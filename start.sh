#!/bin/sh
set -e

# Start the Tailscale daemon in the background in userspace networking mode
# and create a SOCKS5 proxy.
/app/tailscaled --tun=userspace-networking --socks5-server=localhost:1055 &

# Add a short delay to allow the tailscaled daemon to initialize
sleep 2

# Bring the Tailscale interface up using an auth key from the TAILSCALE_AUTHKEY
# environment variable. You can customize the hostname.
/app/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=evcc-container

echo "Tailscale started successfully."

# Run the original application entrypoint, wrapping it with the SOCKS5 proxy.
# This ensures the application's traffic goes through the Tailscale network.
exec env ALL_PROXY=socks5://localhost:1055/ /app/entrypoint.sh evcc