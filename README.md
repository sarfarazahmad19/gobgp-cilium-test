# clab-dual-tor-kind

A containerlab lab that proves out **L3 dual-homing for Kubernetes worker nodes**:
each node eBGP-peers two Top-of-Rack switches (different ASNs), gets an ECMP default,
and advertises its Pod CIDRs / LoadBalancer VIPs into a spine-leaf Clos — with BFD
fast failover. K8s is a Kind cluster; CNI + BGP control plane is Cilium, with a
node-local FRR relaying routes to the fabric.

The payoff: a ToR can die and established TCP connections don't even reset. The
trade-offs, the relay design, and how it compares to MetalLB/frr-k8s are in
**[docs/architecture.md](docs/architecture.md)**.

```
  k8s-worker ──┬── rack1-tor-a (AS 65101) ──┐
               └── rack1-tor-b (AS 65102) ──┴─▶ spine-fabric ─▶ … ─▶ spine-border ─▶ k8s-control-plane
       (dual-homed, active-active ECMP)          rack2 mirrors with k8s-worker2
```

## What's in here

| Path | What |
|------|------|
| `clab-dual-tor-kind.clab.yml` | the containerlab topology (6 FRR fabric nodes + Kind cluster) |
| `configs/<node>/` | per-node FRR config (`frr.conf`, `daemons`) — one dir per node |
| `images/kind-node/` | custom Kind node image (FRR baked in) |
| `configs/cilium-bgp.yaml`, `configs/kind-config.yaml` | Cilium BGP CRs; Kind cluster config |
| `Justfile` | every workflow (build / deploy / cutover / cilium / per-node queries) |
| `docs/` | architecture, findings, design specs, topology, decision log |

## How to use

Requires containerlab 0.77+, Docker, `kind` 0.32+, `just`, ~4 GB RAM.

One-shot end-to-end bring-up:

```sh
just deploy-all       # build -> deploy -> cutover -> cilium-install -> cilium-bgp
```

Or step by step:

```sh
just build            # build the Kind node image (FRR baked in)
just deploy           # bring up the topology (fabric + Kind cluster)
just cutover          # move the cluster onto the fabric: copy FRR configs, assign
                      # fabric IPs, start FRR, repoint kubelets, API-server proxy,
                      # write the kubeconfig, and drop eth0 (pure fabric mode —
                      # egress then flows via the spine SNAT)

just cilium-install   # CNI + BGP control plane + Pod IP pool
just cilium-bgp       # apply the Cilium BGP CRs
```

Verify / demo:

```sh
just sessions         # BGP sessions across the fabric
just routes           # routing / BGP tables
just cilium-bgp-status
just pods
just cp-pool-test     # (demo) prove multi-pool IPAM — CP node draws from cp-pool
```

> `just cutover` already writes the kubeconfig (pointed at the spine-border proxy).
> The standalone `just kubeconfig` is only for the pre-fabric flow — running it after
> cutover overwrites the working one with kind's local endpoint.

Per-node helpers: `just k8s-worker-sessions`, `just rack1-tor-a-routes`,
`just spine-fabric-cmd "<vtysh cmd>"`, etc. Run `just` (or `just --list`) for all.

