# AGENTS.md — bgp-kind-cilium

## Purpose

Local BGP networking lab using Cilium's BGP Control Plane on a kind
(Kubernetes-in-Docker) cluster. A two-hop FRR path simulates a realistic
data-center topology: the test client sits behind a TOR switch (FRR1),
which peers via eBGP with a border router (FRR2), which in turn peers with
Cilium's BGP Control Plane on every kind worker to advertise K8s Service
LoadBalancer IPs.

## Architecture

```
  client-net        transit-net         bgp-net              bgp-kind
  172.21.0.0/24     172.23.0.0/24       172.19.0.0/16        172.20.0.0/16
  ─────────         ──────────           ────────────         ────────────
  test-client  ──►  FRR1 TOR-Client ──►  FRR2 TOR-Cluster ──► overlay-l3-bgp-CP
  172.21.0.100      172.21.0.10          172.19.0.10          (172.19.0.3)
                    172.23.0.1           172.23.0.2           overlay-l3-bgp-worker
                    AS 65100             AS 65000              (172.19.0.4)
                                                              overlay-l3-bgp-worker2
                                                              (172.19.0.5) AS 65001
```

- **Cluster name:** `overlay-l3-bgp`
- **K8s version:** v1.33.0
- **Cilium version:** 1.19.5
- **CNI:** Cilium (default kindnet disabled)
- **kube-proxy:** disabled (Cilium strict kube-proxy replacement via eBPF)
- **BGP:** Cilium BGP Control Plane enabled (`bgpControlPlane.enabled=true`),
  TCP MD5 auth (RFC 2385) enabled on Cilium↔FRR2 peering only
- **DSR:** `loadBalancer.mode=dsr`, `loadBalancer.dsrDispatch=geneve`
- **Tunnel:** Geneve (`tunnelProtocol=geneve`)
- **Observability:** Hubble (agent, relay, UI) enabled
- **IPAM:** Kubernetes mode (`ipam.mode=kubernetes`)

## Key files

| File | Role |
|------|------|
| `kind.yaml` | Cluster definition — nodes, kubeadm patches, pod/service CIDRs |
| `docker-compose.yml` | Controller + FRR1/FRR2 BGP speakers + test client |
| `Makefile` | Day-to-day commands (`make up`, `make frr-up`, etc.) |
| `scripts/kind-up.sh` | Creates cluster, attaches nodes to `bgp-net`, adds DSR return routes, exports kubeconfig |
| `scripts/kind-down.sh` | Deletes cluster (leaves networks intact) |
| `scripts/install-cilium.sh` | Helm-installs Cilium with BGP+Hubble+DSR+Geneve, resolves CP IP from Docker |
| `frr/frr.conf` | FRR2 TOR-Cluster config (AS 65000, peers Cilium workers + FRR1, next-hop-self for FRR1) |
| `frr/frr1.conf` | FRR1 TOR-Client config (AS 65100, peers FRR2, advertises client-net) |
| `frr/daemons` | FRR daemon control (enables bgpd + zebra) |
| `manifests/cilium-bgp.yaml` | Cilium BGP CRDs (peer config, cluster config, advertisement) |
| `manifests/cilium-lb-pool.yaml` | CiliumLoadBalancerIPPool (172.19.0.200-172.19.0.220) |
| `manifests/svc-lb.yaml` | Test go-httpbin Deployment (2x, anti-affinity) + LoadBalancer Service |
| `assets/topology.mmd` + `.png` | Mermaid source + rendered topology diagram |
| `assets/test-client.mmd` + `.png` | Mermaid source + rendered test-client topology |
| `.kubeconfig/kubeconfig.yaml` | Generated kubeconfig (gitignored) |

## Workflow

`make up` is a full bring-up (cluster + cilium + auth secret + BGP CRDs +
LB pool + both FRR speakers + test client). `make clean` is the symmetric
full tear-down. The per-step sub-targets are exposed for surgical use:

