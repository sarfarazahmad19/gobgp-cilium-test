# gobgp-kind-cilium

Local BGP networking lab running Cilium as a Kubernetes CNI with BGP Control
Plane, peered with an external BGP speaker over a shared Docker network.

```mermaid
flowchart LR
    subgraph bgp_net["gobgp-net (172.19.0.0/16)"]
        cp["gobgp-control-plane<br/>172.19.0.3 / AS 65001<br/>PodCIDR: 10.244.0.0/24"]
        wk["gobgp-worker<br/>172.19.0.4 / AS 65001<br/>PodCIDR: 10.244.1.0/24"]
        sp["frr-speaker<br/>172.19.0.10 / AS 65000<br/>FRR bgpd+zebra<br/>kernel FIB via zebra"]
    end

    cp -- "BGP session (TCP :179, TCP MD5 auth) --> advertises 10.244.0.0/24" --- sp
    wk -- "BGP session (TCP :179, TCP MD5 auth) --> advertises 10.244.1.0/24" --- sp

    style cp fill:#c9e6ff
    style wk fill:#c9e6ff
    style sp fill:#ffe6cc
```

## What this does

- Spins up a 2-node Kubernetes cluster (v1.33) using [kind][kind]
- Replaces the default CNI and kube-proxy with Cilium (eBPF)
- Enables Cilium's BGP Control Plane (AS 65001) to advertise Pod CIDRs and
  LoadBalancer Service IPs via BGP
- Uses Cilium's LB IPAM (`CiliumLoadBalancerIPPool`, range 172.19.0.200-220) to
  allocate LoadBalancer IPs — creating a `type: LoadBalancer` Service
  automatically produces a route in GoBGP's RIB
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
  make up              Full bring-up: cluster + cilium + auth + BGP CRDs + speaker
  make cluster-up      Bring up just the kind cluster (no cilium/frr)
  make down            Tear down the kind cluster (also stops frr speaker)
  make status          Show cluster nodes, containers, networks
  make ps              Show running containers
  make logs            Tail controller logs

  make cilium-install  Install or upgrade Cilium via Helm
  make cilium-status   Run `cilium status --brief`
  make hubble-ui       Port-forward Hubble UI to :12000

  make frr-up          Start the FRR speaker (background)
  make frr-down        Stop and remove the FRR speaker
  make gobgp-apply     Apply Cilium BGP CRDs to the cluster
  make gobgp-auth-secret  Create/update the k8s TCP MD5 secret
  make lb-pool-apply   Apply CiliumLoadBalancerIPPool for LB IPAM
  make frr-status      Show FRR BGP neighbor state (vtysh)
  make frr-routes      Show routes learned by FRR (RIB)

  make net-create      Create the shared gobgp-net network
  make net-rm          Remove the shared network

  make clean           Tear down cluster + remove network + wipe kubeconfig
  make kubeconfig      Print path to kubeconfig
```

## Network layout

```
  Port forwards:
    localhost:6443  →  kube-apiserver
    localhost:12000 →  Hubble UI

  Docker networks:
    gobgp-kind     172.20.0.0/16  Dedicated bridge for cluster management
                                  (isolated from other kind clusters)
    gobgp-net      172.19.0.0/16  Shared bridge for BGP peering

  Pod CIDR:     10.244.0.0/16
  Service CIDR: 10.96.0.0/16

  BGP participants (all on gobgp-net):
    gobgp-control-plane  172.19.0.3  AS 65001  PodCIDR: 10.244.0.0/24
    gobgp-worker         172.19.0.4  AS 65001  PodCIDR: 10.244.1.0/24
    frr-speaker          172.19.0.10 AS 65000
```

## BGP peering

Cilium's BGP Control Plane on each node peers with the FRR speaker over
the shared `gobgp-net` L2 bridge. Each kind cluster gets its own Docker
bridge (this one uses `gobgp-kind`) to avoid L2 exposure to other clusters
on the host. The speaker learns PodCIDR routes and installs them into the
kernel FIB via FRR's zebra daemon:

```
FRR RIB / kernel FIB:
  10.244.0.0/24 → 172.19.0.3  AS 65001    (gobgp-control-plane)
  10.244.1.0/24 → 172.19.0.4  AS 65001    (gobgp-worker)
  172.19.0.200/32 → 172.19.0.3 + 172.19.0.4  (ECMP, LoadBalancer IP)
```

### Manifests (`manifests/cilium-bgp.yaml`)

| Resource | Purpose |
|----------|---------|
| `CiliumBGPPeerConfig/gobgp-default` | Peer settings + IPv4 families with ad selector `advertise: bgp` |
| `CiliumBGPClusterConfig/gobgp-bgp` | BGP instance AS 65001, peer to 172.19.0.10 AS 65000 |
| `CiliumBGPAdvertisement/gobgp-advert` | Labeled `advertise: bgp`; advertises PodCIDR + Service LoadBalancerIP |
| `CiliumLoadBalancerIPPool/gobgp-lb-pool` | IP pool 172.19.0.200-220 for LB Service IP allocation (`cilium-lb-pool.yaml`) |


### FRR config (`frr/frr.conf`)

Local AS 65000, router ID 172.19.0.10. Two neighbors: 172.19.0.3
(gobgp-control-plane) and 172.19.0.4 (gobgp-worker), both AS 65001, TCP MD5
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

See [`findings.md`](findings.md) for ECMP behavior and endpoint health details.

## Cluster details

```
  Cluster name:  gobgp
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

## Cleanup

```sh
make clean   # removes cluster + network
```

[kind]: https://kind.sigs.k8s.io
