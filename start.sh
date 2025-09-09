#!/bin/sh

# Start Tailscale daemon in the background
# --tun=userspace-networking is crucial for Cloud Run
# --socks5-server enables the SOCKS5 proxy
/app/tailscaled --tun=userspace-networking --socks5-server=localhost:1055 &

# Bring up the Tailscale interface
# TAILSCALE_AUTHKEY is an environment variable you must set in Cloud Run secrets
# --hostname provides a name for your Cloud Run instance on your Tailnet
/app/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=cloudrun-evcc --accept-routes --accept-dns

echo "Tailscale started"

# Now run your EVCC application through the SOCKS5 proxy
# ALL_PROXY environment variable forces traffic through the SOCKS5 proxy
ALL_PROXY=socks5://localhost:1055/ /usr/local/bin/evcc
