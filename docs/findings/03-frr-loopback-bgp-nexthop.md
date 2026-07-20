# Finding: FRR requires `interface lo` + `update-source lo` for loopback BGP peering with Cilium

**Date:** 2026-07-20
**Severity:** High — prevents BGP sessions on 127.0.0.1
**Status:** Fixed

## What

FRR's bgpd calls `getsockname()` on accepted loopback TCP connections, then
queries Zebra to resolve which interface the local address belongs to. For
127.0.0.1, Zebra cannot resolve the interface unless `interface lo` is
explicitly present in the FRR configuration. Without it, `nexthop_set` fails
and FRR immediately resets the connection with:

```
nexthop_set failed, resetting connection - intf (Unknown)
bgp_connect_success: bgp_getsockname(): failed for peer 127.0.0.1
```

The fix is two-fold:

```frr
interface lo
!
router bgp 65001
  neighbor 127.0.0.1 remote-as 64512
  neighbor 127.0.0.1 passive
  neighbor 127.0.0.1 update-source lo
```

Both `interface lo` and `update-source lo` are required. `interface lo` ensures
Zebra tracks the loopback interface. `update-source lo` explicitly sets the
source interface, bypassing any remaining `getsockname()` resolution issues.

## Why this matters

Cilium BGP connects to a local BGP speaker (FRR) on 127.0.0.1 to avoid
routing loops and to keep the peering independent of the fabric topology.
Without this fix, Cilium BGP sessions on loopback silently fail with
`nexthop_set` errors while regular fabric BGP sessions on physical
interfaces work fine.

## Comparison with Bird3

Bird3 does not call `getsockname()` + interface resolution for passive BGP
connections on loopback. It simply accepts the TCP connection and proceeds
with BGP OPEN negotiation. An identical Bird3 setup (`passive on` on
127.0.0.1) works without any special interface configuration.

## Detection

Look for these in FRR debug logs:

```
debug bgp neighbor-events
```

```
nexthop_set failed, resetting connection - intf (Unknown)
bgp_getsockname(): failed
%NOTIFICATION: sent to neighbor 5/0 (Neighbor Events Error/Unspecific)
```

From Cilium side, `cilium bgp peers` shows perpetual `idle` state with
brief `active` flashes (connect → immediate FRR reset).

## Affected files

- `k8s-control-plane/frr.conf`
- `k8s-worker/frr.conf`
- `k8s-worker2/frr.conf`
