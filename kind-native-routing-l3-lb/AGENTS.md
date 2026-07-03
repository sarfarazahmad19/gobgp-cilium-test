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
  client-net        transit-net         bgp-net
  172.21.0.0/24     172.23.0.0/24       172.19.0.0/16
  ─────────         ──────────           ────────────
  test-client  ──►  FRR1 TOR-Client ──►  FRR2 TOR-Cluster (default gateway)
  172.21.0.100      172.21.0.10          172.19.0.10
                    172.23.0.1           172.23.0.2
                    AS 65100             AS 65000
                                         │
                                         ├── overlay-l3-bgp-CP     172.19.0.3
                                         ├── overlay-l3-bgp-worker 172.19.0.4
                                         └── overlay-l3-bgp-worker2 172.19.0.5  AS 65001
```

- **Cluster name:** `overlay-l3-bgp`
- **K8s version:** v1.33.0
- **Cilium version:** 1.19.5
- **CNI:** Cilium (default kindnet disabled)
- **kube-proxy:** disabled (Cilium strict kube-proxy replacement via eBPF)
- **BGP:** Cilium BGP Control Plane enabled (`bgpControlPlane.enabled=true`),
  TCP MD5 auth (RFC 2385) enabled on Cilium↔FRR2 peering only
- **Routing:** Native routing (`routingMode=native`). Pod IPs are routable
  on the host network; Cilium advertises both per-node PodCIDR slices and
  Service LoadBalancerIPs to FRR2 via BGP.
- **LB mode:** SNAT (`loadBalancer.mode=snat`). Cilium source-NATs inbound
  LB traffic to the node's IP so backend pods can reply via the node;
  the node un-NATs and sends the response to the client.
- **Observability:** Hubble (agent, relay, UI) enabled
- **IPAM:** Kubernetes mode (`ipam.mode=kubernetes`)

## Design decisions

Architectural choices made during development and why:

### Single bgp-net (no bgp-kind bridge)

Kind creates its own Docker bridge (`kind`) for node-to-node traffic, but
external containers (like FRR2) cannot attach to it. The original design used
a second bridge (`bgp-net`) for BGP peering and a second interface (`eth1`)
on each node — but this required per-node PodCIDR static routes through the
kind bridge, which were fragile and unreliable.

The fix: **make FRR2 the default gateway** for all kind nodes. This lets the
kind bridge go away entirely — all traffic (BGP, LB, pod inter-node, apiserver)
flows through `bgp-net` via FRR2. No static routes, no auto-direct-node-routes.

### FRR2 as default gateway

`scripts/kind-up.sh` sets FRR2 (172.19.0.10) as the default gateway on every
kind node via `docker exec <node> ip route replace default via 172.19.0.10`.
FRR2 has `ip_forward=1` (via sysctl in docker-compose) and internet access
through Docker's default bridge — so kind nodes retain outbound connectivity.

### Native routing (not tunnel)

`routingMode=native` (not Geneve/VXLAN). Pod IPs are routable on the host
network. No encapsulation overhead. Cilium advertises both PodCIDRs and LB
VIPs via BGP so FRR2 can route return traffic.

### SNAT (not DSR)

`loadBalancer.mode=snat`. Cilium source-NATs inbound LB traffic to the
node's IP, so the backend pod replies via the node (un-NAT happens there).
This works with any backend regardless of kernel version or kube-proxy mode.
DSR would avoid the SNAT hop but requires backend awareness of the client IP
and more complex Cilium configuration.

### Single Cilium device

`devices={eth1}` only. With FRR2 as the only upstream, Cilium only needs
eBPF programs on `bgp-net` (eth1). No `directRoutingDevice` needed.

### autoDirectNodeRoutes is unreliable

`autoDirectNodeRoutes=true` in Cilium Helm values does NOT reliably install
inter-node PodCIDR routes — the actual state can show `false` despite the
setting. This was a root cause of intermittent curl failures in an earlier
version. Solution: no static routes needed at all (FRR2 is the default
gateway and handles inter-node routing).

### No tunnel in the CNI, no kube-proxy

- kindnet is disabled; Cilium is the sole CNI
- kube-proxy is disabled (strict eBPF replacement)
- No overlay tunnel — native routing end-to-end

## Key files

| File | Role |
|------|------|
| `kind.yaml` | Cluster definition — nodes, kubeadm patches, pod/service CIDRs |
| `docker-compose.yml` | Controller + FRR1/FRR2 BGP speakers + test client |
| `Makefile` | Day-to-day commands (`make up`, `make frr-up`, etc.) |
| `scripts/kind-up.sh` | Creates cluster, attaches nodes to `bgp-net`, sets FRR2 as default gateway, exports kubeconfig |
| `scripts/kind-down.sh` | Deletes cluster (leaves networks intact) |
| `scripts/install-cilium.sh` | Helm-installs Cilium with BGP+Hubble+native-routing+SNAT, resolves CP IP from Docker |
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
make frr2-status          # FRR2 BGP summary
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
container's IP on the `bgp-net` Docker network and passes it as
`k8sServiceHost` so Cilium can reach the apiserver before Service IP routing
is up.

IMPORTANT: The `devices` option must include the BGP peering interface. With
a single upstream (FRR2 is the default gateway on `bgp-net`), Cilium only
needs one device on the BGP/LB network — no dual-device quirk.

Cilium Helm values used:
```
kubeProxyReplacement=true
bgpControlPlane.enabled=true
hubble.enabled=true
hubble.relay.enabled=true
hubble.ui.enabled=true
ipam.mode=kubernetes
bpf.masquerade=true
devices={eth1}
loadBalancer.mode=snat
routingMode=native
ipv4NativeRoutingCIDR=10.244.0.0/16
```

## Network

Three Docker bridges:
- `bgp-net`: server L2 segment (172.19.0.0/16). FRR2 + Cilium control-plane
  and worker nodes. FRR2 (172.19.0.10) is the default gateway for all kind
  nodes. Created by `net-create`; survives cluster teardown — removed by
  `make clean`.
- `transit-net`: transit L2 segment (172.23.0.0/24). FRR1 ↔ FRR2 split.
- `client-net`: client L2 segment (172.21.0.0/24). FRR1 + test client only.

Each kind node has a single host-facing interface:
- `eth0` on `bgp-net` (the only Cilium device — carries BGP, LB traffic,
  inter-node pod traffic, and all node-to-node communication)

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

### FRR2 TOR-Cluster (docker-compose service `frr2`, container `frr-speaker-cluster`)

The border router and default gateway for all kind nodes. Dual-homed on
`bgp-net` (172.19.0.10) and `transit-net` (172.23.0.2). AS 65000.

- **Image:** `frrouting/frr:latest` (cap_add NET_ADMIN + SYS_ADMIN,
  sysctl net.ipv4.ip_forward=1)
- **Config:** `frr/frr.conf` — peers with both Cilium workers (172.19.0.4,
  172.19.0.5, AS 65001) with TCP MD5 password, and FRR1 (172.23.0.1,
  AS 65100, no auth). Uses `neighbor 172.23.0.1 next-hop-self` so FRR1
  forwards all traffic through FRR2 (different L2 segments — without this,
  FRR1 would learn unreachable Cilium worker IPs as next-hops). Uses
  `timers 3 9` for faster Cilium failover (default 90s hold).
- **Lifecycle:** `make frr-up` / `make frr2-up` / `make frr-down` / `make frr2-down`
- **Inspect:** `docker exec frr-speaker-cluster vtysh -c "show bgp summary"`
- **Routes (RIB):** `make frr2-routes`
- **Routes (FIB):** `docker exec frr-speaker-cluster ip route show proto bgp`
- See [README §BGP peering](README.md#bgp-peering) for details.

### FRR1 TOR-Client (docker-compose service `frr1`, container `frr-speaker-tor`)

Client-facing TOR switch. Dual-homed on `client-net` (172.21.0.10) and
`transit-net` (172.23.0.1). AS 65100. Serves as the test client's default
gateway. Peers only with FRR2 over transit-net (does NOT peer with Cilium,
does NOT touch bgp-net). Advertises `network 172.21.0.0/24` to FRR2 so the
return path can reach client-net.

- **Config:** `frr/frr1.conf`
- **Lifecycle:** `make frr1-up` / `make frr1-down`
- **Inspect:** `docker exec frr-speaker-tor vtysh -c "show bgp summary"`
- **Routes (RIB):** `make frr1-routes` (should show LB VIP via FRR2)

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
   Expected: `Devices: eth1 172.19.x.x`
   If `eth1` is missing, re-install Cilium with `devices='{eth1}'`.

2. Check BGP peering on FRR2:
   ```
   make frr2-status
   # State should be "Established" for both Cilium workers + FRR1
   ```

3. Check FRR1 sees the route via FRR2:
   ```
   make frr1-routes
   # Should show 172.19.0.200/32 via 172.23.0.2
   ```

4. Verify kernel return route was added on kind nodes:
   ```
   docker exec overlay-l3-bgp-worker ip route show | grep 172.21.0.0
   # Should show: 172.21.0.0/24 via 172.19.0.10 dev eth1
   ```

5. Verify inter-node PodCIDR routes (native routing):
   ```
   docker exec overlay-l3-bgp-worker ip route show | grep 10.244
   # Should show local + remote PodCIDRs, e.g.:
   #   10.244.1.0/24 via 10.244.1.45 dev cilium_host
   #   10.244.2.0/24 via 172.19.0.10 dev eth1
   ```

6. Check that FRR kernel routes are installed:
   ```
   docker exec frr-speaker-cluster ip route show proto bgp
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

