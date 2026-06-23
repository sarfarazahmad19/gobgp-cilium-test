# bgp-kind-cilium

Local BGP networking lab running Cilium as a Kubernetes CNI with BGP Control
Plane, peered with an external BGP speaker over a shared Docker network.

```
                     bgp-net (Docker bridge, L2, 172.19.0.0/16)
             ┌──────────────────────────────────────────────────────┐
             │                                                      │
    overlay-l3-bgp-control-plane     overlay-l3-bgp-worker          frr-speaker
    (kind node, K8s CP)    (kind node, worker)   (FRR bgpd+zebra)
    172.19.0.3              172.19.0.4           172.19.0.10
    AS 65001                AS 65001             AS 65000
    Cilium BGP CP          Cilium BGP CP
        │                       │                    │
        └─────── BGP peer ──────┼────────────────────┘
                                │
                    (advertises LB Service IPs)
```

## What this does

- Spins up a 2-node Kubernetes cluster (v1.33) using [kind][kind]
- Replaces the default CNI and kube-proxy with Cilium (eBPF)
- Enables Cilium's BGP Control Plane (AS 65001) to advertise LoadBalancer
  Service IPs via BGP
- Uses Cilium's LB IPAM (`CiliumLoadBalancerIPPool`, range 172.19.0.200-220) to
  allocate LoadBalancer IPs — creating a `type: LoadBalancer` Service
  automatically produces a route in FRR's RIB
- Runs an FRR speaker (AS 65000) on a shared Docker L2 bridge, peering with
  Cilium on every node. FRR ships bgpd+zebra together, so routes are
  installed into the kernel FIB for local reachability.
- Ships with Hubble for observability (UI, relay, agent)

## Prerequisites

| Tool    | Minimum version | Purpose                        |
|---------|-----------------|--------------------------------|
| Docker  | 20.10+          | Run kind nodes as containers   |
| kind    | 0.32.0          | Create local K8s cluster       |
| kubectl | 1.33+           | Interact with the cluster      |
| helm    | 3.x             | Install Cilium                 |
| make    | (any)           | Orchestrate lifecycle          |

Install kind: https://kind.sigs.k8s.io/docs/user/quick-start/#installation

## Quick start

```sh
# Bring up the full lab (cluster + Cilium + BGP auth secret + CRDs + FRR speaker)
make up

# Check it's all healthy
make status
make cilium-status
make frr-status
make frr-routes

# Open Hubble UI
make hubble-ui
# Visit http://localhost:12000
```

## Make targets

```
  make up              Full bring-up: cluster + cilium + auth + BGP CRDs + speaker + test client
  make cluster-up      Bring up just the kind cluster (no cilium/frr)
  make down            Tear down the kind cluster (also stops frr speaker and test client)
  make status          Show cluster nodes, containers, networks
  make ps              Show running containers
  make logs            Tail controller logs

  make cilium-install  Install or upgrade Cilium via Helm
  make cilium-status   Run `cilium status --brief`
  make hubble-ui       Port-forward Hubble UI to :12000

  make frr-up          Start the FRR speaker (background)
  make frr-down        Stop and remove the FRR speaker
  make bgp-apply     Apply Cilium BGP CRDs to the cluster
  make bgp-auth-secret  Create/update the k8s TCP MD5 secret
  make lb-pool-apply   Apply CiliumLoadBalancerIPPool for LB IPAM
  make frr-status      Show FRR BGP neighbor state (vtysh)
  make frr-routes      Show routes learned by FRR (RIB)

  make client-up       Start the test client (adds static routes on kind nodes)
  make client-down     Stop the test client
  make client-test     Curl the LB VIP from the test client
  make client-route-add  Add static routes for client-net return path

  make net-create      Create the shared bgp-net + client-net networks
  make net-rm          Remove all networks

  make clean           Tear down cluster + remove network + wipe kubeconfig
  make kubeconfig      Print path to kubeconfig
```

## Network layout

