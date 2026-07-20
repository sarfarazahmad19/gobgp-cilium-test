CLAB := "clab-dual-tor-kind.clab.yml"

# Pinned tool versions fetched by `just get-binaries` into bin/ (git-ignored).
JUST_VERSION := "1.55.1"
CLAB_VERSION := "0.77.0"

# Container names. Fabric = clab-dual-tor-kind-<node>; K8s = kind cluster "k8s".
K8S_WORKER := "k8s-worker"
K8S_WORKER2 := "k8s-worker2"
K8S_CP := "k8s-control-plane"
RACK1_TOR_A := "clab-dual-tor-kind-rack1-tor-a"
RACK1_TOR_B := "clab-dual-tor-kind-rack1-tor-b"
RACK2_TOR_A := "clab-dual-tor-kind-rack2-tor-a"
RACK2_TOR_B := "clab-dual-tor-kind-rack2-tor-b"
SPINE_FABRIC := "clab-dual-tor-kind-spine-fabric"
SPINE_BORDER := "clab-dual-tor-kind-spine-border"

# MGMT_PROXY is resolved dynamically at runtime — see kubeconfig-cutover recipe

# List available recipes
[default]
default:
    @just --list

# --- tooling ---
# Download pinned static binaries (just, clab) into bin/. Arch-aware; no runtime deps.
get-binaries:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p bin
    case "$(uname -m)" in
      x86_64)        just_arch=x86_64-unknown-linux-musl;  clab_arch=Linux_amd64 ;;
      aarch64|arm64) just_arch=aarch64-unknown-linux-musl; clab_arch=Linux_arm64 ;;
      *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
    esac
    echo "Fetching just {{JUST_VERSION}} ($just_arch)..."
    curl -fsSL "https://github.com/casey/just/releases/download/{{JUST_VERSION}}/just-{{JUST_VERSION}}-${just_arch}.tar.gz" | tar -xz -C bin just
    echo "Fetching containerlab {{CLAB_VERSION}} ($clab_arch)..."
    curl -fsSL "https://github.com/srl-labs/containerlab/releases/download/v{{CLAB_VERSION}}/containerlab_{{CLAB_VERSION}}_${clab_arch}.tar.gz" | tar -xz -C bin containerlab
    mv -f bin/containerlab bin/clab
    chmod +x bin/just bin/clab
    echo "Done -> bin/just ({{JUST_VERSION}}), bin/clab ({{CLAB_VERSION}})"

# --- build & lifecycle ---
build:
    docker build -t kind-node-with-frr -f images/kind-node/Dockerfile .

deploy:
    sudo clab deploy -t {{CLAB}} --reconfigure

destroy:
    sudo clab destroy -t {{CLAB}}
    kind delete cluster --name k8s 2>/dev/null || true

# One-shot end-to-end bring-up: image -> topology -> fabric cutover -> Cilium -> BGP CRs.
# cutover now drops eth0 (fabric-only); Kind nodes then pull Cilium images via the
# fabric's spine SNAT egress. If cilium-install races the API right after cutover,
# just re-run it.
deploy-all: build deploy cutover cilium-install cilium-bgp
    @echo "Lab up. Verify:  just sessions  |  just routes  |  just cilium-bgp-status  |  just pods"

# --- cutover: small composable steps ---
copy-frr-configs:
    docker cp configs/k8s-control-plane/frr.conf {{K8S_CP}}:/etc/frr/frr.conf
    docker cp configs/k8s-control-plane/daemons {{K8S_CP}}:/etc/frr/daemons
    docker cp configs/k8s-worker/frr.conf {{K8S_WORKER}}:/etc/frr/frr.conf
    docker cp configs/k8s-worker/daemons {{K8S_WORKER}}:/etc/frr/daemons
    docker cp configs/k8s-worker2/frr.conf {{K8S_WORKER2}}:/etc/frr/frr.conf
    docker cp configs/k8s-worker2/daemons {{K8S_WORKER2}}:/etc/frr/daemons

