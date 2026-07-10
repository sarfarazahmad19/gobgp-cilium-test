#!/bin/bash
set -euo pipefail

# Bird3 + BFD Lab Setup Script
# Architecture: TOR (FRR) <--BGP+BFD--> Bird3 (localhost) <--BGP--> Cilium
#
# Cilium's BGP control plane peers with Bird3 on localhost (127.0.0.1)
# Bird3 provides BFD to the TOR (FRR) - Cilium can't do BFD natively
# Bird3 hides Cilium's AS from TOR (bgp_path.delete)
#
# All on a single kind network - no separate Docker network needed.

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIND_CLUSTER="bird3-lab"
TOR_CONTAINER="frr-tor-mock"
TOR_IP="172.18.0.100"

echo "=== Bird3 + BFD Lab Setup ==="
echo ""

cleanup() {
    echo ""
    echo "=== Cleaning up ==="
    kind delete cluster --name "$KIND_CLUSTER" 2>/dev/null || true
    docker rm -f "$TOR_CONTAINER" 2>/dev/null || true
    echo "Cleanup complete."
}

case "${1:-}" in
    cleanup|teardown)
        cleanup
        exit 0
        ;;
    *)
        ;;
esac

# Step 1: Create Kind cluster
echo "Step 1: Creating Kind cluster '$KIND_CLUSTER'..."
kind create cluster \
    --name "$KIND_CLUSTER" \
    --config "$LAB_DIR/kind/cluster.yaml"

# Step 2: Build and load Bird3 Docker image
echo ""
echo "Step 2: Building Bird3 Docker image..."
if [ ! -d /tmp/bird3-build ]; then
    mkdir -p /tmp/bird3-build
    cat > /tmp/bird3-build/Dockerfile << 'DOCKERFILE'
FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        wget gnupg2 ca-certificates iproute2 iputils-ping tcpdump && \
    echo "deb https://pkg.labs.nic.cz/bird3 bookworm main" > /etc/apt/sources.list.d/bird3.list && \
    wget -qO /usr/share/keyrings/cznic-labs-archive-keyring.gpg https://pkg.labs.nic.cz/bird3/apt_gpg_key && \
    apt-get update && \
    apt-get install -y --no-install-recommends bird3 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
DOCKERFILE
    docker build -t bird3-lab:latest /tmp/bird3-build
fi
echo "Loading image into kind nodes..."
kind load docker-image bird3-lab:latest --name "$KIND_CLUSTER"

# Step 3: Start TOR (FRR) on kind network
echo ""
echo "Step 3: Starting TOR (FRR) at ${TOR_IP} on kind network..."

