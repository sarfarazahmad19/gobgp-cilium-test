#!/bin/sh
# Install Cilium on the kind cluster using helm.
# Idempotent — re-running will upgrade in place.
set -eu

KUBECONFIG="${KUBECONFIG:-./.kubeconfig/kubeconfig.yaml}"
CP_CONTAINER="${CP_CONTAINER:-overlay-l3-bgp-bfd-control-plane}"
CILIUM_VERSION="${CILIUM_VERSION:-1.19.5}"
KIND_NETWORK="${KIND_NETWORK:-bgp-net}"

log() { printf "[install-cilium] %s\n" "$*"; }

if [ ! -f "$KUBECONFIG" ]; then
  echo "ERROR: kubeconfig not found at $KUBECONFIG — run \`make cluster-up\` first" >&2
  exit 1
fi

# Resolve the control-plane IP on the cluster's dedicated Docker bridge.
# Cilium uses this to reach the kube-apiserver before any Service IP routing is up.
CP_IP=$(docker inspect "$CP_CONTAINER" \
  --format "{{index .NetworkSettings.Networks \"$KIND_NETWORK\" \"IPAddress\"}}" 2>/dev/null || true)
if [ -z "$CP_IP" ]; then
  echo "ERROR: could not resolve IP of control-plane container '$CP_CONTAINER'" >&2
  exit 1
fi
log "control-plane IP (kind net): $CP_IP"

log "ensuring cilium helm repo"
helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update >/dev/null

log "installing cilium $CILIUM_VERSION (native routing, single device eth1, hubble enabled)"
helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --kubeconfig "$KUBECONFIG" \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$CP_IP" \
  --set k8sServicePort=6443 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set ipam.mode=kubernetes \
  --set bpf.masquerade=true \
  --set bgpControlPlane.enabled=false \
  --set devices='{eth1}' \
  --set loadBalancer.mode=snat \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR=10.244.0.0/16

log "waiting for cilium daemonset to be ready"
kubectl --kubeconfig "$KUBECONFIG" -n kube-system rollout status ds/cilium --timeout=180s

log "cilium status (high-level):"
kubectl --kubeconfig "$KUBECONFIG" -n kube-system exec deploy/cilium-operator -- \
  cilium status --brief 2>/dev/null || true

log "done. hubble UI port-forward with: make hubble-ui"