assign-fabric-ips:
    docker exec {{K8S_CP}} sh -c "ip addr add 10.99.0.15/31 dev eth1 2>/dev/null; ip link set eth1 up"
    docker exec {{K8S_CP}} sh -c "ip link add dummy0 type dummy 2>/dev/null; ip addr add 10.99.255.10/32 dev dummy0 2>/dev/null; ip link set dummy0 up"
    docker exec {{K8S_CP}} sh -c "ip route add default via 10.99.0.14 dev eth1 2>/dev/null || true"
    docker exec {{K8S_WORKER}} sh -c "ip addr add 10.99.0.0/31 dev eth1 2>/dev/null; ip link set eth1 up"
    docker exec {{K8S_WORKER}} sh -c "ip addr add 10.99.0.2/31 dev eth2 2>/dev/null; ip link set eth2 up"
    docker exec {{K8S_WORKER}} sh -c "ip link add dummy0 type dummy 2>/dev/null; ip addr add 10.99.255.1/32 dev dummy0 2>/dev/null; ip link set dummy0 up"
    docker exec {{K8S_WORKER}} sh -c "ip route add default via 10.99.0.1 dev eth1 2>/dev/null || ip route add default via 10.99.0.3 dev eth2 2>/dev/null || true"
    docker exec {{K8S_WORKER2}} sh -c "ip addr add 10.99.0.16/31 dev eth1 2>/dev/null; ip link set eth1 up"
    docker exec {{K8S_WORKER2}} sh -c "ip addr add 10.99.0.18/31 dev eth2 2>/dev/null; ip link set eth2 up"
    docker exec {{K8S_WORKER2}} sh -c "ip link add dummy0 type dummy 2>/dev/null; ip addr add 10.99.255.2/32 dev dummy0 2>/dev/null; ip link set dummy0 up"
    docker exec {{K8S_WORKER2}} sh -c "ip route add default via 10.99.0.17 dev eth1 2>/dev/null || ip route add default via 10.99.0.19 dev eth2 2>/dev/null || true"

start-frr:
    docker exec {{K8S_CP}} systemctl restart frr
    docker exec {{K8S_WORKER}} systemctl restart frr
    docker exec {{K8S_WORKER2}} systemctl restart frr
    docker exec {{K8S_CP}} sh -c "ip route del default dev eth0 2>/dev/null || true"
    docker exec {{K8S_WORKER}} sh -c "ip route del default dev eth0 2>/dev/null || true"
    docker exec {{K8S_WORKER2}} sh -c "ip route del default dev eth0 2>/dev/null || true"

update-kubelets:
    docker exec {{K8S_CP}} sh -c "sed -i 's/--node-ip=[0-9.]*/--node-ip=10.99.0.15/' /var/lib/kubelet/kubeadm-flags.env && pkill kubelet"
    docker exec {{K8S_WORKER}} sh -c "sed -i 's/--node-ip=[0-9.]*/--node-ip=10.99.255.1/' /var/lib/kubelet/kubeadm-flags.env && sed -i 's|https://k8s-control-plane:6443|https://10.99.0.15:6443|' /etc/kubernetes/kubelet.conf && pkill kubelet"
    docker exec {{K8S_WORKER2}} sh -c "sed -i 's/--node-ip=[0-9.]*/--node-ip=10.99.255.2/' /var/lib/kubelet/kubeadm-flags.env && sed -i 's|https://k8s-control-plane:6443|https://10.99.0.15:6443|' /etc/kubernetes/kubelet.conf && pkill kubelet"

setup-mgmt-proxy:
    docker exec {{SPINE_BORDER}} sh -c "iptables -t nat -C PREROUTING -p tcp --dport 6443 -j DNAT --to-destination 10.99.0.15:6443 2>/dev/null || iptables -t nat -A PREROUTING -p tcp --dport 6443 -j DNAT --to-destination 10.99.0.15:6443"
    docker exec {{SPINE_BORDER}} sh -c "iptables -t nat -C POSTROUTING -d 10.99.0.15 -p tcp --dport 6443 -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -d 10.99.0.15 -p tcp --dport 6443 -j MASQUERADE"
    docker exec {{SPINE_BORDER}} sh -c "iptables -C FORWARD -p tcp -d 10.99.0.15 --dport 6443 -j ACCEPT 2>/dev/null || iptables -A FORWARD -p tcp -d 10.99.0.15 --dport 6443 -j ACCEPT"

