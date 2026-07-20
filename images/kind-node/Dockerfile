FROM kindest/node:v1.33.0

# Install FRR from FRR's official apt repo (10.x stable) instead of Debian's
# bookworm package (8.4.4, which has the ECMP link-flap stale-nexthop-group bug
# — see 04-findings-frr-ecmp-nexthop-group-stale-link-flap.md).
RUN apt-get update && apt-get install -y curl gnupg lsb-release && \
    curl -fsSL https://deb.frrouting.org/frr/keys.gpg \
        -o /usr/share/keyrings/frrouting.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/frrouting.gpg] https://deb.frrouting.org/frr $(lsb_release -s -c) frr-stable" \
        > /etc/apt/sources.list.d/frr.list && \
    apt-get update && apt-get install -y frr frr-pythontools && \
    sed -i 's/^bgpd=.*/bgpd=yes/' /etc/frr/daemons && \
    sed -i 's/^bfdd=.*/bfdd=yes/' /etc/frr/daemons && \
    sed -i 's/^staticd=.*/staticd=yes/' /etc/frr/daemons

COPY images/kind-node/frr-start.service /etc/systemd/system/frr-start.service
RUN systemctl enable frr-start.service
