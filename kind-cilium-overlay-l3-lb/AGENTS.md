# AGENTS.md — gobgp-kind-cilium

## Purpose

Local BGP networking lab using Cilium's BGP Control Plane on a kind
(Kubernetes-in-Docker) cluster. The environment lets you peer an external BGP
speaker (GoBGP, FRR, Bird) with Cilium to test route advertisement of K8s
Service LoadBalancer IPs and Pod CIDRs.

## Architecture

```
                     gobgp-net (Docker bridge, L2 segment, 172.19.0.0/16)
             ┌──────────────────────────────────────────────────────┐
             │                                                      │
    gobgp-control-plane     gobgp-worker         gobgp-speaker
    (kind node, K8s CP)    (kind node, worker)   (GoBGP daemon)
    172.19.0.4              172.19.0.3           172.19.0.10
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
  TCP MD5 auth (RFC 2385) enabled on the GoBGP peer
- **Observability:** Hubble (agent, relay, UI) enabled
- **IPAM:** Kubernetes mode (`ipam.mode=kubernetes`)

## Key files

| File | Role |
|------|------|
| `kind.yaml` | Cluster definition — nodes, kubeadm patches, pod/service CIDRs |
| `docker-compose.yml` | Controller container + GoBGP speaker service |
| `Makefile` | Day-to-day commands (`make up`, `make gobgp-up`, etc.) |
| `scripts/kind-up.sh` | Creates cluster, attaches nodes to `gobgp-net`, exports kubeconfig |
| `scripts/kind-down.sh` | Deletes cluster (leaves `gobgp-net` intact) |
| `scripts/install-cilium.sh` | Helm-installs Cilium with BGP+Hubble, resolves CP IP from Docker |
| `gobgp/gobgpd.toml` | GoBGP speaker config (AS 65000, peers to both nodes) |
| `manifests/cilium-bgp.yaml` | Cilium BGP CRDs (peer config, cluster config, advertisement) |
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
make gobgp-up            # start GoBGP speaker (background)

make status              # check cluster health
make cilium-status       # quick Cilium health check
make gobgp-status        # check BGP peering state
make gobgp-routes        # show learned routes
make hubble-ui           # port-forward Hubble UI to localhost:12000

make down                # stop speaker + tear down cluster
make clean               # down + remove gobgp-net + wipe kubeconfig
```

## Cilium install details

The install script (`scripts/install-cilium.sh`) resolves the control-plane
container's IP on the Docker `kind` network and passes it as `k8sServiceHost`
so Cilium can reach the apiserver before Service IP routing is up.

Cilium Helm values used:
```
kubeProxyReplacement=true
bgpControlPlane.enabled=true
hubble.enabled=true
hubble.relay.enabled=true
hubble.ui.enabled=true
ipam.mode=kubernetes
bpf.masquerade=true
```

## Network

- `kind` network: default Docker network kind creates for the cluster
- `gobgp-net`: shared external bridge network for connecting BGP peers
  (created on first `make up`, survives cluster teardown — removed by
  `make clean`)
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

## GoBGP speaker

GoBGP runs as a docker-compose service (`gobgp`), container name `gobgp-speaker`,
on the shared `gobgp-net` bridge with static IP 172.19.0.10.

- **Image:** `osrg/gobgp:latest`
- **Config:** `gobgp/gobgpd.toml` — local AS 65000, router ID 172.19.0.10,
  neighbors 172.19.0.4 and 172.19.0.3 (both AS 65001), accept-all policy,
  TCP MD5 `auth-password` on each peer
- **gRPC API:** exposed on `:50051`
- **Lifecycle:** `make gobgp-up` / `make gobgp-down`

Cilium BGP configuration is applied via `manifests/cilium-bgp.yaml`:
- `CiliumBGPPeerConfig/gobgp-default` — peer settings + `authSecretRef: gobgp-auth`
  (TCP MD5) + `families[ipv4].advertisements.matchLabels: {advertise: bgp}`
- `CiliumBGPClusterConfig/gobgp-bgp` — AS 65001, peer 172.19.0.10:179 AS 65000
- `CiliumBGPAdvertisement/gobgp-advert` — labelled `advertise: bgp`, advertises PodCIDR + Service LoadBalancerIP
- k8s Secret `gobgp-auth` in `kube-system` (key `password`) — created by `make gobgp-auth-secret`

NOTE: Without `families[].advertisements.matchLabels` on the PeerConfig matching the
Advertisement's labels, no routes are advertised even if BGP sessions are established.