cutover: copy-frr-configs assign-fabric-ips start-frr update-kubelets setup-mgmt-proxy kubeconfig-cutover fabric-only
    @echo "Cutover complete — cluster on fabric IPs, eth0 down (pure fabric; egress via spine SNAT), kubeconfig via spine-border proxy"

fabric-only:
    docker exec {{K8S_CP}} ip link set eth0 down 2>/dev/null || true
    docker exec {{K8S_WORKER}} ip link set eth0 down 2>/dev/null || true
    docker exec {{K8S_WORKER2}} ip link set eth0 down 2>/dev/null || true
    echo "eth0 down on k8s-control-plane, k8s-worker, k8s-worker2 — pure fabric mode"

# --- kubeconfig ---
kubeconfig:
    @kind get kubeconfig --name k8s > kubeconfig.yaml 2>/dev/null && \
    sed -i 's/certificate-authority-data:.*/insecure-skip-tls-verify: true/' kubeconfig.yaml && \
    kubectl --kubeconfig kubeconfig.yaml config set-context --current --namespace kube-system >/dev/null && \
    echo "Kubeconfig -> kubeconfig.yaml"

kubeconfig-cutover:
    @MGMT_PROXY=`docker inspect {{SPINE_BORDER}} | jq -r ".[0].NetworkSettings.Networks | to_entries[0].value.IPAddress"` && \
    [ -n "$MGMT_PROXY" ] || (echo 'ERROR: could not determine spine-border mgmt IP' && exit 1) && \
    kind get kubeconfig --name k8s > kubeconfig.yaml 2>/dev/null && \
    sed -i "s|server: .*|server: https://$MGMT_PROXY:6443|" kubeconfig.yaml && \
    sed -i 's/certificate-authority-data:.*/insecure-skip-tls-verify: true/' kubeconfig.yaml && \
    kubectl --kubeconfig kubeconfig.yaml config set-context --current --namespace kube-system >/dev/null && \
    echo "Kubeconfig -> kubeconfig.yaml (via spine-border proxy: $MGMT_PROXY:6443)"

# --- k8s cluster queries ---
pods:
    kubectl --kubeconfig kubeconfig.yaml get pods -A

nodes:
    kubectl --kubeconfig kubeconfig.yaml get nodes

# --- k8s-worker (rack1, FRR) ---
k8s-worker-sessions:
    docker exec {{K8S_WORKER}} vtysh -c "show ip bgp summary"

k8s-worker-routes:
    docker exec {{K8S_WORKER}} vtysh -c "show ip bgp"
    docker exec {{K8S_WORKER}} vtysh -c "show ip route"

k8s-worker-cmd CMD:
    docker exec {{K8S_WORKER}} vtysh -c "{{CMD}}"

k8s-worker-shcmd CMD:
    docker exec {{K8S_WORKER}} sh -c "{{CMD}}"

# --- k8s-worker2 (rack2, FRR) ---
k8s-worker2-sessions:
    docker exec {{K8S_WORKER2}} vtysh -c "show ip bgp summary"

k8s-worker2-routes:
    docker exec {{K8S_WORKER2}} vtysh -c "show ip bgp"
    docker exec {{K8S_WORKER2}} vtysh -c "show ip route"

k8s-worker2-cmd CMD:
    docker exec {{K8S_WORKER2}} vtysh -c "{{CMD}}"

k8s-worker2-shcmd CMD:
    docker exec {{K8S_WORKER2}} sh -c "{{CMD}}"

# --- k8s-control-plane (FRR) ---
k8s-cp-sessions:
    docker exec {{K8S_CP}} vtysh -c "show ip bgp summary"

k8s-cp-routes:
    docker exec {{K8S_CP}} ip route

k8s-cp-cmd CMD:
    docker exec {{K8S_CP}} vtysh -c "{{CMD}}"

k8s-cp-shcmd CMD:
    docker exec {{K8S_CP}} sh -c "{{CMD}}"

k8s-cp-logs:
    docker logs --tail 50 {{K8S_CP}}

k8s-cp-logs-follow:
    docker logs -f {{K8S_CP}}

# --- rack1-tor-a (FRR) ---
rack1-tor-a-sessions:
    docker exec {{RACK1_TOR_A}} vtysh -c "show ip bgp summary"

