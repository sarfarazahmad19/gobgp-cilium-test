#!/bin/sh
# Tear down the kind cluster. Network is left intact (it's managed by
# docker-compose / external user) so it can be reused by other stacks.
set -eu

CLUSTER_NAME="gobgp"

log() { printf "[kind-down] %s\n" "$*"; }

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "deleting cluster '$CLUSTER_NAME'"
  kind delete cluster --name "$CLUSTER_NAME"
else
  log "cluster '$CLUSTER_NAME' does not exist, nothing to do"
fi