### Cilium daemonset stuck (CP pod Pending)

If a Cilium pod on the control-plane is stuck in `Pending` after re-install,
check for an old pod in `Terminating` state:

```
kubectl -n kube-system get pods | grep cilium
```

The old pod's podAntiAffinity blocks scheduling the new one. Force-delete
from the kubelet (the CP node itself):

```
docker exec overlay-l3-bgp-control-plane kubectl --kubeconfig /etc/kubernetes/admin.conf delete pod -n kube-system <old-cilium-pod> --force --grace-period=0
```

### Control-plane NotReady after force-delete

Force-deleting a Cilium pod on the CP can corrupt containerd's bolt metadata
database. Symptoms: `kubectl get nodes` shows CP `NotReady`, containerd logs
show `failed to recover state: sandbox not found`.

Fix (on the CP container):
```
docker exec overlay-l3-bgp-control-plane systemctl stop containerd
docker exec overlay-l3-bgp-control-plane rm -f /var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db
docker exec overlay-l3-bgp-control-plane systemctl start containerd
```

### Cilium re-install fails (cilium-secrets namespace stuck)

`cilium-secrets` namespace can get stuck in `Terminating` after `helm uninstall`.
Wait for it to fully disappear before retrying `make cilium-install`:

```
kubectl get namespace cilium-secrets -o json | jq 'del(.spec.finalizers[])' | kubectl replace --raw /api/v1/namespaces/cilium-secrets/finalize -f -
```

