#!/bin/sh
# Tear down the kind cluster. Network is left intact (it's managed by
# docker-compose / external user) so it can be reused by other stacks.
set -eu

# Install deps in case we're running via `docker compose run` (bypasses
# the compose file's `command` which includes apk add).
apk add --no-cache docker-cli bash >/dev/null 2>&1 || true

CLUSTER_NAME="overlay-l3-bgp"

log() { printf "[kind-down] %s\n" "$*"; }

# Prefer the proper kind path when possible (also wipes node containers).
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "deleting cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME" || true
fi

# Belt and suspenders: kill any node containers still labeled as part of
# this cluster. This catches the case where `kind get clusters` doesn't
# see the cluster (version mismatch, stale state) but the containers are
# still running on the docker socket.
orphan_count=0
for c in $(docker ps -aq --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME" 2>/dev/null); do
  log "removing orphan kind node container: $c"
  docker rm -f "$c" >/dev/null 2>&1 || true
  orphan_count=$((orphan_count + 1))
done
if [ "$orphan_count" -gt 0 ]; then
  log "removed $orphan_count orphan container(s)"
fi