```sh
make up                  # full bring-up (idempotent)
make cluster-up          # just the kind cluster (skip cilium/frr)
make cilium-install      # install/upgrade Cilium (idempotent)
make bgp-auth-secret     # create k8s secret bgp-auth (TCP MD5 password) — idempotent
make bgp-apply           # apply Cilium BGP CRDs
make lb-pool-apply       # apply CiliumLoadBalancerIPPool for LB IPAM
make svc-apply           # apply sample LoadBalancer Service + Deployment
make frr-up              # start both FRR speakers (FRR1 + FRR2)

make status              # check cluster health
make cilium-status       # quick Cilium health check
make frr-status          # FRR2 BGP summary (alias for frr2-status)
make frr1-status         # FRR1TOR-Client BGP summary
make frr2-routes         # FRR2 RIB (routes from Cilium)
make frr1-routes         # FRR1 RIB (routes from FRR2)
make client-test         # curl LB VIP from test-client (end-to-end)
make hubble-ui           # port-forward Hubble UI to localhost:12000

make down                # stop FRRs + client + tear down cluster
make clean               # down + remove all networks + wipe kubeconfig
```

## Cilium install details

The install script (`scripts/install-cilium.sh`) resolves the control-plane
container's IP on the Docker `bgp-kind` network and passes it as
`k8sServiceHost` so Cilium can reach the apiserver before Service IP routing
is up.

IMPORTANT: The `devices` option must list both `eth0` (kind management
network) and `eth1` (bgp-net BGP peering network). Without `eth1` in the
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
loadBalancer.mode=dsr
loadBalancer.dsrDispatch=geneve
tunnelProtocol=geneve
```

## Network

Four Docker bridges:
- `bgp-kind`: kind management network (172.20.0.0/16). Kind cluster
  node-to-node communication (apiserver, etcd, etc.).
- `bgp-net`: server L2 segment (172.19.0.0/16). FRR2 + Cilium worker nodes.
  Created by `net-create`; survives cluster teardown — removed by
  `make clean`.
- `transit-net`: transit L2 segment (172.23.0.0/24). FRR1 ↔ FRR2 split.
- `client-net`: client L2 segment (172.21.0.0/24). FRR1 + test client only.

Each kind node has two interfaces:
- `eth0` on `bgp-kind` (auto-detected by Cilium as the default device)
- `eth1` on `bgp-net` (must be explicitly added to Cilium's device list)

- Pod CIDR: `10.244.0.0/16`
- Service CIDR: `10.96.0.0/16`

## Conventions

- `make` targets are the primary interface; don't use `docker compose` directly
- Scripts are idempotent (safe to re-run)
- Shell scripts use `set -eu` (exit on error, undefined vars)
- `.kubeconfig/` is gitignored
- Docker socket is mounted read-write into the controller container
- Host binaries (kind, helm, kubectl) are bind-mounted into the controller

## FRR BGP speakers

### FRR2 TOR-Cluster (docker-compose service `frr2`, container `frr-speaker`)

The border router. Dual-homed on `bgp-net` (172.19.0.10) and `transit-net`
(172.23.0.2). AS 65000.

- **Image:** `frrouting/frr:latest` (cap_add NET_ADMIN + SYS_ADMIN,
  sysctl net.ipv4.ip_forward=1)
- **Config:** `frr/frr.conf` — peers with both Cilium workers (172.19.0.4,
  172.19.0.5, AS 65001) with TCP MD5 password, and FRR1 (172.23.0.1,
  AS 65100, no auth). Uses `neighbor 172.23.0.1 next-hop-self` so FRR1
  forwards all traffic through FRR2 (different L2 segments — without this,
  FRR1 would learn unreachable Cilium worker IPs as next-hops). Uses
  `timers 3 9` for faster Cilium failover (default 90s hold).
- **Lifecycle:** `make frr-up` / `make frr2-up` / `make frr-down` / `make frr2-down`
- **Inspect:** `docker exec frr-speaker vtysh -c "show bgp summary"`
- **Routes (RIB):** `make frr2-routes`
- **Routes (FIB):** `docker exec frr-speaker ip route show proto bgp`
- See [README §BGP peering](README.md#bgp-peering) for details.

### FRR1 TOR-Client (docker-compose service `frr1`, container `frr-speaker-tor`)

Client-facing TOR switch. Dual-homed on `client-net` (172.21.0.10) and
`transit-net` (172.23.0.1). AS 65100. Serves as the test client's default
gateway. Peers only with FRR2 over transit-net (does NOT peer with Cilium,
does NOT touch bgp-net). Advertises `network 172.21.0.0/24` to FRR2 so the
DSR return path can reach client-net.

- **Config:** `frr/frr1.conf`
- **Lifecycle:** `make frr1-up` / `make frr1-down`
- **Inspect:** `docker exec frr-speaker-tor vtysh -c "show bgp summary"`
- **Routes (RIB):** `make frr1-routes` (should show LB VIP via FRR2)

### DSR return path

The kind nodes need a static route to reach `client-net` (172.21.0.0/24) —
without it, DSR response packets (sourced from real client IP) go out the
default gateway (bgp-kind bridge) which doesn't know about client-net.

```
docker exec <node> ip route add 172.21.0.0/24 via 172.19.0.10 dev eth1
```

This is added automatically:
- At cluster creation time (`scripts/kind-up.sh` runs it on every node)
- By `make client-up` (via `client-route-add` target) when the client starts
- Re-run `make client-route-add` if kind nodes are restarted

### Test client

Alpine container on client-net (172.21.0.100) with FRR1 as default gateway.

- **Start/stop:** `make client-up` / `make client-down`
- **Test (curl LB VIP):** `make client-test`
- **Shell:** `docker exec -it test-client sh`

## Cilium BGP CRDs

Applied via `manifests/cilium-bgp.yaml`:
- `CiliumBGPPeerConfig/overlay-l3-bgp-default` — peer settings + `authSecretRef: bgp-auth`
  (TCP MD5) + `families[ipv4].advertisements.matchLabels: {advertise: bgp}`
- `CiliumBGPClusterConfig/overlay-l3-bgp-bgp` — BGP instance AS 65001, peer
  172.19.0.10:179 AS 65000. `nodeSelector` excludes control-plane (workers
  only: 172.19.0.4 and 172.19.0.5).
- `CiliumBGPAdvertisement/overlay-l3-bgp-advert` — labelled `advertise: bgp`,
  advertises Service LoadBalancerIP
- k8s Secret `bgp-auth` in `kube-system` (key `password`) — created by
  `make bgp-auth-secret`

NOTE: Without `families[].advertisements.matchLabels` on the PeerConfig
matching the Advertisement's labels, no routes are advertised even if BGP
sessions are established.

## Troubleshooting

### LoadBalancer IP unreachable from client

If `make client-test` fails or `docker exec test-client wget http://172.19.0.200`
returns "Host is unreachable":

