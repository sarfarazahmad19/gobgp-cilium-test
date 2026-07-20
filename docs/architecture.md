# Architecture — dual-homing K8s workers (Cilium ↔ FRR ↔ fabric)

The goal of this lab: prove **L3 dual-homing for Kubernetes worker nodes** — a node
with two independent uplinks (to two different ToRs) that survives losing either one
without dropping traffic or connections, using routing (eBGP/ECMP + BFD) rather than
L2 (bonds/MC-LAG). This doc covers why the design works, what it costs, and how the
Cilium→FRR→fabric route relay is wired.

## Fabric overview

Two racks; a **fabric spine** (hub for all four ToRs) and a **border spine**
(control-plane uplink + SNAT egress). All fabric IPs in `10.99.0.0/16`.

```
                  internet / mgmt bridge  172.20.20.0/24
                     ▲ eth0 (SNAT)                 ▲ eth0 (SNAT)
              ┌──────┴───────────┐  inter-spine   ┌┴───────────────────┐
              │   spine-fabric   │◄══ 10.99.0.8 ══►│   spine-border      │
              │    AS 65200      │      /31        │    AS 65201         │
              │ (hub: 4 ToRs,    │                │ (cp uplink + SNAT)  │
              │  default-orig)   │                └──────────┬──────────┘
              └─┬────┬─────┬────┬┘                      eth2 │
            eth1│eth2│ eth4│ eth5                            │
                │    │     │    │                 ┌──────────┴─────────┐
        ┌───────┘    │     │    └───────┐         │ k8s-control-plane  │
  ┌─────┴─────┐┌─────┴────┐┌─────┴─────┐┌─────────┴─┐  Kind, AS 65001  │
  │rack1-tor-a││rack1-tor-b││rack2-tor-a││rack2-tor-b│  single-homed    │
  │ AS 65101  ││ AS 65102  ││ AS 65101  ││ AS 65102  │──────────────────┘
  └──┬─────┬──┘└─┬──────┬──┘└──┬─────┬──┘└─┬──────┬──┘
     │     │     │      │      │     │     │      │
     └──┬──┴─────┘      │      └──┬──┴─────┘      │
    ┌───┴──────────┐    │     ┌───┴──────────┐    │
    │  k8s-worker  │    │     │  k8s-worker2 │    │
    │  AS 65001    │    │     │  AS 65001    │    │
    │ (dual-homed) │          │ (dual-homed) │
    └──────────────┘          └──────────────┘
          RACK 1                    RACK 2
```

Node names are consistent across config dir, FRR hostname, clab node key, and
container name (fabric containers prefixed `clab-dual-tor-kind-`; kind cluster `k8s`).
Full node table + per-interface addressing: [TOPOLOGY.md](TOPOLOGY.md).

## Wins

- **True active-active ECMP to both ToRs.** FRR programs a genuine two-nexthop
  default (both uplinks forwarding, not primary/backup). Pod/LB prefixes are
  advertised out **both legs**, so the fabric ECMPs toward the node too — both
  directions use both uplinks.

- **A ToR can die and TCP doesn't even RST.** BFD detects a dead ToR in ~150 ms;
  FRR then *atomically* swaps the ECMP nexthop group in the kernel (single
  `RTM_NEWROUTE`/`NLM_F_REPLACE`) — no transient "no route" gap (the reason we left
  Bird3). In-flight flows re-hash onto the surviving leg instead of resetting.
  Failover is a reroute, not a reset.

- **Maglev consistent-hash backend LB.** With Cilium's eBPF kube-proxy replacement
  using Maglev (`loadBalancer.algorithm=maglev`), service→backend selection is stable
  across backend-set changes *and consistent across nodes*. So when traffic re-hashes
  to the surviving ToR and lands on a different node, that node picks the **same**
  backend — the connection keeps flowing. ECMP + Maglev turns a link failure into a
  non-event for established connections.

- **More packets-per-second headroom.** eBPF datapath (no `iptables`/kube-proxy
  scaling wall), native routing (no overlay/encap tax), and two active uplinks per
  node → more PPS per node and per rack, bandwidth across both legs rather than one.

## Limitations

The intrinsic cost of dual-homing workers this way (L3 / eBGP + on-node FRR relay for
Cilium) — trade-offs of the *approach*, not this lab's topology:

- **Every worker becomes a router.** Per-node BGP daemon peering both ToRs *and* the
  local CNI — routing config, an ASN plan, and a routing stack to operate/monitor on
  every host. Heavier than an L2/bonded-NIC or MC-LAG approach that keeps the host dumb.
- **CNI ↔ host-routing coordination is delicate.** FRR owns the kernel ECMP default,
  Cilium owns pod routing; the `table-map KERNEL-FIB` (default-only) split must be
  exact or the two contend for the FIB. Correct-by-careful-config, not a robust boundary.
- **On-node BGP peering needs workarounds.** Cilium+FRR share the netns → loopback
  peering → `bgp allow-martian-nexthop` + inbound next-hop rewrite, weakening next-hop
  validation for the whole instance. Inherent to the relay.
