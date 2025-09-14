#!/bin/sh
set -e

# Export the proxy variable so all subsequent commands inherit it.
export ALL_PROXY=socks5://127.0.0.1:1055/

# Start the Tailscale daemon in the background
/app/tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 &
sleep 3

# Bring Tailscale up
/app/tailscale up --authkey=${TAILSCALE_AUTHKEY} --hostname=evcc-container --accept-dns=true --accept-routes=true

echo "✅ Tailscale is connected and running."

# Now that Tailscale is running, its proxy is active.
# The ALL_PROXY variable is already exported, so we can just execute the command.
exec /app/entrypoint.sh evcc --config /etc/evcc.yaml