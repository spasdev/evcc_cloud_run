#!/bin/sh
set -e

# 1. Start the Tailscale daemon in the background.
/app/tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 &
sleep 3

# 2. Bring Tailscale up and have it manage DNS and routes.
/app/tailscale up --authkey=${TAILSCALE_AUTHKEY} --hostname=evcc-container --accept-dns=true --accept-routes=true

sleep 10

echo "✅ Tailscale is connected and running."

# 4. Execute the evcc application directly, setting the environment variable
#    only for this specific command.
exec env ALL_PROXY=socks5://127.0.0.1:1055/ evcc --config /etc/evcc.yaml