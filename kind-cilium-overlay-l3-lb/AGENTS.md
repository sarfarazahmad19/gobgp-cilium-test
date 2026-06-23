# AGENTS.md — gobgp-kind-cilium

## Purpose

Local BGP networking lab using Cilium's BGP Control Plane on a kind
(Kubernetes-in-Docker) cluster. The environment lets you peer an external BGP
speaker (FRR, GoBGP, Bird) with Cilium to test route advertisement of K8s
Service LoadBalancer IPs and Pod CIDRs.

## Architecture

```
                     gobgp-net (Docker bridge, L2 segment, 172.19.0.0/16)
             ┌──────────────────────────────────────────────────────┐
             │                                                      │
    gobgp-control-plane     gobgp-worker          frr-speaker
    (kind node, K8s CP)    (kind node, worker)   (FRR bgpd+zebra)
    172.19.0.3              172.19.0.4           172.19.0.10
    AS 65001                AS 65001             AS 65000
    Cilium BGP CP          Cilium BGP CP
        │                       │                    │
        └─────── BGP peer ──────┼────────────────────┘
                                │
                    (advertises PodCIDR + Service LB IPs)
```

- **Cluster name:** `gobgp`
- **K8s version:** v1.33.0
- **Cilium version:** 1.19.5
- **CNI:** Cilium (default kindnet disabled)
- **kube-proxy:** disabled (Cilium strict kube-proxy replacement via eBPF)
- **BGP:** Cilium BGP Control Plane enabled (`bgpControlPlane.enabled=true`),
  TCP MD5 auth (RFC 2385) enabled on the FRR peer
- **Observability:** Hubble (agent, relay, UI) enabled
- **IPAM:** Kubernetes mode (`ipam.mode=kubernetes`)

## Key files

| File | Role |
|------|------|
| `kind.yaml` | Cluster definition — nodes, kubeadm patches, pod/service CIDRs |
| `docker-compose.yml` | Controller container + FRR BGP speaker service |
| `Makefile` | Day-to-day commands (`make up`, `make frr-up`, etc.) |
| `scripts/kind-up.sh` | Creates cluster, attaches nodes to `gobgp-net`, exports kubeconfig |
| `scripts/kind-down.sh` | Deletes cluster (leaves networks intact) |
| `scripts/install-cilium.sh` | Helm-installs Cilium with BGP+Hubble, resolves CP IP from Docker |
| `frr/frr.conf` | FRR BGP speaker config (AS 65000, peers to both nodes) |
| `frr/daemons` | FRR daemon control (enables bgpd + zebra) |
| `manifests/cilium-bgp.yaml` | Cilium BGP CRDs (peer config, cluster config, advertisement) |
| `manifests/cilium-lb-pool.yaml` | CiliumLoadBalancerIPPool (172.19.0.200-172.19.0.220) |
| `manifests/svc-lb.yaml` | Test nginx Deployment (2x) + LoadBalancer Service |
| `.kubeconfig/kubeconfig.yaml` | Generated kubeconfig (gitignored) |

## Workflow

`make up` is a full bring-up (cluster + cilium + auth secret + BGP CRDs +
speaker). `make clean` is the symmetric full tear-down. The per-step
sub-targets are exposed for surgical use:

```sh
make up                  # full bring-up (idempotent)
make cluster-up          # just the kind cluster (skip cilium/gobgp)
make cilium-install      # install/upgrade Cilium (idempotent)
make gobgp-auth-secret   # create k8s secret gobgp-auth (TCP MD5 password) — idempotent
make gobgp-apply         # apply Cilium BGP CRDs
make lb-pool-apply       # apply CiliumLoadBalancerIPPool for LB IPAM
make frr-up              # start FRR BGP speaker (background)

make status              # check cluster health
make cilium-status       # quick Cilium health check
make frr-status          # check BGP peering state (vtysh)
make frr-routes          # show routes learned by FRR
make hubble-ui           # port-forward Hubble UI to localhost:12000

make down                # stop speaker + tear down cluster
make clean               # down + remove gobgp-net + wipe kubeconfig
```

## Cilium install details

The install script (`scripts/install-cilium.sh`) resolves the control-plane
container's IP on the Docker `gobgp-kind` network and passes it as
`k8sServiceHost` so Cilium can reach the apiserver before Service IP routing
is up.