(Or just wait 10-15 seconds.)

### Cilium BGP session won't establish

- TCP MD5 mismatch failure mode: `dial: i/o timeout` (silently drops SYN).
  Verify password match between k8s Secret and `frr/frr.conf`.
- Check FRR is running: `docker exec frr-speaker-cluster vtysh -c "show bgp summary"`.
- Check `bgp-net` connectivity: `docker exec overlay-l3-bgp-worker ping 172.19.0.10`.
- Verify Cilium's device list includes `eth1` on the worker (`Devices: eth1 172.19.x.x`).

### Helm value gotchas

- `loadBalancer.mode=snat` (lowercase `snat`, not `sNat` or `SNAT`)
- `routingMode=native` (not `tunnelProtocol=disabled`)
- `ipv4NativeRoutingCIDR=10.244.0.0/16` is **required** with native routing

## Verification checklist

After `make up`, verify the full path end-to-end:

```
# 1. Cluster is healthy
make status
kubectl get nodes -o wide

# 2. Cilium daemonset fully rolled out
kubectl -n kube-system get pods | grep cilium
# Should show 3/3 cilium-agent pods, all Running

# 3. Cilium device list is correct
kubectl exec -n kube-system ds/cilium -- cilium-dbg status --verbose | grep Devices
# Expected: Devices: eth1 172.19.x.x

# 4. BGP sessions are Established
make frr2-status
# State: Established for both workers + FRR1

# 5. FRR2 RIB has PodCIDRs + LB VIP
make frr2-routes
# Should show 10.244.1.0/24, 10.244.2.0/24, 172.19.0.200/32

# 6. FRR1 RIB has LB VIP via FRR2
make frr1-routes
# Should show 172.19.0.200/32 via 172.23.0.2

# 7. Kernel routes installed on FRR2
docker exec frr-speaker-cluster ip route show proto bgp

# 8. Worker routing is clean (no static routes)
docker exec overlay-l3-bgp-worker ip route show | grep "^default"
# default via 172.19.0.10 dev eth1
docker exec overlay-l3-bgp-worker ip route show | grep 10.244
# Shows local PodCIDR via cilium_host AND remote via 172.19.0.10

# 9. End-to-end: curl LB VIP from test-client
make client-test
# Should return HTTP 200
```
</content>
</invoke>