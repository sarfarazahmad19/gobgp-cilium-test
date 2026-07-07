#!/bin/sh
# Bring up the kind cluster (idempotent) and attach the node containers to
# the shared bgp-net network so sidecar services (e.g. FRR) can reach
# them on the same L2 segment.
set -eu

CLUSTER_NAME="overlay-l3-bgp-bfd"
NETWORK_NAME="${NETWORK_NAME:-bgp-net}"

KUBECONFIG_OUT="${KUBECONFIG_OUT:-/data/kubeconfig.yaml}"

log() { printf "[kind-up] %s\n" "$*"; }

# Install deps if running outside the normal compose command path (which
# installs them before calling this script).  Idempotent on subsequent calls.
apk add --no-cache docker-cli bash >/dev/null 2>&1 || true

# Sanity: docker socket reachable?
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: docker socket not reachable from inside controller" >&2
  exit 1
fi

# Make sure the BGP network exists (compose will create it on first up,
# but running the script standalone is supported too).
if ! docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  log "creating docker network $NETWORK_NAME"
  docker network create --driver bridge "$NETWORK_NAME" >/dev/null
fi

# Idempotent cluster creation — kind creates nodes on its default Docker bridge
# (named `kind`). We add the bgp-net secondary interface with pinned IPs below.
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "cluster '$CLUSTER_NAME' already exists, skipping create"
else
  log "creating cluster '$CLUSTER_NAME'"
  kind create cluster --config /config/kind.yaml --retain
fi

# Attach every node to bgp-net with pinned IPs so FRR2 (BGP border) and
# Cilium BGP CP can peer deterministically.  The pinned IPs must match
# neighbor-address values in frr/frr.conf — keep both in sync.
ip_for_node() {
  case "$1" in
    overlay-l3-bgp-bfd-control-plane) echo "172.19.0.3" ;;
    overlay-l3-bgp-bfd-worker)        echo "172.19.0.4" ;;
    overlay-l3-bgp-bfd-worker2)       echo "172.19.0.5" ;;
    *) log "WARN: no pinned IP for node '$1' on $NETWORK_NAME — using Docker DHCP" >&2
       echo "" ;;
  esac
}
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  if docker inspect "$node" \
      --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
      | tr ' ' '\n' | grep -qx "$NETWORK_NAME"; then
    actual=$(docker inspect "$node" --format "{{index .NetworkSettings.Networks \"$NETWORK_NAME\" \"IPAddress\"}}")
    expected=$(ip_for_node "$node")
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
      log "FATAL: node '$node' is on $NETWORK_NAME with IP $actual, expected $expected"
      log "  run 'make down && make up' to recreate, or detach and re-attach manually"
      exit 1
    fi
    log "node '$node' already on $NETWORK_NAME with IP $actual"
  else
    ip=$(ip_for_node "$node")
    if [ -n "$ip" ]; then
      log "attaching node '$node' to $NETWORK_NAME with pinned IP $ip"
      docker network connect --ip "$ip" "$NETWORK_NAME" "$node"
    else
      log "attaching node '$node' to $NETWORK_NAME (Docker-assigned IP)"
      docker network connect "$NETWORK_NAME" "$node"
    fi
  fi
done

# Patch kubelet --node-ip on every node so kubelet reports the bgp-net IP
# as InternalIP instead of the kind-net IP.  This is critical for BGP:
# kube-router / GoBGP uses the node's InternalIP as the source address for
# outgoing BGP connections (to FRR2).  Without this, kubelet auto-detects
# the kind-net IP (eth0) as InternalIP, and GoBGP dials from the wrong
# address, causing "Mismatched local address" errors.
# kind creates nodes with --node-ip=0.0.0.0 (auto-detect), which picks the
# kind-net IP (eth0) first.  We patch kubeadm-flags.env to use the pinned
# bgp-net IP, then restart kubelet so it re-registers with the correct IP.
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  bgp_ip=$(ip_for_node "$node")
  if [ -n "$bgp_ip" ]; then
    docker exec "$node" sed -i \
      "s|--node-ip=0.0.0.0|--node-ip=$bgp_ip|g" \
      /var/lib/kubelet/kubeadm-flags.env 2>/dev/null || true
    log "patched --node-ip=$bgp_ip on $node"
  fi
done

# Restart kubelet on all nodes so the new --node-ip takes effect.
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  docker exec "$node" sh -c "systemctl restart kubelet" 2>/dev/null || true
done
log "restarted kubelet on all nodes (will re-register with bgp-net IPs)"

# Wait for kubelet to re-register and nodes to become Ready.
sleep 10

# Set FRR2 (172.19.0.10) as the default gateway on every kind node.
FRR_GW="${FRR_GW:-172.19.0.10}"
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  docker exec "$node" sh -c "ip route flush 0/0 2>/dev/null; ip route add default via $FRR_GW" 2>/dev/null || true
done
log "set default route via FRR2 ($FRR_GW) on all nodes"

# Always (re)write the kubeconfig so the host can pick it up.
log "exporting kubeconfig -> $KUBECONFIG_OUT"
kind export kubeconfig --kubeconfig "$KUBECONFIG_OUT" --name "$CLUSTER_NAME"
chmod 666 "$KUBECONFIG_OUT" 2>/dev/null || true

# Wait for the control plane to be Ready.
log "waiting for control-plane to be Ready"
kubectl --kubeconfig "$KUBECONFIG_OUT" wait --for=condition=Ready \
  --timeout=120s node --all >/dev/null 2>&1 \
  || true

log "cluster nodes:"
kubectl --kubeconfig "$KUBECONFIG_OUT" get nodes -o wide 2>/dev/null || true

log "done."