- **Failover correctness lives in the host routing stack.** "No RST on ToR loss" holds
  only if the daemon atomically reprograms the kernel ECMP group — exactly where FRR had
  a real bug (finding 04). Only as good as the node's route programming, per FRR version.
- **Connection preservation is conditional.** Also needs stable backends across nodes
  (Maglev + `externalTrafficPolicy: Cluster`); rollouts / `eTP: Local` weaken it, and
  SNAT LB mode drops client source IPs.
- **Per-flow ECMP, not per-packet.** Redundancy + aggregate throughput, but a single
  flow pins to one leg. Resilience + fan-out, not single-connection speedup.
- **Route/ASN scale.** Dual-homing every worker + advertising each node's Pod/LB
  prefixes grows fabric prefix count and demands an ASN plan (2-byte private space is
  finite) — a scaling concern as node count climbs.

## The relay — Cilium → FRR → fabric

Two eBGP hops. The first is **entirely on-node** (loopback); the second fans the same
routes out **both uplinks** so either ToR can carry the traffic.

```
  Cilium (AS 64512, GoBGP)             k8s-worker (node)
      │  ① loopback eBGP (127.0.0.1)   — never leaves the node
      ▼
  FRR (AS 65001) ──② eBGP eth1──▶ rack1-tor-a (AS 65101) ─┐
                 └─② eBGP eth2──▶ rack1-tor-b (AS 65102) ─┴─▶ spine-fabric ──▶ fabric
                        └──── the "2 legs": active-active ECMP ────┘
```

Worker-side close-up:

```
                     ┌─────────────── k8s-worker (AS 65001) ────────────────┐
                     │                                                       │
  Cilium (AS 64512) ─┤ 127.0.0.1 BGP ▶ FRR  (receive-only out to Cilium)     │
                     │                    │                                  │
                     │  dummy0 10.99.255.1/32  (node loopback, advertised)   │
                     │                    │                                  │
                     │        eth1 10.99.0.0/31      eth2 10.99.0.2/31        │
                     └────────────┼──────────────────────┼───────────────────┘
                                  ▼                       ▼
                            rack1-tor-a              rack1-tor-b
                             (AS 65101)               (AS 65102)

  kernel default = ECMP { via rack1-tor-a , via rack1-tor-b }   ← active-active
  BFD 50ms×3 (~150ms) per leg; FRR atomic ECMP re-program on a leg drop
```

### Hop ① — Cilium → local FRR (loopback eBGP)

- Cilium runs its own BGP speaker (GoBGP) inside the agent, in the host netns, as
  **AS 64512**. It peers the node's local **FRR (AS 65001)** over **`127.0.0.1`** — the
  session never leaves the node. Cilium advertises **PodCIDR** and **LB VIPs**.

Config (`cilium-bgp.yaml`):
- `CiliumBGPClusterConfig` — `localASN: 64512`, `peerAddress: 127.0.0.1`,
  `peerASN: 65001`, `nodeSelector: kubernetes.io/os=linux` (every node).
- `CiliumBGPAdvertisement` (`pod-cidr`) — `advertisementType: PodCIDR`.
- `CiliumBGPAdvertisement` (`lb-vip`) — `advertisementType: Service`, `LoadBalancerIP`,
  selecting Services labeled `bgp-advertise: lb`.

Config (`configs/k8s-worker/frr.conf`, mirrored on the other two K8s nodes):
```frr
interface lo
!
route-map FROM-CILIUM permit 10
  set ip next-hop 10.99.255.1          # node's dummy0 IP (.2 / .10 on the others)
!
router bgp 65001
  bgp allow-martian-nexthop            # accept Cilium's 127.0.0.1 next-hop
  neighbor 127.0.0.1 remote-as 64512
  neighbor 127.0.0.1 passive           # FRR waits; Cilium initiates
  neighbor 127.0.0.1 update-source lo  # required for loopback peering
  address-family ipv4 unicast
    neighbor 127.0.0.1 route-map FROM-CILIUM in   # rewrite next-hop -> valid local IP
    neighbor 127.0.0.1 route-map TO-CILIUM out    # advertise nothing back (receive-only)
```

> **`interface lo` + `update-source lo`** — without them FRR fails
> `getsockname()`/nexthop resolution on the loopback connection and resets. See
> `findings/03-frr-loopback-bgp-nexthop.md`.
> **`allow-martian-nexthop` + `FROM-CILIUM in`** — Cilium's `127.0.0.1` next-hop is
> rejected as martian *and* inaccessible; the knob gets the UPDATE past attribute
> parsing and the route-map rewrites the next-hop to a reachable local IP so it's valid
> and re-advertised. See `findings/05-cilium-frr-martian-nexthop.md`.

### Hop ② — FRR → both ToRs (fabric eBGP, the "2 legs")

FRR re-advertises the Cilium-learned routes to its ToR peers — out **both** `eth1`
(→ rack1-tor-a) and `eth2` (→ rack1-tor-b):

```frr
router bgp 65001
  no bgp ebgp-requires-policy          # eBGP re-advertisement w/o explicit policy
  neighbor 10.99.0.1 next-hop-self     # leg 1: nexthop = this worker
  neighbor 10.99.0.3 next-hop-self     # leg 2: nexthop = this worker
```

