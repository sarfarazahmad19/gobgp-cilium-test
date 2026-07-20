# Finding: FRR 8.4.4 leaves a stale kernel nexthop-group after ECMP link flap

**Date:** 2026-07-20
**Severity:** High — silently degrades dual-homing ECMP to a single path after a link flap
**Status:** Mitigated (`no zebra nexthop kernel enable` on K8s-node FRR); permanent fix = upgrade FRR to 10.x
**Affected nodes:** `k8s-worker`, `k8s-worker2`, `k8s-control-plane` (the three K8s nodes)
**Not affected:** fabric ToRs/spines (they run `frrouting/frr:latest` = 10.x)

---

## Symptom

Flapping `worker1` `eth1` (the uplink to `tor1-a`) down/up. The BGP session and
BFD to `tor1-a` came back fully, but the worker's kernel default route stayed
**single-nexthop** via `eth2` (`tor1-b`) only — the `eth1` path was never
re-added. ECMP dual-homing was silently degraded to one path.

```
# docker exec k8s-worker ip r
default nhid 25 via 10.99.0.3 dev eth2 proto bgp metric 20   # <-- only tor1-b
10.99.0.0/31 dev eth1 proto kernel scope link src 10.99.0.0
10.99.0.2/31 dev eth2 proto kernel scope link src 10.99.0.2
...
```

This is dangerous because everything **above** the kernel looks healthy:
BGP Established, BFD up, prefixes received, and even zebra's own RIB shows
correct 2-way ECMP. Only the kernel FIB is wrong, and nothing retries.

---

## Evidence — the control plane was fine, only the kernel was wrong

BGP session to `tor1-a` back up, 11 prefixes received, BFD up:

```
Neighbor          V         AS   MsgRcvd   MsgSent   Up/Down State/PfxRcd
tor1-a(10.99.0.1) 4      65101       974       976    00:01:26           11
tor1-b(10.99.0.3) 4      65102       965       973    00:47:28           11
```

BGP RIB has **2 multipath** for the default:

```
# vtysh -c "show ip bgp 0.0.0.0/0"
Paths: (2 available, best #2, table default)
  65101 65200
    10.99.0.1(tor1-a) ... valid, external, multipath
  65102 65200
    10.99.0.3(tor1-b) ... valid, external, multipath, best
```

zebra's RIB also has **both** nexthops and believes they are installed:

```
# vtysh -c "show ip route 0.0.0.0/0"
Routing entry for 0.0.0.0/0
  Known via "bgp", distance 20, metric 0, best
  * 10.99.0.1, via eth1, weight 1
  * 10.99.0.3, via eth2, weight 1
```

But the **kernel** nexthop objects tell the real story:

```
# docker exec k8s-worker ip nexthop show
id 25 group 27 proto zebra          # <-- ECMP group has ONLY member 27
id 26 via 10.99.0.1 dev eth1 ...     # eth1 member exists, but is NOT in group 25
id 27 via 10.99.0.3 dev eth2 ...     # eth2 member
```

zebra thinks group 25 = {26, 27} and marks it **Installed**:

```
# vtysh -c "show nexthop-group rib"
ID: 25 (zebra)
     Valid, Installed
     Depends: (26) (27)
           via 10.99.0.1, eth1 (vrf default), weight 1
           via 10.99.0.3, eth2 (vrf default), weight 1
```

So: **zebra's view (group 25 = {26,27}, Installed) does not match the kernel
(group 25 = {27}).** zebra considers the group already correctly installed and
never re-pushes it.

---

## Root cause

FRR/zebra programs ECMP via **kernel nexthop-group objects** (`RTM_NEWNEXTHOP`,
referenced by routes through an `nhid`). On the link flap:

1. When `eth1` went down, zebra updated group 25 in the kernel to `{27}` (drop
   the dead `eth1` member) — correct.
2. When `eth1` came back and BGP/BFD re-established, zebra recomputed the group
   back to `{26, 27}` in its own RIB and marked it Installed…
3. …but the corresponding `RTM_NEWNEXTHOP` **replace** of group 25 was either
   never issued or silently failed, leaving the kernel group at `{27}`. zebra
   has no reconciliation that catches the mismatch, so it never retries.

This is the FRR ECMP-on-link-flap reprogramming defect class, well documented
upstream:

