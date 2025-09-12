#!/bin/sh
set -e

# Start the Tailscale daemon in ephemeral mode, using a direct IP for the proxy.
/app/tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 --state=mem: &

# Give the daemon a moment to start before checking its status.
sleep 2

# --- Bring Tailscale Up ---
# Use --accept-dns=false as a best practice in server environments.
/app/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=evcc-container --accept-dns=true --accept-routes=true

echo "Tailscale started successfully."

# Run the evcc application using the correct config path and proxy settings.
exec env ALL_PROXY=socks5://127.0.0.1:1055/ \
     /app/entrypoint.sh evcc --config /etc/evcc.yaml