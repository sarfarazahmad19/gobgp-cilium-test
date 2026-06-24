#!/bin/sh
# Bring up the kind cluster (idempotent) and attach the node containers to
# the shared bgp-net network so sidecar services (e.g. FRR) can reach
# them on the same L2 segment.
set -eu

CLUSTER_NAME="overlay-l3-bgp"
NETWORK_NAME="${NETWORK_NAME:-bgp-net}"
KIND_NETWORK="${KIND_NETWORK:-bgp-kind}"
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

# Idempotent cluster creation — use the dedicated network for isolation from
# other kind clusters on the host (they all default to the shared `kind` bridge).
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "cluster '$CLUSTER_NAME' already exists, skipping create"
else
  log "creating cluster '$CLUSTER_NAME'"
  export KIND_EXPERIMENTAL_DOCKER_NETWORK="$KIND_NETWORK"
  kind create cluster --config /config/kind.yaml --retain
fi

# Attach every node to the shared network so peer containers (frr, etc.)
# can reach them on the same L2 segment. Tolerate already-attached state.
# IPs are pinned here and must match the `neighbor-address` values in
# frr/frr.conf — keep both in sync.
ip_for_node() {
  case "$1" in
    overlay-l3-bgp-control-plane) echo "172.19.0.3" ;;
    overlay-l3-bgp-worker)        echo "172.19.0.4" ;;
    overlay-l3-bgp-worker2)       echo "172.19.0.5" ;;
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

# Add static route on every node for the client-net (DSR return path).
# Without this, response packets from backend pods (sourced from real client
# IP 172.21.0.0/24) would go out the default gateway instead of via FRR2.
CLIENT_NET_SUBNET="${CLIENT_NET_SUBNET:-172.21.0.0/24}"
FRR_IP="${FRR_IP:-172.19.0.10}"
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  docker exec "$node" ip route replace "$CLIENT_NET_SUBNET" via "$FRR_IP" dev eth1 2>/dev/null || true
done
log "added static route for $CLIENT_NET_SUBNET via $FRR_IP on all nodes"

# Always (re)write the kubeconfig so the host can pick it up. The
# controller runs as root (it needs the docker socket), so we loosen
# perms explicitly so the host user can read it.
log "exporting kubeconfig -> $KUBECONFIG_OUT"
kind export kubeconfig --kubeconfig "$KUBECONFIG_OUT" --name "$CLUSTER_NAME"
chmod 666 "$KUBECONFIG_OUT" 2>/dev/null || true

# Wait for the control plane to be Ready.
log "waiting for control-plane to be Ready"
kubectl --kubeconfig "$KUBECONFIG_OUT" wait --for=condition=Ready \
  --timeout=120s -n kube-system pod -l tier=control-plane >/dev/null 2>&1 \
  || true

log "cluster nodes:"
kubectl --kubeconfig "$KUBECONFIG_OUT" get nodes -o wide 2>/dev/null || true

log "done."
