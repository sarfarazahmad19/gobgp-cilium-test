# Finding: Cilium's 127.0.0.1 next-hop is rejected by FRR (martian) — routes not relayed

**Date:** 2026-07-20
**Severity:** High — Cilium-originated routes (Pod CIDR, LB VIPs) never reach the fabric
**Status:** Fixed (`bgp allow-martian-nexthop` + inbound next-hop rewrite on the Cilium peer)
**Affected nodes:** `k8s-worker/frr.conf`, `k8s-worker2/frr.conf`, `k8s-control-plane/frr.conf`

---

## Symptom

Cilium↔FRR BGP session is **Established**, Cilium reports the route as
**Advertised=1**, but FRR shows **0 accepted** and the prefix is `% Network not
in table`. Nothing propagates to the ToRs, so LoadBalancer VIPs / Pod CIDRs are
unreachable from the rest of the fabric.

```
# cilium bgp routes advertised ipv4 unicast   (Cilium side — it IS sending)
VRouter   Peer        Prefix           NextHop     Attrs
64512     127.0.0.1   10.99.100.1/32   127.0.0.1   [{Origin: i} {AsPath: 64512} {Nexthop: 127.0.0.1}]

# FRR side
worker1# show ip bgp 10.99.100.1/32
% Network not in table
worker1# show ip bgp neighbors 127.0.0.1     -> "0 accepted"
```

## Root cause

The Cilium↔FRR session runs over the loopback (`peerAddress: 127.0.0.1`, see
`03-frr-loopback-bgp-nexthop.md`). Cilium's embedded BGP speaker
therefore advertises every route with **NEXT_HOP = `127.0.0.1`** (the session's
local address). FRR rejects this in **two** independent stages:

1. **Attribute parsing — martian next-hop.** FRR treats a `127.0.0.0/8`
   next-hop as a *martian* and discards the entire UPDATE as malformed. Confirmed
   in `bgpd` debug (`debug bgp updates`):

   ```
   BGP: Martian nexthop 127.0.0.1
   BGP: 127.0.0.1 rcvd UPDATE with errors in attr(s)!! Withdrawing route.
   BGP: 127.0.0.1 withdrawing route 10.99.100.1/32 IPv4 unicast not in adj-in
   ```

   Because this happens during attribute validation — **before** any inbound
   route-map runs — an inbound `set ip next-hop` alone cannot rescue it.

2. **Next-hop tracking — inaccessible.** Even after step 1 is allowed (via
   `bgp allow-martian-nexthop`), the route is accepted but marked invalid:

   ```
   127.0.0.1 (inaccessible, import-check enabled) ... invalid, external
   Paths: (1 available, no best path)
   ```

   `127.0.0.1` is not a usable forwarding next-hop, so FRR marks the route
   invalid → not best → **not re-advertised** to the ToRs.

Both stages must be addressed. Fixing only one leaves the route either dropped
(only route-map) or invalid/no-best (only `allow-martian-nexthop`).

## Fix

Per K8s-node FRR config, on the Cilium neighbor:

```frr
router bgp 65001
  ...
  bgp allow-martian-nexthop            # (1) accept the 127.0.0.1 next-hop
!
route-map FROM-CILIUM permit 10
  description Rewrite Cilium loopback (127.0.0.1) next-hop to a reachable local IP so routes are valid/re-advertised
  set ip next-hop 10.99.255.1          # (2) node's dummy0 IP — a valid, connected next-hop
!
router bgp 65001
  address-family ipv4 unicast
    neighbor 127.0.0.1 route-map FROM-CILIUM in
```

Per-node `set ip next-hop` value (each node's advertised `dummy0` loopback):

| Node    | file                | set ip next-hop |
|---------|---------------------|-----------------|
| worker1 | `k8s-worker/frr.conf`   | `10.99.255.1`   |
| worker2 | `k8s-worker2/frr.conf`  | `10.99.255.2`   |
| cp      | `k8s-control-plane/frr.conf`       | `10.99.255.10`  |

The rewritten next-hop only needs to be a **valid, locally-reachable** address so
FRR marks the route best. When FRR re-advertises to the ToRs it applies
`next-hop-self` on each uplink, so the ToRs receive the correct **per-leg link
IP** as next-hop regardless (`10.99.0.0` via eth1, `10.99.0.2` via eth2 on
worker1) — this is what preserves the dual-leg (ECMP) reachability.

## Why not just peer over a real (non-loopback) address?

An alternative is to peer Cilium↔FRR over a dedicated dummy IP so the advertised
next-hop is naturally non-martian (this is likely what the original stale
`peerAddress: 10.99.255.254` intended). It was not pursued because:
- it requires assigning an extra address on every node **and** changing both
  `cilium-bgp.yaml` and every `frr.conf`, versus a contained FRR-only fix;
- any node-local address can still trip FRR's self/next-hop checks, so it is not
  obviously simpler;
- the loopback (`127.0.0.1`) peering is already the documented, working session
  model (finding 03).

## Verification

```sh
# Cilium is advertising
kubectl exec -n kube-system ds/cilium -- cilium bgp routes advertised ipv4 unicast

# FRR accepts + marks best + relays to both ToRs
docker exec k8s-worker vtysh -c "show ip bgp 10.99.100.1/32"
#   -> valid, external, best ; Advertised to peers: tor1-a, tor1-b

# ToRs learned it, next-hop = the worker's per-leg link IP
docker exec clab-dual-tor-kind-rack1-tor-a vtysh -c "show ip bgp 10.99.100.1/32"   # nexthop 10.99.0.0 (eth1)
docker exec clab-dual-tor-kind-rack1-tor-b vtysh -c "show ip bgp 10.99.100.1/32"   # nexthop 10.99.0.2 (eth2)
```

Expected: the same VIP/Pod CIDR present on **both** ToRs with distinct per-leg
next-hops — the "2 legs" carrying the K8s prefix into the fabric.

## Related

- `03-frr-loopback-bgp-nexthop.md` — why the session runs on `127.0.0.1` (`interface lo` + `update-source lo`)
- `../architecture.md` — the Cilium → FRR → ToR relay architecture
- `cilium-bgp.yaml` — `peerAddress: 127.0.0.1`, advertisements for `pod-cidr` / `lb-vip`

## Affected files

- `k8s-worker/frr.conf`, `k8s-worker2/frr.conf`, `k8s-control-plane/frr.conf` — `bgp allow-martian-nexthop`, `route-map FROM-CILIUM` + `neighbor 127.0.0.1 route-map FROM-CILIUM in`
