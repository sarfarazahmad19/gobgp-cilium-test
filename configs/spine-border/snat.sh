#!/bin/bash
# SNAT/PAT gateway setup for the spine node.
# eth0 is the internet-facing egress (clab mgmt bridge, NATed by host).
# This spine (dc2) currently has no ToRs behind it; it NATs its own and
# inter-DC traffic.
set -e

sysctl -w net.ipv4.ip_forward=1
ip route replace default via 172.20.20.1 dev eth0

iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
