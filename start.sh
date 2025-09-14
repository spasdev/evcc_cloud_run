#!/bin/sh
set -e

# Export the proxy variable so all child processes will inherit it.
export ALL_PROXY=socks5://127.0.0.1:1055/

# Start the Tailscale daemon in the background.
/app/tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 &
sleep 3

# Bring Tailscale up.
/app/tailscale up --authkey=${TAILSCALE_AUTHKEY} --hostname=evcc-container --accept-dns=true --accept-routes=true
sleep 10

echo "Tailscale 'up' command issued. Proceeding without waiting for connection."

# Execute your entrypoint script immediately.
exec /app/entrypoint.sh evcc --config /etc/evcc.yaml