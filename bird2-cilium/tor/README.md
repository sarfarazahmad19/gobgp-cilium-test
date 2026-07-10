# FRR TOR containers

This directory contains the FRR configurations for the TOR (Top of Rack) containers that Bird3 peers with via BGP+BFD.

## Files

- `tor1.conf` — FRR config for `frr-tor-mock` at **172.18.0.100** (primary TOR)
- `tor2.conf` — FRR config for `frr-tor2-mock` at **172.18.0.50** (secondary TOR)
- `daemons` — FRR daemons file (enables bgpd and bfdd)

## Start the TOR containers

```bash
# Primary TOR (172.18.0.100)
docker run -d \
  --name frr-tor-mock \
  --network kind \
  --ip 172.18.0.100 \
  --privileged \
  --volume $(pwd)/tor1.conf:/etc/frr/frr.conf \
  --volume $(pwd)/daemons:/etc/frr/daemons \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_ADMIN \
  --sysctl net.ipv4.ip_forward=1 \
  frrouting/frr:latest

# Secondary TOR (172.18.0.50)
docker run -d \
  --name frr-tor2-mock \
  --network kind \
  --ip 172.18.0.50 \
  --privileged \
  --volume $(pwd)/tor2.conf:/etc/frr/frr.conf \
  --volume $(pwd)/daemons:/etc/frr/daemons \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_ADMIN \
  --sysctl net.ipv4.ip_forward=1 \
  frrouting/frr:latest

# Enable SNAT for egress traffic
docker exec frr-tor-mock iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
docker exec frr-tor2-mock iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

## Verify

```bash
# BGP sessions
docker exec frr-tor-mock vtysh -c "show ip bgp summary"
docker exec frr-tor2-mock vtysh -c "show ip bgp summary"

# BFD peers
docker exec frr-tor-mock vtysh -c "show bfd peers"
docker exec frr-tor2-mock vtysh -c "show bfd peers"

# Routes from Bird3
docker exec frr-tor-mock vtysh -c "show ip bgp"
docker exec frr-tor2-mock vtysh -c "show ip bgp"
```

## Cleanup

```bash
docker rm -f frr-tor-mock frr-tor2-mock
```