rack1-tor-a-routes:
    docker exec {{RACK1_TOR_A}} vtysh -c "show ip bgp"
    docker exec {{RACK1_TOR_A}} vtysh -c "show ip route"

rack1-tor-a-cmd CMD:
    docker exec {{RACK1_TOR_A}} vtysh -c "{{CMD}}"

# --- rack1-tor-b (FRR) ---
rack1-tor-b-sessions:
    docker exec {{RACK1_TOR_B}} vtysh -c "show ip bgp summary"

rack1-tor-b-routes:
    docker exec {{RACK1_TOR_B}} vtysh -c "show ip bgp"
    docker exec {{RACK1_TOR_B}} vtysh -c "show ip route"

rack1-tor-b-cmd CMD:
    docker exec {{RACK1_TOR_B}} vtysh -c "{{CMD}}"

# --- rack2-tor-a (FRR) ---
rack2-tor-a-sessions:
    docker exec {{RACK2_TOR_A}} vtysh -c "show ip bgp summary"

rack2-tor-a-routes:
    docker exec {{RACK2_TOR_A}} vtysh -c "show ip bgp"
    docker exec {{RACK2_TOR_A}} vtysh -c "show ip route"

rack2-tor-a-cmd CMD:
    docker exec {{RACK2_TOR_A}} vtysh -c "{{CMD}}"

# --- rack2-tor-b (FRR) ---
rack2-tor-b-sessions:
    docker exec {{RACK2_TOR_B}} vtysh -c "show ip bgp summary"

rack2-tor-b-routes:
    docker exec {{RACK2_TOR_B}} vtysh -c "show ip bgp"
    docker exec {{RACK2_TOR_B}} vtysh -c "show ip route"

rack2-tor-b-cmd CMD:
    docker exec {{RACK2_TOR_B}} vtysh -c "{{CMD}}"

# --- spine-fabric (FRR) — hub for all 4 ToRs ---
spine-fabric-sessions:
    docker exec {{SPINE_FABRIC}} vtysh -c "show ip bgp summary"

spine-fabric-routes:
    docker exec {{SPINE_FABRIC}} vtysh -c "show ip bgp"
    docker exec {{SPINE_FABRIC}} vtysh -c "show ip route"

spine-fabric-cmd CMD:
    docker exec {{SPINE_FABRIC}} vtysh -c "{{CMD}}"

# --- spine-border (FRR) — cp uplink + SNAT egress ---
spine-border-sessions:
    docker exec {{SPINE_BORDER}} vtysh -c "show ip bgp summary"

spine-border-routes:
    docker exec {{SPINE_BORDER}} vtysh -c "show ip bgp"
    docker exec {{SPINE_BORDER}} vtysh -c "show ip route"

spine-border-cmd CMD:
    docker exec {{SPINE_BORDER}} vtysh -c "{{CMD}}"

# --- all nodes ---
sessions:
    @echo "===== k8s-worker (FRR) ====="
    docker exec {{K8S_WORKER}} vtysh -c "show ip bgp summary"
    @echo "===== k8s-worker2 (FRR) ====="
    docker exec {{K8S_WORKER2}} vtysh -c "show ip bgp summary"
    @echo "===== k8s nodes (Kind) ====="
    kubectl --kubeconfig kubeconfig.yaml get nodes 2>/dev/null || echo "kubeconfig not ready"
    @echo "===== rack1-tor-a (FRR) ====="
    docker exec {{RACK1_TOR_A}} vtysh -c "show ip bgp summary"
    @echo "===== rack1-tor-b (FRR) ====="
    docker exec {{RACK1_TOR_B}} vtysh -c "show ip bgp summary"
    @echo "===== rack2-tor-a (FRR) ====="
    docker exec {{RACK2_TOR_A}} vtysh -c "show ip bgp summary"
    @echo "===== rack2-tor-b (FRR) ====="
    docker exec {{RACK2_TOR_B}} vtysh -c "show ip bgp summary"
    @echo "===== spine-fabric (FRR) ====="
    docker exec {{SPINE_FABRIC}} vtysh -c "show ip bgp summary"
    @echo "===== spine-border (FRR) ====="
    docker exec {{SPINE_BORDER}} vtysh -c "show ip bgp summary"