1. Verify Cilium's device list includes `eth1`:
   ```
   kubectl exec -n kube-system ds/cilium -- cilium-dbg status --verbose | grep Devices
   ```
   Expected: `Devices: eth0 172.20.x.x, eth1 172.19.x.x`
   If `eth1` is missing, re-install Cilium with `devices='{eth0,eth1}'` and
   `directRoutingDevice=eth0`.

2. Check BGP peering on FRR2:
   ```
   make frr-status
   # State should be "Established" for both Cilium workers + FRR1
   ```

3. Check FRR1 sees the route via FRR2:
   ```
   make frr1-routes
   # Should show 172.19.0.200/32 via 172.23.0.2
   ```

4. Verify kernel DSR return route was added on kind nodes:
   ```
   docker exec overlay-l3-bgp-worker ip route show | grep 172.21.0.0
   # Should show: 172.21.0.0/24 via 172.19.0.10 dev eth1
   ```

5. Check that FRR kernel routes are installed:
   ```
   docker exec frr-speaker ip route show proto bgp
   docker exec frr-speaker-tor ip route show proto bgp
   ```

### BGP session won't come up (Cilium ↔ FRR2)

- Verify the k8s Secret `bgp-auth` exists and the password matches
  `frr/frr.conf`:
  ```
  kubectl -n kube-system get secret bgp-auth -o jsonpath='{.data.password}' | base64 -d
  ```
- Cilium BGP CP failure mode on MD5 mismatch: `dial: i/o timeout` (silently
  drops SYN). Both ends must have the same password.

### FRR1 doesn't see the LB VIP route

- Check FRR2 has FRR1 as a neighbor and `next-hop-self` is set — without it,
  FRR1 learns an unreachable worker IP (172.19.0.x, on a different L2) as
  the next-hop.
- Confirm `no bgp ebgp-requires-policy` is set in both FRR configs.
```
</content>
</invoke>