```
  Port forwards:
    localhost:6443  →  kube-apiserver
    localhost:12000 →  Hubble UI

  Docker networks:
    bgp-kind     172.20.0.0/16  Dedicated bridge for cluster management
                                  (isolated from other kind clusters)
    bgp-net      172.19.0.0/16  Shared bridge for BGP peering

  Pod CIDR:     10.244.0.0/16
  Service CIDR: 10.96.0.0/16

  BGP participants (all on bgp-net):
    overlay-l3-bgp-control-plane  172.19.0.3  AS 65001
    overlay-l3-bgp-worker         172.19.0.4  AS 65001
    frr-speaker          172.19.0.10 AS 65000
```

## BGP peering

Cilium's BGP Control Plane on each node peers with the FRR speaker over
the shared `bgp-net` L2 bridge. Only LoadBalancer Service IPs are
advertised — PodCIDR routes are intentionally excluded because Cilium's
VXLAN overlay handles pod-to-pod traffic internally. External traffic
reaches pods exclusively through LoadBalancer Services.

FRR learns the LB VIP and installs it into the kernel FIB via zebra:

```
FRR RIB / kernel FIB:
  172.19.0.200/32 → 172.19.0.3 + 172.19.0.4  (ECMP, LoadBalancer IP)
```

### Manifests (`manifests/cilium-bgp.yaml`)

| Resource | Purpose |
|----------|---------|
| `CiliumBGPPeerConfig/overlay-l3-bgp-default` | Peer settings + IPv4 families with ad selector `advertise: bgp` |
| `CiliumBGPClusterConfig/overlay-l3-bgp-bgp` | BGP instance AS 65001, peer to 172.19.0.10 AS 65000 |
| `CiliumBGPAdvertisement/overlay-l3-bgp-advert` | Labeled `advertise: bgp`; advertises Service LoadBalancerIP |
| `CiliumLoadBalancerIPPool/overlay-l3-bgp-lb-pool` | IP pool 172.19.0.200-220 for LB Service IP allocation (`cilium-lb-pool.yaml`) |


### FRR config (`frr/frr.conf`)

Local AS 65000, router ID 172.19.0.10. Two neighbors: 172.19.0.3
(overlay-l3-bgp-control-plane) and 172.19.0.4 (overlay-l3-bgp-worker), both AS 65001, TCP MD5
auth enabled. Includes `no bgp ebgp-requires-policy` to accept routes
without explicit policy. Zebra is enabled (`frr/daemons`) to install routes
into the kernel FIB.

### Verifying LB route advertisement

`make up` applies the IP pool automatically. To test the full path:

```sh
# 1. Apply the sample LoadBalancer Service
kubectl apply -f manifests/svc-lb.yaml

# 2. Check the Service got an IP from the pool
kubectl get svc test-lb
# EXTERNAL-IP column should be 172.19.0.200 (not <pending>)

# 3. Check FRR learned the route
make frr-routes
# → 172.19.0.200/32 via 172.19.0.3 and 172.19.0.4 (ECMP next-hops)

# 4. Verify kernel routes were installed by zebra
docker exec frr-speaker ip route show proto bgp

# 5. Test HTTP reachability from the FRR container
docker exec frr-speaker wget -q -O- http://172.19.0.200 | head -5
# → Welcome to nginx!
```

The route is advertised even without matching pods — BGP is "up" but traffic
blackholes until pods exist. The Deployment bundled in the same manifest
creates nginx pods that match the Service selector, so the full path works
immediately after `kubectl apply`.

