# bird3-lab Docker image

Custom Docker image for the Bird3 BGP daemon, used in the Cilium → Bird3 → TOR BGP lab.

## Base

- `debian:bookworm-slim`
- Bird3 3.3.1 from `https://pkg.labs.nic.cz/bird3`
- Includes: `iproute2`, `iputils-ping`, `tcpdump`, `jq`, `python3`

## Build

```bash
docker build -t bird3-lab:latest images/bird3/
```

## Load into kind

```bash
kind load docker-image bird3-lab:latest --name bird2-lab
```

## Used as

1. **Main container** in the `bird3-bfd` DaemonSet — runs `bird -d -c /etc/bird/bird.conf -s /var/run/bird.ctl -f`
2. **Init container** in the same DaemonSet — uses `ip -j` + `jq` + `python3` to:
   - Substitute `__NODE_IP__` placeholder with the node's IP (from Downward API `status.hostIP`)
   - Detect TOR peers from default routes (`ip -j route show default | jq -r '.[].gateway'`)
   - Generate one BFD + BGP block per detected default gateway
   - Replace `__TOR_PEERS__` placeholder in the config
