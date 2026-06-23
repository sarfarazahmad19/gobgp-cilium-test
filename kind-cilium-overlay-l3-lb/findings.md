# Findings — bgp-kind-cilium lab

Operational and behavioral notes accumulated while building and exercising the
lab. Each entry explains a behavior, why it happens, and what to do about it.

---

## F1. Service VIP is advertised by BGP even when no endpoints exist

**What we saw:**
- Created `Service/test-lb` (`type: LoadBalancer`, no matching pods).
- Cilium allocated a `LoadBalancer` IP from `CiliumLoadBalancerIPPool/overlay-l3-bgp-lb-pool`
  (e.g. `172.19.0.200`).
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

**Related:** [QUESTIONS.md §4 — Will creating a LoadBalancer Service
produce a BGP route?](../QUESTIONS.md) covers the IP-allocation side of
this; this finding covers the endpoint-orthogonal side.

---

## F2. ECMP next-hops from both nodes is by design

**What we saw:**
- `docker exec frr-speaker vtysh -c "show bgp ipv4 unicast"` shows the
  same Service prefix with two next-hops: `172.19.0.3` and `172.19.0.4`.

**Why:** Every node in the cluster runs a Cilium BGP instance
(`nodeSelector: {}` in `CiliumBGPClusterConfig/overlay-l3-bgp-bgp`), each peers with
FRR at `172.19.0.10` AS 65000, and each advertises the same Service
because the `CiliumBGPAdvertisement` has no per-node selector. FRR
receives two equal-cost paths and installs both as ECMP next-hops.

**When you DON'T want this:** set `externalTrafficPolicy: Local` on the
Service. A node withdraws its advertisement when it has no local endpoint,
so traffic only lands on a node that has a pod. From FRR's RIB the
route appears from one node only (the one with the local pod).

**Related:** [F1](#f1-service-vip-is-advertised-by-bgp-even-when-no-endpoints-exist).

---

## F3. Verifying a BGP route end-to-end

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

---

## F4. (placeholder)

Add more findings as they surface.
