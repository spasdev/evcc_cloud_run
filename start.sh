#!/bin/sh
set -e

# Start the Tailscale daemon in the background in userspace networking mode
# and create a SOCKS5 proxy.
/app/tailscaled --tun=userspace-networking --socks5-server=localhost:1055 &

# --- Wait for Tailscale to start ---
# This loop waits for the daemon to be ready before continuing.
counter=0
until /app/tailscale status > /dev/null 2>&1; do
    counter=$((counter+1))
    if [ $counter -ge 10 ]; then
        echo "tailscaled failed to start after 10 seconds."
        exit 1
    fi
    echo "Waiting for tailscaled to start... (attempt $counter)"
    sleep 1
done
echo "tailscaled daemon is running."
# ------------------------------------

# Bring the Tailscale interface up using an auth key from the TAILSCALE_AUTHKEY
# environment variable. You can customize the hostname.
/app/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=evcc-container

echo "Tailscale started successfully."

# Run the original application entrypoint, wrapping it with the SOCKS5 proxy.
# This ensures the application's traffic goes through the Tailscale network.
exec env ALL_PROXY=socks5://localhost:1055/ /app/entrypoint.sh evcc