# Get worker IPs from kind network
WORKERS=$(docker ps -f "name=${KIND_CLUSTER}" --format "{{.Names}}" | grep -v "control-plane" | head -2)
WORKER_IPS=()
for WORKER in $WORKERS; do
    IP=$(docker inspect "$WORKER" 2>/dev/null | python3 -c "
import sys, json
i = json.load(sys.stdin)[0]
for net, cfg in i['NetworkSettings']['Networks'].items():
    if net == 'kind':
        print(cfg['IPAddress'])
" 2>/dev/null)
    WORKER_IPS+=("$IP")
    echo "  $WORKER: $IP"
done

# Generate FRR config for TOR
FRR_NEIGHBORS=""
BFD_PEERS=""
for IP in "${WORKER_IPS[@]}"; do
    FRR_NEIGHBORS="${FRR_NEIGHBORS}
 neighbor ${IP} peer-group K8S-WORKERS"
    BFD_PEERS="${BFD_PEERS}
 peer ${IP} local-address ${TOR_IP}
  detect-multiplier 3
  receive-interval 300
  transmit-interval 300
 exit
 !"
done

cat > /tmp/frr-tor.conf <<EOF
frr version 8.4_git
frr defaults traditional
hostname tor-mock
log file /tmp/frr.log
no ipv6 forwarding
service integrated-vtysh-config
!
router bgp 65000
 bgp router-id ${TOR_IP}
 bgp bestpath as-path multipath-relax
 neighbor K8S-WORKERS peer-group
 neighbor K8S-WORKERS remote-as 65100
 !${FRR_NEIGHBORS}
 !
 address-family ipv4 unicast
  network 10.0.0.0/8
  network 172.16.0.0/12
  neighbor K8S-WORKERS activate
  neighbor K8S-WORKERS route-map IMPORT in
  neighbor K8S-WORKERS route-map EXPORT out
 exit-address-family
exit
!
ip prefix-list IMPORT seq 5 permit 192.168.0.0/16 le 32
ip prefix-list IMPORT seq 10 permit 10.0.0.0/8 le 32
ip prefix-list IMPORT seq 15 permit 0.0.0.0/0 le 32
ip prefix-list EXPORT seq 5 permit 10.0.0.0/8
ip prefix-list EXPORT seq 10 permit 172.16.0.0/12
!
route-map IMPORT permit 10
 match ip address prefix-list IMPORT
exit
!
route-map EXPORT permit 10
 match ip address prefix-list EXPORT
exit
!
bfd
${BFD_PEERS}
exit
!
EOF

cat > /tmp/frr-daemons << 'DAEMONS'
bgpd=yes
bfdd=yes
zebra=yes
staticd=yes
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1 -p 179"
bfdd_options="   -A 127.0.0.1"
staticd_options="  -A 127.0.0.1"
DAEMONS

docker rm -f "$TOR_CONTAINER" 2>/dev/null || true
docker run -d \
    --name "$TOR_CONTAINER" \
    --network kind \
    --ip "$TOR_IP" \
    --privileged \
    --volume /tmp/frr-tor.conf:/etc/frr/frr.conf \
    --volume /tmp/frr-daemons:/etc/frr/daemons \
    --cap-add=NET_ADMIN \
    --cap-add=SYS_ADMIN \
    --sysctl net.ipv4.ip_forward=1 \
    frrouting/frr:latest

sleep 5
echo "TOR FRR daemons:"
docker exec "$TOR_CONTAINER" ps aux | grep -E "bgpd|bfdd" | grep -v grep

# Add SNAT for egress traffic
docker exec "$TOR_CONTAINER" iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
echo "SNAT enabled on TOR"

# Step 4: Install Cilium with BGP control plane
echo ""
echo "Step 4: Installing Cilium with BGP control plane enabled..."
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set bgpControlPlane.enabled=true \
    --wait

# Step 5: Apply Cilium BGP peering config
echo ""
echo "Step 5: Applying Cilium BGP peering config..."
kubectl apply -f "$LAB_DIR/bird3/cilium-bgp.yaml"

# Step 6: Deploy Bird3 DaemonSet
echo ""
echo "Step 6: Deploying Bird3..."
kubectl apply -f "$LAB_DIR/bird3/configmap.yaml"
kubectl apply -f "$LAB_DIR/bird3/daemonset.yaml"

echo "Waiting for Bird3 daemonset..."
kubectl rollout status daemonset bird3-bfd -n kube-system --timeout=120s || true

echo ""
echo "=== Lab Setup Complete ==="
echo ""
echo "Architecture:"
echo "  TOR (FRR): ${TOR_IP} (AS 65000) + BFD + SNAT"
echo "  Bird3: localhost (AS 65100) - BFD to TOR, BGP to Cilium"
echo "  Cilium: localhost (AS 64512) - BGP control plane to Bird3"
for i in "${!WORKER_IPS[@]}"; do
    echo "  Worker $((i+1)): ${WORKER_IPS[$i]}"
done
echo ""
echo "Chain: TOR (FRR) <--BGP+BFD--> Bird3 <--BGP--> Cilium"
echo ""
echo "Verify:"
echo "  # TOR BGP table"
echo "  docker exec ${TOR_CONTAINER} vtysh -c 'show ip bgp'"
echo "  # TOR BFD peers"
echo "  docker exec ${TOR_CONTAINER} vtysh -c 'show bfd peers'"
echo "  # Cilium BGP status"
echo "  kubectl exec -n kube-system ds/cilium -- cilium bgp peers"
echo "  # Bird3 status"
echo "  kubectl exec -n kube-system \$(kubectl get pod -n kube-system -l app=bird3-bfd -o name | head -1) -c bird3 -- birdc -s /var/run/bird.ctl show protocols"
echo ""
echo "Cleanup: $0 cleanup"