See [Findings](#findings) for ECMP behavior and endpoint health details.

## Findings

Operational and behavioral notes accumulated while building and exercising the
lab.

### F1. Service VIP is advertised by BGP even when no endpoints exist

**What we saw:**
- Created `Service/test-lb` (`type: LoadBalancer`, no matching pods).
- Cilium allocated a `LoadBalancer` IP from
  `CiliumLoadBalancerIPPool/overlay-l3-bgp-lb-pool` (e.g. `172.19.0.200`).
- FRR learned `172.19.0.200/32` with **two ECMP next-hops** (one per node).
- Both nodes had zero local endpoints for the service.

**Why:** `CiliumBGPAdvertisement` advertises the **Service VIP**, not the
Endpoints object. From Cilium's BGP control plane's perspective:
- The Service exists with `type: LoadBalancer` and got an IP from the pool.
- The advertisement config says "advertise `LoadBalancerIP`".
- The BGP daemon does not check whether there are healthy backends before
  pushing the route.

So FRR installs the route, traffic from outside is ECMP'd to both nodes,
hits the kube-proxy replacement (Cilium eBPF), finds no backend, and is
dropped/refused. BGP looks "up", the service is a black hole.

**What to do:**
- Create matching pods before treating the route as functional. For the
  sample `test-lb`:
  ```sh
  kubectl --kubeconfig ./.kubeconfig/kubeconfig.yaml run test \
    --image=nginx --labels=app=test --port=80
  ```
  Re-check `make frr-routes` and curl the VIP from `bgp-net`.

**How to make BGP honestly reflect endpoint health (advanced, optional):**
- `externalTrafficPolicy: Local` on the Service: a node withdraws its route
  when it has zero local endpoints. Other nodes still advertise.
- Cilium's BGP CP has no built-in "only advertise if endpoints Ready" gate.
  True readiness-aware advertisement requires either an external health
  checker or a custom per-node BGP speaker that watches Endpoints.

**Related:** [Questions §4](#4-will-creating-a-loadbalancer-service-produce-a-bgp-route)
covers the IP-allocation side; this finding covers the endpoint-orthogonal
side.

### F2. ECMP next-hops from both nodes is by design

**What we saw:**
- `docker exec frr-speaker vtysh -c "show bgp ipv4 unicast"` shows the
  same Service prefix with two next-hops: `172.19.0.3` and `172.19.0.4`.

**Why:** Every node in the cluster runs a Cilium BGP instance
(`nodeSelector: {}` in `CiliumBGPClusterConfig/overlay-l3-bgp-bgp`), each
peers with FRR at `172.19.0.10` AS 65000, and each advertises the same
Service because the `CiliumBGPAdvertisement` has no per-node selector. FRR
receives two equal-cost paths and installs both as ECMP next-hops.

**When you DON'T want this:** set `externalTrafficPolicy: Local` on the
Service. A node withdraws its advertisement when it has no local endpoint,
so traffic only lands on a node that has a pod. From FRR's RIB the route
appears from one node only (the one with the local pod).

**Related:** [F1](#f1-service-vip-is-advertised-by-bgp-even-when-no-endpoints-exist).

### F3. Verifying a BGP route end-to-end

Three checks, in order of usefulness:

1. **Service got an IP (LB IPAM working):**
   ```sh
   kubectl --kubeconfig ./.kubeconfig/kubeconfig.yaml get svc test-lb
   # EXTERNAL-IP column should be 172.19.0.200-220, not <pending>
   ```

2. **BGP session is established:**
   ```sh
   make frr-status
   # Each neighbor's state should be "Established"
   ```

3. **Route is in FRR's RIB:**
   ```sh
   make frr-routes
   # or: docker exec frr-speaker vtysh -c "show bgp ipv4 unicast"
   ```
   Look for the Service prefix (e.g. `172.19.0.200/32`) with next-hops on
   `bgp-net` (`172.19.0.3` / `172.19.0.4`).

If 1 passes but 2 fails → Cilium BGP CP can't reach the speaker; check
`authSecretRef` secret, TCP MD5 password match, and `bgp-net` connectivity.
If 2 passes but 3 doesn't show the Service prefix → advertisement selector
isn't matching; verify the `CiliumBGPAdvertisement` and the Service labels.

### F4. (placeholder)

Add more findings as they surface.

## Cluster details

```
  Cluster name:  overlay-l3-bgp
  Nodes:         1 control-plane + 1 worker
  Image:         kindest/node:v1.33.0
  CNI:           Cilium (kindnet disabled)
  kube-proxy:    disabled (eBPF replacement)
  Kubeconfig:    ./.kubeconfig/kubeconfig.yaml
```

## Cilium configuration

Cilium is installed with these key settings:

| Setting                      | Value    | Why                                   |
|------------------------------|----------|---------------------------------------|
| `kubeProxyReplacement`       | true     | Replace kube-proxy with eBPF          |
| `bgpControlPlane.enabled`    | true     | Enable BGP Control Plane              |
| `hubble.enabled`             | true     | Observe traffic flows                 |
| `hubble.relay.enabled`       | true     | Aggregate Hubble data across nodes    |
| `hubble.ui.enabled`          | true     | Web UI for Hubble                     |
| `ipam.mode`                  | kubernetes | Use K8s pod CIDR allocation         |
| `bpf.masquerade`             | true     | eBPF-based masquerading (perf)        |
| `devices`                    | {eth0,eth1} | BGP peering on eth1 needs BPF     |
| `directRoutingDevice`        | eth0     | Must be explicit with multiple devices |

## Failover testing

BGP failover time was measured using three isolation methods to understand
how the setup behaves under different failure scenarios.

### Methodology

1. **`docker kill <worker>`** — Instantly tears down the veth pair. FRR zebra
   receives immediate netlink notification and removes the dead nexthop from
   the FIB. Result: ~50ms failover. Unrealistic — no real failure behaves
   this way.

2. **`docker pause <worker>`** — Freezes all processes in the worker
   container, including cilium-agent. The eBPF data plane continues
   forwarding traffic via Geneve tunnel unaffected. Result: **zero packet
   loss**. Cilium's eBPF programs run in kernel space and survive user-space
   agent death.

3. **iptables isolation** — Simulates a network partition by adding
   `iptables -A INPUT -s 172.19.0.10 -j DROP` and
   `iptables -A OUTPUT -d 172.19.0.10 -j DROP` on the worker. FRR's TCP
   connection monitoring detects the path failure before the BGP hold timer
   expires. Result: ~5s failover detection, 1 dropped TCP connection during
   transition.

| Method | Failover time | Realism |
|--------|--------------|---------|
| `docker kill` | ~50ms | Low (veth teardown is instant) |
| `docker pause` | 0ms (no loss) | Medium (eBPF survives) |
| iptables DROP | ~5s | High (network partition) |

### BGP timers

FRR's hold timer was tuned from default 90s to 9s to reduce failover time:

```
neighbor 172.19.0.4 timers 3 9
```

Timer changes require a BGP session reset (`clear bgp 172.19.0.4`) to take
effect — timer negotiation occurs in the BGP OPEN message.

### BFD support

Cilium's BGP Control Plane does **not** support BFD in version 1.19.x. The
`CiliumBGPPeerConfig` CRD rejects BFD fields and does not expose timer
configuration. Alternatives for faster failover:

- Tune BGP timers (as above)
- Use FRR zebra's nexthop tracking (automatic on Linux)
- Deploy an external FRR router with BFD support as the BGP speaker

### Key takeaways

- Realistic failover testing requires simulating a network partition
  (iptables DROP), not killing or pausing the container.
- The eBPF data plane is independent of the cilium-agent user-space
  process — forwarding continues during agent failure.
- Without BFD, BGP hold timer (default 90s, tuned to 9s) determines failover
  upper bound.
- TCP failure detection can trigger faster than the hold timer (~5s in this
  test).

## Questions

*From `QUESTIONS.md` — a running list of architectural / operational
questions for this lab, with the current answer and a "why it matters" note.*

### 1. Will this setup leak route advertisements or peer with other nodes? Do we have authentication?

**Short answer: it won't leak today, but it has no auth.**

#### Why it doesn't leak

- **GoBGP is configured with two static neighbors** (`172.19.0.3`,
  `172.19.0.4`) in `gobgp/gobgpd.toml`. It does **not** listen for incoming
  connections (`port = 179` in the config is the *target* port it dials to,
  not a `listen` directive) and it does **not** run any auto-discovery /
  listen-range (e.g. no `bgp listen range` like FRR has). So it cannot
  accidentally accept a peer from a host on the Docker bridge.
- **Cilium is configured with one static peer** (`172.19.0.10` AS 65000) in
  `manifests/cilium-bgp.yaml` (`CiliumBGPClusterConfig/overlay-l3-bgp-bgp`).
  It is also an active-mode initiator with a fixed peer address — it won't
  accept an inbound session from an unknown neighbor either.
- The two speakers live on `bgp-net` (172.19.0.0/16), which is a dedicated
  bridge. To leak, a foreign container would need to be **attached to that
  exact network** (and know the static peer IPs), which is a host-local
  Docker action, not a network event.
- Routes are not exported to any other speaker (GoBGP `default-export-policy
  = "accept"` is scoped to the two configured neighbors, and Cilium has no
  other peers).

#### What is NOT set up (the risk surface)

- **No BGP TCP MD5 authentication.** `CiliumBGPPeerConfig/overlay-l3-bgp-default`
  has no `authSecretRef`; `gobgpd.toml` has no `auth-password` and no
  `[[neighbors.auth-password]]`. RFC 2385 (TCP MD5) is the standard BGP auth
  mechanism and it's off.
- **GoBGP `default-import-policy = "accept"`** — it will accept and install
  any route the two peers send, even malformed ones, with no prefix-list or
  RPKI validation.
- **GoBGP `default-export-policy = "accept"`** — if a second speaker were
  ever added, GoBGP would advertise its entire RIB to it.
- **No TTL / eBGP-multihop hardening beyond `ebgpMultihop: 1` on Cilium.**
  GoBGP side has no `ebgp-multihop` set explicitly.
- **`bgp-net` is plain bridge L2.** Anyone with access to the Docker daemon
  can `docker network connect bgp-net <any-container>` and impersonate either
  peer. On a multi-tenant host, that's a real concern.

#### Why it matters

A BGP speaker on a shared bridge without auth and with accept-all policies
is fine for a single-user laptop lab (the threat model is "I mess up my own
cluster"), but is **not safe** to run on a shared host, CI runner, or cloud
VM where other workloads can reach the Docker socket. A noisy neighbor or a
malicious container could:

1. Open a TCP/179 session to `172.19.0.3` or `172.19.0.4` and claim to be
   `172.19.0.10` (no MD5 check) → inject black-hole routes into Cilium →
   poison the cluster's egress for the prefix it advertises.
2. Accept inbound BGP from GoBGP if `bgp-net` is ever bridged outward and
   drain the PodCIDR routes to an external speaker.

#### Mitigations (status)

- ✅ **TCP MD5 auth (RFC 2385) — APPLIED.** `CiliumBGPPeerConfig/overlay-l3-bgp-default`
  references `authSecretRef: bgp-auth`, and the matching k8s Secret
  (in `kube-system`, key `password`) is created by `make bgp-auth-secret`.
  Both `[neighbors.config]` blocks in `gobgp/gobgpd.toml` set
  `auth-password = "..."`. The lab password is in plaintext in the toml and
  the Makefile default — fine for a local lab, replace before committing
  anywhere public. The default Makefile variable is `BGP_AUTH_PASSWORD`
  (override with `make bgp-auth-secret BGP_AUTH_PASSWORD=...`).
- 🟡 Replace `default-import-policy = "accept"` with a prefix-list that only
  allows `10.244.0.0/16` and `10.96.0.0/16` (the cluster's CIDRs).
- 🟡 Optionally enable RPKI validation on GoBGP.
- 🟡 Restrict `bgp-net` membership in `docker-compose.yml` (it's already
  exclusive via `external: true`, but no MAC/IP allowlist).

### 1a. Is it possible to add authentication?

**Yes — both sides support TCP MD5 (RFC 2385).**

- **Cilium side:** `CiliumBGPPeerConfig.spec.authSecretRef` references a k8s
  Secret in the BGP secrets namespace (default `kube-system`, configurable
  via `bgpControlPlane.secretNamespace.name`). The Secret must contain a key
  `password`. If the Secret is missing, Cilium logs an error and the session
  proceeds with an empty password (no auth, same as today) — so the Secret
  must be created *before* the PeerConfig references it.
- **GoBGP side:** `auth-password = "<value>"` under each `[neighbors.config]`
  block in `gobgpd.toml`. Plain string in the file (mount the file as a
  `docker-compose` secret or inject via env if you don't want it on disk).
- **No asymmetric config** — both ends must have the same password or the
  session will fail to come up; Cilium's failure mode is `dial: i/o timeout`
  (the OS-level TCP MD5 mismatch drops SYN segments silently).
- **Caveat:** TCP MD5 signs the TCP header, so the BGP source/destination IP
  seen by each side must match the configured peer address exactly. If you
  ever change the source interface (`transport.sourceInterface`) or use any
  form of address translation in front of the Cilium agent, the MD5 check
  will fail. In this lab both sides use the `bgp-net` IP directly, so this
  is fine.
- **Stronger options (not currently supported by both ends):** TCP-AO
  (RFC 5925) is the successor to MD5 but Cilium BGP and GoBGP only do MD5.
  For real production, use a dedicated underlay network (no shared L2).

**Status: applied.** See "Mitigations" above — `make bgp-auth-secret`
creates the k8s Secret and `gobgpd.toml` is committed with the matching
password. To rotate: edit the toml + `make bgp-auth-secret` with the new
value, then `make frr-down && make frr-up` and let Cilium reconcile.

### 2. Is Cilium in overlay (tunnel) mode? (answered)

**Yes, VXLAN.** `cilium status` reports `Network: Tunnel [vxlan]`.
Pod-to-pod on the same node uses direct routing; pod-to-pod across nodes
uses VXLAN encapsulation over the `kind` bridge. For L3 service
reachability from an external speaker, this means return traffic still
traverses Cilium's overlay — there is no "clean" routed path from GoBGP to
a pod IP without also enabling native routing in Cilium.

### 3. Is the setup isolated? (answered, partially)

- `bgp-net` (172.19.0.0/16) is exclusive to this project.
- The **kind Docker network is shared** with the `flux-cluster` cluster on
  the host (both end up on the same `kind` bridge with overlapping CIDRs).
  L2 reachability exists between `gobgp-*` nodes and
  `flux-cluster-control-plane`. Mitigate by giving each kind cluster a
  unique `--network-name` (not currently set in `kind.yaml`).

### 4. Will creating a LoadBalancer Service produce a BGP route?

**Yes, but only if a LoadBalancer IP is actually allocated.** The
`CiliumBGPAdvertisement/overlay-l3-bgp-advert` advertises
`Service/addresses: [LoadBalancerIP]`, and `kind` + plain Cilium do not
ship with a LoadBalancer IPAM controller. `kubectl expose ... --type=
LoadBalancer` will give `EXTERNAL-IP: <pending>` until you install
LB IPAM (`CiliumLoadBalancerIPPool`) or annotate the service manually.

When it does work, the route in GoBGP looks like:

```
10.96.<svc-ip>/32  next-hop 172.19.0.{3|4}  AS_PATH 65001  Origin i
```

ECMP happens when pods for the service are on both nodes, but only if
`externalTrafficPolicy: Cluster` (the default). With
`externalTrafficPolicy: Local`, a node withdraws its advertisement when it
has no local endpoint.

The `CiliumBGPAdvertisement` has no `selector` field, so it matches every
LoadBalancer service in the cluster — by design foot-gun for a multi-tenant
cluster; fine for a lab.

## Test client

A permanent Alpine-based test client (`test-client`) lives on a separate
subnet (`client-net`, 172.21.0.0/24) with FRR as its default gateway.
This provides an isolated client outside `bgp-net` for realistic end-to-end
testing.

### Topology

```
client-net (172.21.0.0/24, Docker bridge)

test-client (172.21.0.100/24, gw 172.21.0.10)
       │
       └── FRR speaker (172.21.0.10 eth1 + 172.19.0.10 eth0)
                │ ip_forward=1
                │
                ├── Cilium node worker (172.19.0.4) AS 65001
                └── Cilium node worker2 (172.19.0.5) AS 65001
```

Traffic flow:

1. `test-client` sends to LB VIP (172.19.0.200) → default gateway (FRR)
2. FRR forwards via BGP-learned route to one of the Cilium nodes
3. Cilium's DSR+Geneve delivers to the backend pod
4. Pod responds with the real client IP (DSR preserves it)
5. Return path: pod → Cilium node → FRR (via static route) → client

### Usage

```sh
make client-up        # Start the client (also adds routes on kind nodes)
make client-down      # Stop the client
make client-test      # curl the LB VIP from the client
docker exec -it test-client sh  # Interactive shell
```

### Requirements

For DSR return traffic, the kind nodes need a route to `client-net`:

```sh
docker exec overlay-l3-bgp-worker ip route add 172.21.0.0/24 via 172.19.0.10 dev eth1
```

This is handled automatically by `make client-up` (via the `client-route-add`
target). The route is not persistent across node restarts.

## Cleanup

```sh
make clean   # removes cluster + network
```

[kind]: https://kind.sigs.k8s.io