`next-hop-self` rewrites the next-hop to FRR's own `/31` link IP per leg, so each ToR
forwards return traffic to this node over the connected link. Advertising out both legs
gives the fabric **dual-path (ECMP) reachability** to the node's Pods/VIPs.

### What does NOT flow back to Cilium

FRR advertises **nothing** to Cilium (`route-map TO-CILIUM deny 10`, no match =
deny-all, applied `out`). Cilium is announce-only; the node kernel already has its
default via FRR (through `table-map KERNEL-FIB`, default-only).

## Relation to MetalLB / frr-k8s (split-FRR)

Delegating fabric BGP to a **node-local FRR** is a common, endorsed pattern —
MetalLB's [split-FRR proposal](https://github.com/metallb/metallb/blob/main/design/splitfrr-proposal.md)
(`frr-k8s`) is its canonical form. This lab shares the *spirit* but differs in
*mechanism*, and that difference explains the loopback workarounds:

| | MetalLB + frr-k8s | This lab (Cilium relay) |
|---|---|---|
| FRR instances per node | one **shared** | one FRR **+** Cilium's own GoBGP |
| How routes reach FRR | consumers write `FRRConfiguration` **CRDs**; frr-k8s merges → FRR | Cilium GoBGP **eBGP-peers FRR over `127.0.0.1`** |
| Intra-host BGP session | **none** | **yes** (two speakers on loopback) |
| Workarounds | none | `allow-martian-nexthop` + next-hop rewrite |

**Who's the load balancer?** Two jobs:
- **Control plane** (allocate a Service VIP + announce it): MetalLB does this and hands
  prefixes to frr-k8s. Here, Cilium does it (`CiliumLoadBalancerIPPool` + its BGP).
- **Data plane** (spread connections across backend pods): MetalLB has **none** — it's
  kube-proxy or the CNI. Here it's Cilium's eBPF datapath, where **Maglev** lives.
  MetalLB alone can't give you the connection-preserving-failover win.

**Pod CIDR announcement.** MetalLB announces *only* Service VIPs — pods stay behind the
node. Advertising pod CIDRs (for **native routing**, fabric → pod directly) is a *CNI*
decision (Calico/Cilium BGP). To make frr-k8s do it you'd add an `FRRConfiguration` with
`redistribute kernel` scoped to the pool — FRR then just mirrors whatever Cilium
programmed into the kernel (via `cilium_host`), staying dumb and IPAM-unaware.

**Why this stack is "best of both."** Pod IPs here come from **Cilium multi-pool IPAM**
(`CiliumPodIPPool`), not Kubernetes — K8s' built-in IPAM only slices one `--cluster-cidr`
per node, no multi-pool / per-DC concept. So you get split pools per datacenter/tenant
*and* FRR's BGP/BFD/ECMP, with a clean seam: **Cilium owns allocation, FRR owns
announcement.** Caveat: with multi-pool, `node.spec.podCIDR` (the kube value, e.g.
`10.99.42.0/24`) is **not** what pods use (`10.99.40.0/22`) — pod-CIDR announcement must
come from the kernel/`CiliumNode`, never from `node.spec.podCIDR`.

## Addressing recap (per node)

| Element | Value (k8s-worker) |
|---|---|
| Cilium ASN | 64512 |
| FRR ASN (node) | 65001 |
| Loopback peering | `127.0.0.1` |
| Leg 1 — eth1 → rack1-tor-a (AS 65101) | `10.99.0.0/31` |
| Leg 2 — eth2 → rack1-tor-b (AS 65102) | `10.99.0.2/31` |
| Node loopback (advertised) | `10.99.255.1/32` (dummy0) |
| Pod CIDR pool | `10.99.40.0/22`, /24 per node |
| LB VIP pools | `10.99.100.0/28`, `10.99.101.0/28` |

k8s-worker2 mirrors with shifted addresses (rack2-tor-a/b, `10.99.0.16/31` +
`10.99.0.18/31`, loopback `10.99.255.2/32`). k8s-control-plane is single-homed to
spine-border.

## Verify the full relay

```sh
just cilium-bgp-status                                  # ① Cilium↔FRR Established
docker exec k8s-worker vtysh -c "show ip bgp"           # ① Pod CIDR / LB VIP in FRR
docker exec clab-dual-tor-kind-rack1-tor-a vtysh -c "show ip bgp"   # ② leg 1
docker exec clab-dual-tor-kind-rack1-tor-b vtysh -c "show ip bgp"   # ② leg 2
just cilium-routes                                      # Cilium's announced view
```

Expect the same Pod CIDR (e.g. `10.99.40.0/24`) on **both** ToRs, each with the worker's
respective `/31` link IP as next-hop — the "2 legs" in action.

## Related docs

- [TOPOLOGY.md](TOPOLOGY.md) — full fabric addressing / ASNs
- [findings/](findings/) — 03 (loopback peering), 04 (ECMP stale nexthop-group), 05 (martian next-hop)
- [DECISION-LOG.md](DECISION-LOG.md) — architectural decision chronology
