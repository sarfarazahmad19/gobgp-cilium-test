# QUESTIONS.md — open questions about gobgp-kind-cilium

A running list of architectural / operational questions for this lab, with
the current answer and a "why it matters" note. When an answer changes,
update the relevant code/docs in the same commit so this file doesn't rot.

---

## 1. Will this setup leak route advertisements or peer with other nodes on the larger network? Do we have authentication?

**Short answer: it won't leak today, but it has no auth.**

### Why it doesn't leak

- **GoBGP is configured with two static neighbors** (`172.19.0.3`, `172.19.0.4`)
  in `gobgp/gobgpd.toml`. It does **not** listen for incoming connections
  (`port = 179` in the config is the *target* port it dials to, not a
  `listen` directive) and it does **not** run any auto-discovery / listen-range
  (e.g. no `bgp listen range` like FRR has). So it cannot accidentally accept
  a peer from a host on the Docker bridge.
- **Cilium is configured with one static peer** (`172.19.0.10` AS 65000) in
  `manifests/cilium-bgp.yaml` (`CiliumBGPClusterConfig/gobgp-bgp`). It is
  also an active-mode initiator with a fixed peer address — it won't accept
  an inbound session from an unknown neighbor either.
- The two speakers live on `gobgp-net` (172.19.0.0/16), which is a dedicated
  bridge. To leak, a foreign container would need to be **attached to that
  exact network** (and know the static peer IPs), which is a host-local
  Docker action, not a network event.
- Routes are not exported to any other speaker (GoBGP `default-export-policy
  = "accept"` is scoped to the two configured neighbors, and Cilium has no
  other peers).

### What is NOT set up (the risk surface)

- **No BGP TCP MD5 authentication.** `CiliumBGPPeerConfig/gobgp-default` has
  no `authSecretRef`; `gobgpd.toml` has no `auth-password` and no
  `[[neighbors.auth-password]]`. RFC 2385 (TCP MD5) is the standard BGP
  auth mechanism and it's off.
- **GoBGP `default-import-policy = "accept"`** — it will accept and install
  any route the two peers send, even malformed ones, with no prefix-list or
  RPKI validation.
- **GoBGP `default-export-policy = "accept"`** — if a second speaker were
  ever added, GoBGP would advertise its entire RIB to it.
- **No TTL / eBGP-multihop hardening beyond `ebgpMultihop: 1` on Cilium.**
  GoBGP side has no `ebgp-multihop` set explicitly.
- **`gobgp-net` is plain bridge L2.** Anyone with access to the Docker
  daemon can `docker network connect gobgp-net <any-container>` and
  impersonate either peer. On a multi-tenant host, that's a real concern.

### Why it matters

A BGP speaker on a shared bridge without auth and with accept-all policies
is fine for a single-user laptop lab (the threat model is "I mess up my own
cluster"), but is **not safe** to run on a shared host, CI runner, or
cloud VM where other workloads can reach the Docker socket. A noisy
neighbor or a malicious container could:

1. Open a TCP/179 session to `172.19.0.3` or `172.19.0.4` and claim to be
   `172.19.0.10` (no MD5 check) → inject black-hole routes into Cilium →
   poison the cluster's egress for the prefix it advertises.
2. Accept inbound BGP from GoBGP if `gobgp-net` is ever bridged outward and
   drain the PodCIDR routes to an external speaker.

### Mitigations (status)

- ✅ **TCP MD5 auth (RFC 2385) — APPLIED.** `CiliumBGPPeerConfig/gobgp-default`
  references `authSecretRef: gobgp-auth`, and the matching k8s Secret
  (in `kube-system`, key `password`) is created by `make gobgp-auth-secret`.
  Both `[neighbors.config]` blocks in `gobgp/gobgpd.toml` set
  `auth-password = "..."`. The lab password is in plaintext in the toml and
  the Makefile default — fine for a local lab, replace before committing
  anywhere public. The default Makefile variable is `BGP_AUTH_PASSWORD`
  (override with `make gobgp-auth-secret BGP_AUTH_PASSWORD=...`).
- 🟡 Replace `default-import-policy = "accept"` with a prefix-list that only
  allows `10.244.0.0/16` and `10.96.0.0/16` (the cluster's CIDRs).
- 🟡 Optionally enable RPKI validation on GoBGP.
- 🟡 Restrict `gobgp-net` membership in `docker-compose.yml` (it's already
  exclusive via `external: true`, but no MAC/IP allowlist).

---

## 1a. Is it possible to add authentication?

**Yes — both sides support TCP MD5 (RFC 2385).**

- **Cilium side:** `CiliumBGPPeerConfig.spec.authSecretRef` references a k8s
  Secret in the BGP secrets namespace (default `kube-system`, configurable via
  `bgpControlPlane.secretNamespace.name`). The Secret must contain a key
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
  will fail. In this lab both sides use the `gobgp-net` IP directly, so this
  is fine.
- **Stronger options (not currently supported by both ends):** TCP-AO
  (RFC 5925) is the successor to MD5 but Cilium BGP and GoBGP only do MD5.
  For real production, use a dedicated underlay network (no shared L2).

**Status: applied.** See "Mitigations" above — `make gobgp-auth-secret`
creates the k8s Secret and `gobgpd.toml` is committed with the matching
password. To rotate: edit the toml + `make gobgp-auth-secret` with the new
value, then `make gobgp-down && make gobgp-up` and let Cilium reconcile.

---

## 2. Is Cilium in overlay (tunnel) mode? (answered)

**Yes, VXLAN.** `cilium status` reports `Network: Tunnel [vxlan]`. Pod-to-pod
on the same node uses direct routing; pod-to-pod across nodes uses VXLAN
encapsulation over the `kind` bridge (172.18.0.0/16). For L3 service
reachability from an external speaker, this means return traffic still
traverses Cilium's overlay — there is no "clean" routed path from GoBGP
to a pod IP without also enabling native routing in Cilium.

---

## 3. Is the setup isolated? (answered, partially)

- `gobgp-net` (172.19.0.0/16) is exclusive to this project.
- The **kind Docker network is shared** with the `flux-cluster` cluster on
  the host (both end up on the same `kind` bridge with overlapping CIDRs).
  L2 reachability exists between `gobgp-*` nodes and
  `flux-cluster-control-plane`. Mitigate by giving each kind cluster a
  unique `--network-name` (not currently set in `kind.yaml`).

---

## 4. Will creating a LoadBalancer Service produce a BGP route?

**Yes, but only if a LoadBalancer IP is actually allocated.** The
`CiliumBGPAdvertisement/gobgp-advert` advertises
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

---

## 5. (placeholder)

Add more questions here as they come up.
