# kind-native-routing-l3-lb-metallb

Local BGP networking lab using **Cilium BGP Control Plane + MetalLB BGP mode**
on a kind cluster, with both speakers running on the same nodes using
**different BGP ports and ASNs** to avoid port 179 conflicts.

## Motivation

Cilium's BGP Control Plane lacks BFD support (issue
[cilium/cilium#22394](https://github.com/cilium/cilium/issues/22394), open
since Nov 2022). MetalLB in BGP mode uses GoBGP which also lacks BFD in
released versions (PR
[cloudnativelabs/kube-router#2118](https://github.com/cloudnativelabs/kube-router/pull/2118)
is unmerged).

This lab explores a **dual-BGP-speaker** architecture where:

1. **Cilium BGP CP** (AS 65001, port 180) advertises PodCIDRs — the stable
   underlay that never changes
2. **MetalLB BGP speaker** (AS 65002, port 179) advertises Service
   LoadBalancer VIPs — the ephemeral overlay that comes and goes

Different ASNs let the external router (FRR2) apply **different routing
policies** to each: e.g., more aggressive BFD on the VIP path, different
LOCAL_PREF, or separate route-maps for traffic engineering.

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
                                         ├── overlay-nr-ml-cp     172.19.0.3  (no BGP)
                                         ├── overlay-nr-ml-worker 172.19.0.4
                                         │     Cilium BGP CP  AS 65001 :180
                                         │     MetalLB speaker AS 65002 :179
                                         └── overlay-nr-ml-worker2 172.19.0.5
                                               Cilium BGP CP  AS 65001 :180
                                               MetalLB speaker AS 65002 :179
```

### BGP peering matrix

| Speaker | Port | AS | Advertises | Peer |
|---------|------|----|------------|------|
| Cilium BGP CP (per worker) | 180 | 65001 | PodCIDRs (10.244.x.0/24) | FRR2 (AS 65000) |
| MetalLB BGP (per worker) | 179 | 65002 | Service VIPs (172.19.0.200-220) | FRR2 (AS 65000) |
| FRR2 TOR-Cluster | 179 | 65000 | All learned routes | FRR1 (AS 65100) |
| FRR1 TOR-Client | 179 | 65100 | client-net (172.21.0.0/24) | FRR2 |

### Route propagation

```
Cilium (AS 65001 :180) ──PodCIDRs──► FRR2 (AS 65000) ──► FRR1 ──► FIB
MetalLB (AS 65002 :179) ──VIPs────► FRR2 (AS 65000) ──► FRR1 ──► FIB
```

FRR2 learns PodCIDRs from AS 65001 and VIPs from AS 65002. It can apply
separate policies: e.g., prefer AS 65001 paths for pod traffic but
load-balance AS 65002 VIP paths across workers.

## The same-IP different-ASN problem

Two GoBGP instances on the same node work fine — they bind to different
ports (179 and 180) on the same IP, which Linux allows (different socket
tuples). **The constraint is on the receiving side (FRR2).**

FRR keys BGP neighbors by `(remote-as, remote-ip)`. You cannot have two
`neighbor` blocks with the same IP but different ASNs in the same BGP
instance — FRR rejects the second block as a duplicate. This is because
FRR treats the BGP connection as a single session per peer IP, and it
can't multiplex two independent AS sessions over one TCP connection.

**Example of what FRR rejects:**

```
neighbor 172.19.0.4 remote-as 65001   # Cilium
neighbor 172.19.0.4 remote-as 65002   # MetalLB — FRR rejects this
```

### VRF solution (recommended for this experiment)

FRR supports VRF (Virtual Routing and Forwarding) — separate routing
tables with independent BGP instances. Each VRF has its own neighbor
table, so the same peer IP can appear in both with different ASNs:

```
vrf cilium-bgp
  router bgp 65000 vrf cilium-bgp
    neighbor 172.19.0.4 remote-as 65001   # Cilium
    neighbor 172.19.0.4 port 180
    neighbor 172.19.0.5 remote-as 65001
    neighbor 172.19.0.5 port 180

vrf metallb-bgp
  router bgp 65000 vrf metallb-bgp
    neighbor 172.19.0.4 remote-as 65002   # MetalLB
    neighbor 172.19.0.5 remote-as 65002
```

The tradeoff: routes learned in one VRF don't automatically appear in
another. FRR2 needs to redistribute between VRFs (or use `import-vrf`)
to make both PodCIDRs and VIPs available to FRR1 and the host routing
table.

### Alternative: different IPs (simpler but more overhead)

Assign each worker a second bgp-net IP (e.g., 172.19.0.104 for Cilium,
172.19.0.4 for MetalLB). Both speakers bind to their respective IPs.
No VRF needed, but requires managing secondary IPs on kind nodes.

### Simplest: single speaker, no ASN split

Use MetalLB for IPAM only (`IPAddressPool` + no BGP advertisement) and
let Cilium BGP CP handle all advertising. No port/ASN conflict.
The different-ASN experiment is done with FRR VRF separately.

## Why different ASNs?

Different ASNs give FRR2 (and FRR1) **independent routing policy control**
over PodCIDRs vs VIPs:

- **LOCAL_PREF**: Prefer PodCIDR paths (AS 65001) over VIP paths (AS 65002)
- **Route-maps**: Apply prefix-lists only to AS 65002 (VIP) routes
- **BFD**: Enable sub-second detection only on the VIP path (AS 65002)
  while keeping default hold timers on PodCIDRs (AS 65001)
- **Community tags**: Tag routes by origin ASN for downstream policy

Without different ASNs, FRR2 treats all routes from the same peer as
equivalent — no way to differentiate policy by route type.

## Why different ports?

Both Cilium's GoBGP and MetalLB's GoBGP need to bind TCP port 179 on
the same node IP (e.g., `172.19.0.4:179`). Linux only allows one process
per socket tuple `(proto, srcIP, srcPort, dstIP, dstPort)`. Two GoBGP
instances cannot both bind `0.0.0.0:179`.

**Solution:** MetalLB keeps the default port 179. Cilium BGP CP uses port
180 (`--bgp-port=180` on kube-router, or Cilium's `CiliumBGPPeerConfig`
port field). FRR2 configures both ports per neighbor — this part works
fine since the ports distinguish the sessions.

## Components

### Cilium (CNI + BGP CP)

Same as `kind-native-routing-l3-lb`:
- `routingMode=native`, `devices={eth1}`
- `bgpControlPlane.enabled=true`
- `loadBalancer.mode=snat`
- `ipam.mode=kubernetes`
- BGP peering: AS 65001 → FRR2 (AS 65000) on **port 180**
- Advertises: PodCIDRs + Service VIPs (via `CiliumBGPAdvertisement`)

### MetalLB (LB IPAM + BGP speaker)

MetalLB runs as a DaemonSet on workers. In BGP mode it:
1. Allocates IPs from `IPAddressPool` (172.19.0.200-220)
2. Runs its own GoBGP instance per node
3. Advertises Service VIPs via BGP to configured peers

Key config:
- `L2Advertisement`: disabled (we want BGP, not L2)
- `BGPPeer`: FRR2 (172.19.0.10) AS 65000, from AS 65002
- `IPAddressPool`: 172.19.0.200-220

**Important**: MetalLB BGP speaker binds port 179. Cilium BGP CP must
use port 180 to coexist.

### FRR2 (TOR-Cluster, border router)

Dual-homed on bgp-net (172.19.0.10) and transit-net (172.23.0.2).
AS 65000. Peers with:

- Cilium on each worker: AS 65001, port 180, TCP MD5 auth
- MetalLB on each worker: AS 65002, port 179, no auth (MetalLB
  doesn't support TCP MD5 — known limitation)
- FRR1: AS 65100, port 179, transit-net

FRR2 config adds `neighbor <ip> port 180` for Cilium peers and
`no bgp ebgp-requires-policy` to accept routes without explicit policy.

### FRR1 (TOR-Client)

Same as other labs: AS 65100, single peer to FRR2, advertises
client-net for return path.

### Test client

Alpine on client-net (172.21.0.100), FRR1 as default gateway.
`make client-test` curls the LB VIP.

## Key differences from kind-native-routing-l3-lb-bfd

| Aspect | BFD lab | MetalLB lab |
|--------|---------|-------------|
| BGP speaker for VIPs | kube-router (custom build) | MetalLB BGP mode (released) |
| BGP speaker for PodCIDRs | kube-router | Cilium BGP CP |
| BFD support | Yes (GoBGP BFD via kube-router PR) | No (neither Cilium nor MetalLB support BFD yet) |
| Number of BGP stacks | 1 (kube-router handles both) | 2 (Cilium GoBGP + MetalLB GoBGP) |
| BGP ports | Both on 179 | Cilium on 180, MetalLB on 179 |
| ASNs | Single AS 65001 | Cilium AS 65001, MetalLB AS 65002 |
| TCP MD5 auth | Yes (kube-router ↔ FRR2) | Cilium: yes, MetalLB: no |
| Custom images | Yes (kube-router BFD branch) | No (stock MetalLB) |
| Complexity | Lower (single speaker) | Higher (two speakers, two ports) |

## File structure

```
kind-native-routing-l3-lb-metallb/
├── AGENTS.md                    # Architecture + design decisions
├── Makefile                     # Day-to-day commands
├── docker-compose.yml           # FRR1 + FRR2 + test client
├── kind.yaml                    # Cluster definition
├── assets/
│   ├── topology.mmd             # Mermaid topology source
│   └── topology.png             # Rendered diagram
├── frr/
│   ├── frr.conf                 # FRR2 config (peers Cilium :180 + MetalLB :179)
│   ├── frr1.conf                # FRR1 config
│   └── daemons                  # FRR daemon control
├── manifests/
│   ├── metallb.yaml             # MetalLB install (IPAddressPool + BGPPeer + BGP advertisement)
│   ├── cilium-bgp.yaml          # Cilium BGP CRDs (port 180)
│   ├── cilium-lb-pool.yaml      # CiliumLoadBalancerIPPool (if using Cilium LB IPAM)
│   └── svc-lb.yaml              # Sample LoadBalancer Service + Deployment
└── scripts/
    ├── kind-up.sh               # Create cluster, attach bgp-net, set default route
    ├── kind-down.sh             # Delete cluster
    └── install-cilium.sh        # Helm install Cilium
```

## Implementation plan

### Phase 1: Cluster + Cilium (reuse from existing lab)

1. Copy `kind.yaml`, `scripts/kind-up.sh`, `scripts/kind-down.sh`,
   `scripts/install-cilium.sh` from `kind-native-routing-l3-lb-bfd`
2. Change cluster name to `overlay-nr-ml-bgp`
3. Apply Cilium with `bgpControlPlane.enabled=true`
4. Apply Cilium BGP CRDs **with port 180**:
   ```yaml
   CiliumBGPPeerConfig:
     spec:
       families:
         - afi: ipv4
           unicast:
             advertisements:
               matchLabels:
                 advertise: bgp
       transport:
         tcp:
           port: 180    # <-- non-default to coexist with MetalLB
   ```
5. Verify: `kubectl exec -n kube-system ds/cilium -- cilium-dbg status`
6. Verify: Cilium BGP session to FRR2 on port 180

### Phase 2: MetalLB BGP mode

1. Install MetalLB via Helm:
   ```sh
   helm install metallb metallb/metallb -n metallb-system --create-namespace \
     --set speaker.frr.enabled=true
   ```
2. Apply MetalLB CRDs:
   ```yaml
   IPAddressPool:
     spec:
       addresses:
         - 172.19.0.200-172.19.0.220
   BGPPeer:
     spec:
       myASN: 65002
       peerASN: 65000
       peerAddress: 172.19.0.10
       # No TCP MD5 — MetalLB FRR doesn't support it
   BGPAdvertisement:
     spec:
       ipAddressPools:
         - metallb-ip-pool
   ```
3. Verify: MetalLB speaker pods running on workers
4. Verify: GoBGP sessions to FRR2 on port 179

### Phase 3: FRR2 config (VRF mode)

FRR2 uses separate VRFs for each BGP speaker, allowing the same peer IP
with different ASNs:

```frr
! Cilium VRF — peers on port 180, AS 65001
vrf cilium-bgp
  router bgp 65000 vrf cilium-bgp
    bgp router-id 172.19.0.10
    neighbor 172.19.0.4 remote-as 65001
    neighbor 172.19.0.4 port 180
    neighbor 172.19.0.4 description Cilium-worker
    neighbor 172.19.0.5 remote-as 65001
    neighbor 172.19.0.5 port 180
    neighbor 172.19.0.5 description Cilium-worker2
    address-family ipv4 unicast
      neighbor 172.19.0.4 activate
      neighbor 172.19.0.5 activate
      redistribute kernel

! MetalLB VRF — peers on port 179 (default), AS 65002
vrf metallb-bgp
  router bgp 65000 vrf metallb-bgp
    bgp router-id 172.19.0.10
    neighbor 172.19.0.4 remote-as 65002
    neighbor 172.19.0.4 description MetalLB-worker
    neighbor 172.19.0.5 remote-as 65002
    neighbor 172.19.0.5 description MetalLB-worker2
    address-family ipv4 unicast
      neighbor 172.19.0.4 activate
      neighbor 172.19.0.5 activate
      redistribute kernel

! Default VRF — FRR1 peer only
router bgp 65000
  neighbor 172.23.0.1 remote-as 65100
  address-family ipv4 unicast
    neighbor 172.23.0.1 activate
    redistribute vrf cilium-bgp
    redistribute vrf metallb-bgp
```

Routes learned in VRFs are redistributed into the default VRF so FRR1
(and the host routing table) can reach both PodCIDRs and VIPs.

**Note**: FRR VRF support requires Linux VRF devices (ip link add dev
cilium-bgp type vrf table 100). These are created in the FRR container's
network namespace.

### Phase 4: End-to-end test

```sh
make up                    # Full bring-up
make status                # Cluster healthy
make frr2-status           # All BGP sessions Established
make frr2-routes           # PodCIDRs from AS 65001, VIPs from AS 65002
make client-test           # HTTP 200 from test-client → LB VIP
```

### Phase 5: Policy experiments (optional)

With different ASNs established, test FRR2 route-maps:

```
route-map PODCIDR permit 10
  match as-path 65001
  set local-preference 200

route-map VIP permit 10
  match as-path 65002
  set local-preference 100
```

This gives PodCIDR routes higher preference than VIP routes on FRR2.

## Known limitations

1. **MetalLB BGP doesn't support TCP MD5** — the FRR-based speaker in
   MetalLB can't do RFC 2385 auth. Cilium BGP CP can. This means the
   MetalLB session is unauthenticated.

2. **Same-IP different-ASN neighbor conflict** — FRR rejects two neighbor
   blocks with the same IP but different ASNs in one BGP instance.
   Solved with FRR VRF: separate routing tables = separate neighbor
   tables = same IP, different ASNs. Alternative: assign secondary IPs.

3. **No BFD** — neither Cilium BGP CP nor MetalLB BGP supports BFD in
   released versions. For BFD, use the kube-router approach from the
   BFD lab instead.

4. **Port 180 is non-standard** — any firewall rules or monitoring that
   assumes BGP = port 179 will miss Cilium's sessions.

5. **MetalLB + Cilium LB IPAM conflict** — both can allocate LoadBalancer
   IPs. Disable Cilium's `CiliumLoadBalancerIPPool` and let MetalLB
   handle allocation exclusively.

## Network layout

Same as the BFD lab:

- **bgp-net** (172.19.0.0/16): FRR2 + kind nodes. FRR2 is default gateway.
- **transit-net** (172.23.0.0/24): FRR1 ↔ FRR2.
- **client-net** (172.21.0.0/24): FRR1 + test client.
- **Pod CIDR**: 10.244.0.0/16
- **Service CIDR**: 10.96.0.0/16
- **LB pool**: 172.19.0.200-220

## Make targets

```
  make up                  Full bring-up (idempotent)
  make cluster-up          Just the kind cluster
  make cilium-install      Install/upgrade Cilium
  make metallb-install     Install MetalLB via Helm
  make metallb-apply       Apply IPAddressPool + BGPPeer + BGPAdvertisement
  make bgp-apply           Apply Cilium BGP CRDs (port 180)
  make lb-pool-apply       Apply CiliumLoadBalancerIPPool (if using Cilium LB IPAM)
  make svc-apply           Apply sample LoadBalancer Service + Deployment
  make frr-up              Start both FRR speakers
  make frr1-up / frr2-up   Start individual FRR speakers
  make status              Check cluster health
  make frr2-status         FRR2 BGP summary (should show AS 65001 + AS 65002)
  make frr2-routes         FRR2 RIB
  make frr1-status         FRR1 BGP summary
  make frr1-routes         FRR1 RIB
  make client-test         curl LB VIP from test-client
  make down                Tear down
  make clean               Full cleanup
```
