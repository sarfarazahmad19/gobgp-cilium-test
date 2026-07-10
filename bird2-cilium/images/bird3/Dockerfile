FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends wget gnupg2 ca-certificates && \
    wget -qO - "https://pkg.labs.nic.cz/gpg" | gpg --dearmor -o /usr/share/keyrings/bird-pkg.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/bird-pkg.gpg] https://pkg.labs.nic.cz/bird3 bookworm main" | tee /etc/apt/sources.list.d/bird.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends bird3 iproute2 iputils-ping tcpdump jq python3 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["bird", "-c", "/etc/bird/bird.conf", "-s", "/var/run/bird.ctl", "-f"]