- [FRR #15505](https://github.com/FRRouting/frr/issues/15505) — kernel routes not re-programmed on link flap when using ECMP
- [FRR #14481](https://github.com/FRRouting/frr/issues/14481) — zebra won't recover after a failed `RTM_NEWNEXTHOP`; it thinks the interface is already up and never re-tries the nexthop install
- [FRR #14160](https://github.com/FRRouting/frr/issues/14160) — multipath routes not installed after another interface flaps
- [FRR #7299](https://github.com/FRRouting/frr/issues/7299) — kernel routes go missing after interface flaps (only reproducible with ECMP)

### Why *this* lab hits it

- The K8s nodes run **FRR 8.4.4** — see "Why FRR 8.4.4" below. This is old
  (Nov 2022) and squarely in the affected range.
- We use ECMP (`maximum-paths 2`) on the worker↔ToR uplinks — the exact trigger.

### Ruled out: systemd-networkd

A related failure mode is `systemd-networkd` deleting foreign (FRR-created)
kernel nexthops
([scottstuff.net writeup](https://scottstuff.net/posts/2025/02/25/frr-vs-systemd-networkd/)).
Not our case — `systemctl is-active systemd-networkd` returns `inactive` in the
kind nodes. Ours is purely the zebra↔kernel nexthop-group desync.

---

## Why FRR 8.4.4 (and not 10.x like the fabric)

The K8s-node image installs FRR from Debian's default repo. `images/kind-node/Dockerfile`:

```dockerfile
FROM kindest/node:v1.33.0                 # Debian 12 (bookworm) base
RUN apt-get update && apt-get install -y frr frr-pythontools && ...
```

Bookworm's `frr` package is **8.4.4**, with no version pin — so the nodes get
whatever the distro ships. The clab fabric nodes are unaffected because the
topology pulls `frrouting/frr:latest` (10.x) directly.

---

## Immediate remediation (applied to worker1, live)

1. Heal the already-broken route by patching the kernel group directly:

   ```sh
   docker exec k8s-worker ip nexthop replace id 25 group 26/27
   ```

   Result — ECMP restored:

   ```
   default nhid 25 proto bgp metric 20
       nexthop via 10.99.0.1 dev eth1 weight 1
       nexthop via 10.99.0.3 dev eth2 weight 1
   ```

2. Prevent recurrence by telling zebra to stop using kernel nexthop objects:

   ```sh
   docker exec k8s-worker vtysh -c "configure terminal" -c "no zebra nexthop kernel enable"
   ```

Note: `clear ip bgp 10.99.0.1` did **not** fix it — zebra still saw group 25 as
Installed and issued no dplane update. The manual `ip nexthop replace` was
required to heal the stale group.

---

## Recommended fix — `no zebra nexthop kernel enable`

Add to the FRR config on all three K8s nodes (`k8s-worker/frr.conf`,
`k8s-worker2/frr.conf`, `k8s-control-plane/frr.conf`):

```frr
no zebra nexthop kernel enable
```

This makes zebra program **classic inline-multipath routes** (nexthops carried
directly in the route, replaced atomically by the kernel) instead of separate
kernel nexthop-group objects. It sidesteps the entire stale-`nhid` class. This
is the community-adopted workaround and is documented as low-impact for
deployments that don't use nexthop-tracking or policy-based routing — which is
us. It also preserves the atomic-replacement property we migrated to FRR for in
the first place (see `../archive/02-findings-bird3-vs-frr-ecmp-convergence.md`).

Because `frr.conf` on the K8s nodes is copied in at cutover
(`just copy-frr-configs`) and loaded via `systemctl restart frr`, persisting the
line into the three files makes it survive `deploy`/`cutover`.

---

## Permanent fix — upgrade K8s-node FRR to 10.x

The `no zebra nexthop kernel enable` workaround is correct, but the cleaner
long-term fix is to stop shipping a 2022-era FRR on the K8s nodes and match the
fabric's 10.x. FRR's reprogramming/reconciliation logic improved substantially
after 8.4; keep the workaround as belt-and-suspenders regardless.

### Option A (recommended): install from FRR's official apt repo

Edit `images/kind-node/Dockerfile` to use `deb.frrouting.org` instead of Debian's
package:

```dockerfile
FROM kindest/node:v1.33.0

RUN apt-get update && apt-get install -y curl gnupg lsb-release && \
    curl -fsSL https://deb.frrouting.org/frr/keys.gpg \
        -o /usr/share/keyrings/frrouting.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/frrouting.gpg] \
https://deb.frrouting.org/frr $(lsb_release -s -c) frr-stable" \
        > /etc/apt/sources.list.d/frr.list && \
    apt-get update && apt-get install -y frr frr-pythontools && \
    sed -i 's/^bgpd=.*/bgpd=yes/'   /etc/frr/daemons && \
    sed -i 's/^bfdd=.*/bfdd=yes/'   /etc/frr/daemons && \
    sed -i 's/^staticd=.*/staticd=yes/' /etc/frr/daemons

COPY images/kind-node/frr-start.service /etc/systemd/system/frr-start.service
RUN systemctl enable frr-start.service
```

Notes:
- `$(lsb_release -s -c)` resolves to `bookworm` on the current kind base; pin it
  literally if `lsb-release` is undesirable.
- `frr-stable` tracks the latest FRR stable (10.x). Pin a specific train
  (e.g. `frr-10.2`) if reproducibility matters more than latest.
- Rebuild and redeploy:

  ```sh
  just build      # rebuild kind-node-with-frr with FRR 10.x
  just destroy && just deploy
  just cutover    # copy-frr-configs + assign-ips + start-frr + kubelets + proxy
  ```

- Verify: `docker exec k8s-worker vtysh -c "show version"` should report
  FRR 10.x.

### Option B: keep 8.4.4, rely only on the workaround

Lower-effort but leaves the nodes on an EOL FRR. Acceptable for a lab; not
recommended if this topology is a template for anything longer-lived.

### Regression test after either fix

```sh
# flap the uplink and confirm the kernel keeps BOTH nexthops
docker exec k8s-worker ip link set eth1 down
sleep 3
docker exec k8s-worker ip link set eth1 up
sleep 5
docker exec k8s-worker ip route show default   # expect 2 nexthops
docker exec k8s-worker ip nexthop show          # group must list both members
```

---

## Affected / changed files

- `k8s-worker/frr.conf`, `k8s-worker2/frr.conf`, `k8s-control-plane/frr.conf` — add `no zebra nexthop kernel enable`
- `images/kind-node/Dockerfile` — (Option A) install FRR 10.x from `deb.frrouting.org`