routes:
    @echo "===== k8s-worker (FRR) ====="
    docker exec {{K8S_WORKER}} vtysh -c "show ip route"
    @echo "===== k8s-worker2 (FRR) ====="
    docker exec {{K8S_WORKER2}} vtysh -c "show ip route"
    @echo "===== k8s-control-plane (host) ====="
    docker exec {{K8S_CP}} ip route
    @echo "===== rack1-tor-a (FRR) ====="
    docker exec {{RACK1_TOR_A}} vtysh -c "show ip bgp"
    @echo "===== rack1-tor-b (FRR) ====="
    docker exec {{RACK1_TOR_B}} vtysh -c "show ip bgp"
    @echo "===== rack2-tor-a (FRR) ====="
    docker exec {{RACK2_TOR_A}} vtysh -c "show ip bgp"
    @echo "===== rack2-tor-b (FRR) ====="
    docker exec {{RACK2_TOR_B}} vtysh -c "show ip bgp"
    @echo "===== spine-fabric (FRR) ====="
    docker exec {{SPINE_FABRIC}} vtysh -c "show ip bgp"
    @echo "===== spine-border (FRR) ====="
    docker exec {{SPINE_BORDER}} vtysh -c "show ip bgp"

# --- cilium (CNI + BGP control plane) ---
cilium-install:
    helm repo add cilium https://helm.cilium.io/ 2>/dev/null || true
    helm upgrade --install cilium cilium/cilium \
        --namespace kube-system \
        --set kubeProxyReplacement=true \
        --set loadBalancer.algorithm=maglev \
        --set loadBalancer.mode=dsr \
        --set loadBalancer.dsrDispatch=opt \
        --set k8sServiceHost=10.99.0.15 \
        --set k8sServicePort=6443 \
        --set routingMode=native \
        --set ipv4NativeRoutingCIDR=10.99.0.0/16 \
        --set bgpControlPlane.enabled=true \
        --set envoy.enabled=false \
        --set ingressController.enabled=false \
        --set ipam.mode=multi-pool \
        --set enableIPv4Masquerade=false \
        --set ipam.operator.autoCreateCiliumPodIPPools.default.ipv4.cidrs="{10.99.40.0/22}" \
        --set ipam.operator.autoCreateCiliumPodIPPools.default.ipv4.maskSize=24 \
        --wait

cilium-bgp:
    kubectl --kubeconfig kubeconfig.yaml apply -f configs/cilium-bgp.yaml

cilium-bgp-uninstall:
    kubectl --kubeconfig kubeconfig.yaml delete -f configs/cilium-bgp.yaml --ignore-not-found

cilium-bgp-status:
    kubectl --kubeconfig kubeconfig.yaml exec -n kube-system ds/cilium -- cilium bgp peers

cilium-routes:
    kubectl --kubeconfig kubeconfig.yaml exec -n kube-system ds/cilium -- cilium bgp route announced ipv4 unicast

# Prove multi-pool IPAM + LB on the cp path: deploy the CP-pinned httpbin/netshoot
# on cp-pool, then show the CP node's allocated pod CIDRs (expect a 10.99.200.0/27
# block from cp-pool, while workers stay on the default 10.99.40.0/22 pool).
cp-pool-test:
    kubectl --kubeconfig kubeconfig.yaml apply -f configs/test-lb-cp.yaml
    kubectl --kubeconfig kubeconfig.yaml -n kube-system rollout status deploy/httpbin --timeout=60s
    @echo "--- k8s-control-plane allocated pod pools ---"
    kubectl --kubeconfig kubeconfig.yaml get ciliumnode k8s-control-plane -o jsonpath='{.spec.ipam.pools.allocated}{"\n"}'
    kubectl --kubeconfig kubeconfig.yaml -n kube-system get pods -o wide
    kubectl --kubeconfig kubeconfig.yaml -n kube-system get svc httpbin-lb-cp

# Generate a web-viewable HTML topology (requires sudo). Output goes to
# clab-dual-tor-kind/graph/. Open the generated .html in a browser.
topo-web:
    sudo clab graph -t {{CLAB}}
