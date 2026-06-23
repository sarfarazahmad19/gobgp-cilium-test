# gobgp-kind-cilium

Local BGP networking lab running Cilium as a Kubernetes CNI with BGP Control
Plane, peered with an external BGP speaker over a shared Docker network.

```
                          Docker host
  +-------------------------------------------------------------+
  |                                                             |
  |   gobgp-net (bridge, 172.19.0.0/16)                         |
  |   +-------------------------------------------------------+ |
  |   |                                                       | |
  |   |   +-------------------+   +-------------------+       | |
  |   |   | gobgp-control-    |   | gobgp-worker      |       | |
  |   |   | plane             |   |                   |       | |
  |   |   | 172.19.0.4        |   | 172.19.0.3        |       | |
  |   |   |                   |   |                   |       | |
  |   |   |   kind node       |   |   kind node       |       | |
  |   |   |   K8s CP          |   |   K8s worker      |       | |
  |   |   |   + Cilium agent  |   |   + Cilium agent  |       | |
  |   |   |   + BGP (AS65001) |   |   + BGP (AS65001) |       | |
  |   |   |                   |   |                   |       | |
  |   |   +---------+---------+   +--------+----------+       | |
  |   |             |                      |                  | |
  |   |             |         BGP          |                  | |
  |   |             +----------+-----------+                  | |
  |   |                        |                              | |
  |   |                   +----+------+                       | |
  |   |                   | gobgp-    |                       | |
  |   |                   | speaker   |                       | |
  |   |                   | 172.19.0.10                       | |
  |   |                   | AS 65000  |                       | |
  |   |                   +-----------+                       | |
  |   +-------------------------------------------------------+ |
  |                                                             |
  |   Port forwards:                                            |
  |   localhost:6443  -->  kube-apiserver                       |
  |   localhost:12000 -->  Hubble UI                            |
  |   localhost:50051 -->  GoBGP gRPC API                       |
  +-------------------------------------------------------------+
```

## What this does

- Spins up a 2-node Kubernetes cluster (v1.33) using [kind][kind]
- Replaces the default CNI and kube-proxy with Cilium (eBPF)
- Enables Cilium's BGP Control Plane (AS 65001) to advertise Pod CIDRs and
  LoadBalancer Service IPs via BGP
- Runs a GoBGP speaker (AS 65000) on a shared Docker L2 bridge, peering with
  Cilium on every node
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
# Bring up the full lab (cluster + Cilium + BGP auth secret + CRDs + GoBGP speaker)
make up

# Check it's all healthy
make status
make cilium-status
make gobgp-status
make gobgp-routes

# Open Hubble UI
make hubble-ui
# Visit http://localhost:12000
```

## Make targets

```
  make up              Full bring-up: cluster + cilium + auth + BGP CRDs + speaker
  make cluster-up      Bring up just the kind cluster (no cilium/gobgp)
  make down            Tear down the kind cluster (also stops gobgp speaker)
  make status          Show cluster nodes, containers, networks
  make ps              Show running containers
  make logs            Tail controller logs

  make cilium-install  Install or upgrade Cilium via Helm
  make cilium-status   Run `cilium status --brief`
  make hubble-ui       Port-forward Hubble UI to :12000

  make gobgp-up        Start the GoBGP speaker (background)
  make gobgp-down      Stop and remove the GoBGP speaker
  make gobgp-apply     Apply Cilium BGP CRDs to the cluster
  make gobgp-auth-secret  Create/update the k8s TCP MD5 secret
  make gobgp-status    Show GoBGP neighbor state
  make gobgp-routes    Show routes learned by GoBGP

  make net-create      Create the shared gobgp-net network
  make net-rm          Remove the shared network

  make clean           Tear down cluster + remove network + wipe kubeconfig
  make kubeconfig      Print path to kubeconfig
```

## Network layout

```
  Host:127.0.0.1:6443  ---- kube-apiserver (in gobgp-control-plane)
  Host:127.0.0.1:12000 ---- Hubble UI (port-forward)
  Host:127.0.0.1:50051 ---- GoBGP gRPC API

  Docker networks:
    gobgp-net      172.19.0.0/16  Shared bridge for BGP peering
    kind           (internal)     Default kind network

  Pod CIDR:     10.244.0.0/16
  Service CIDR: 10.96.0.0/16

  BGP:
    GoBGP speaker:  172.19.0.10  AS 65000
    Cilium (all nodes):          AS 65001
```

## BGP peering

Cilium's BGP Control Plane on each node peers with the GoBGP speaker over
the shared `gobgp-net` L2 bridge:

```
  AS 65001 (Cilium)                       AS 65000 (GoBGP)
  +----------+
  | CP node  |---172.19.0.4:179---+
  +----------+                    |
                          +-------+--------+
  +----------+            | gobgp-speaker  |
  | worker   |---172.19.0.3:179---+        |
  +----------+            +----------------+
```

The GoBGP speaker learns PodCIDR routes (so external routers can reach pods)
and LoadBalancer Service IPs (so external traffic can hit K8s services).

### Manifests (`manifests/cilium-bgp.yaml`)

| Resource | Purpose |
|----------|---------|
| `CiliumBGPPeerConfig/gobgp-default` | Peer settings + IPv4 families with ad selector `advertise: bgp` |
| `CiliumBGPClusterConfig/gobgp-bgp` | BGP instance AS 65001, peer to 172.19.0.10 AS 65000 |
| `CiliumBGPAdvertisement/gobgp-advert` | Labeled `advertise: bgp`; advertises PodCIDR + Service LoadBalancerIP |


### GoBGP config (`gobgp/gobgpd.toml`)

Local AS 65000, router ID 172.19.0.10. Two neighbors: 172.19.0.4 and
172.19.0.3, both AS 65001. Default accept policy for import and export.

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

## Cleanup

```sh
make clean   # removes cluster + network
```

[kind]: https://kind.sigs.k8s.io