IMPORTANT: The `devices` option must list both `eth0` (kind management
network) and `eth1` (gobgp-net BGP peering network). Without `eth1` in the
device list, Cilium's eBPF programs won't intercept LoadBalancer traffic
arriving on the BGP peering interface. `directRoutingDevice` must be set to
`eth0` when multiple devices are specified.

Cilium Helm values used:
```
kubeProxyReplacement=true
bgpControlPlane.enabled=true
hubble.enabled=true
hubble.relay.enabled=true
hubble.ui.enabled=true
ipam.mode=kubernetes
bpf.masquerade=true
devices={eth0,eth1}
directRoutingDevice=eth0
```

## Network

- Two Docker bridges:
  - `gobgp-kind`: kind management network (172.20.0.0/16). Kind cluster
    node-to-node communication (apiserver, etcd, etc.).
  - `gobgp-net`: shared external bridge for BGP peering (172.19.0.0/16).
    Created by `net-create`; survives cluster teardown — removed by
    `make clean`.
- Each kind node has two interfaces:
  - `eth0` on `gobgp-kind` (auto-detected by Cilium as the default device)
  - `eth1` on `gobgp-net` (must be explicitly added to Cilium's device list)
- Pod CIDR: `10.244.0.0/16`
- Service CIDR: `10.96.0.0/16`

## Conventions

- `make` targets are the primary interface; prefer them over raw `docker compose` / `kubectl`
- `make` targets are the primary interface; don't use `docker compose` directly
- Scripts are idempotent (safe to re-run)
- Shell scripts use `set -eu` (exit on error, undefined vars)
- `.kubeconfig/` is gitignored
- Docker socket is mounted read-write into the controller container
- Host binaries (kind, helm, kubectl) are bind-mounted into the controller

## FRR BGP speaker

FRR runs as a docker-compose service (`frr`), container name `frr-speaker`,
on the shared `gobgp-net` bridge with static IP 172.19.0.10.

- **Image:** `frrouting/frr:latest`
- **Config:** `frr/frr.conf` — local AS 65000, router ID 172.19.0.10,
  neighbors 172.19.0.4 and 172.19.0.3 (both AS 65001), TCP MD5 password on
  each peer, `no bgp ebgp-requires-policy`
- **Daemons:** `frr/daemons` — `bgpd=yes` and `zebra=yes` (zebra installs
  routes into the kernel FIB; this is the key advantage over GoBGP)
- **Lifecycle:** `make frr-up` / `make frr-down`
- **Inspect:** `docker exec frr-speaker vtysh -c "show bgp summary"`
- **Routes (RIB):** `docker exec frr-speaker vtysh -c "show bgp ipv4 unicast"`
- **Routes (FIB):** `docker exec frr-speaker ip route show proto bgp`

Cilium BGP configuration is applied via `manifests/cilium-bgp.yaml`:
- `CiliumBGPPeerConfig/gobgp-default` — peer settings + `authSecretRef: gobgp-auth`
  (TCP MD5) + `families[ipv4].advertisements.matchLabels: {advertise: bgp}`
- `CiliumBGPClusterConfig/gobgp-bgp` — AS 65001, peer 172.19.0.10:179 AS 65000
- `CiliumBGPAdvertisement/gobgp-advert` — labelled `advertise: bgp`, advertises
  PodCIDR + Service LoadBalancerIP
- k8s Secret `gobgp-auth` in `kube-system` (key `password`) — created by
  `make gobgp-auth-secret`

NOTE: Without `families[].advertisements.matchLabels` on the PeerConfig
matching the Advertisement's labels, no routes are advertised even if BGP
sessions are established.

## Troubleshooting

### LoadBalancer IP unreachable from FRR

If `wget http://172.19.0.200` fails with "Host is unreachable":

1. Verify Cilium's device list includes `eth1`:
   ```
   kubectl exec -n kube-system cilium-XXXX -- cilium-dbg status --verbose | grep Devices
   ```
   Expected: `Devices: eth0 172.20.0.2, eth1 172.19.0.3`
   If `eth1` is missing, re-install Cilium with `devices='{eth0,eth1}'` and
   `directRoutingDevice=eth0`.

2. Check that kernel routes are installed:
   ```
   docker exec frr-speaker ip route show proto bgp
   ```
   Expected: PodCIDR routes (10.244.x.x/24) and LB IP (172.19.0.200) with
   ECMP nexthops.

3. Test BGP peering:
   ```
   docker exec frr-speaker vtysh -c "show bgp summary"
   ```
