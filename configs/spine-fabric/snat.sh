#!/bin/bash
# SNAT/PAT gateway setup for the spine node.
# eth0 is the internet-facing egress (clab mgmt bridge, NATed by host).
# Workers/ToRs behind this spine reach the internet via default-originate;
# this script MASQUERADEs all traffic leaving eth0.
set -e

# Ensure forwarding is on (also handled by FRR removing 'no ip forwarding')
sysctl -w net.ipv4.ip_forward=1

# Default route out eth0 so the spine itself can reach the internet.
ip route replace default via 172.20.20.1 dev eth0

# SNAT/PAT all traffic leaving eth0 (internet-bound).
# Private ranges never egress eth0 (they use the data interfaces), so no
# RFC1918 exemption is needed.
iptables -t nat -C POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
