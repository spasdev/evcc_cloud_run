#!/bin/sh
set -e

echo "--- Running Network Diagnostics before tailscale started ---"

echo "DNS Configuration before tailscale started:"
cat /etc/resolv.conf
echo

echo "Pinging Google's DNS Server before tailscale started:"
ping -c 4 8.8.8.8
echo

echo "Resolving api.zaptec.com before tailscale started:"
nslookup api.zaptec.com
echo


# Start the Tailscale daemon in ephemeral mode, using a direct IP for the proxy.
/app/tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 &

# Give the daemon a moment to start before checking its status.
sleep 2

# --- Bring Tailscale Up ---
# Use --accept-dns=false as a best practice in server environments.
/app/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=evcc-container --accept-dns=true --accept-routes=true

echo "Tailscale started successfully."

# Wait until the connection is fully established
until /app/tailscale status | grep -q "Running"; do
    echo "Waiting for Tailscale to start..."
    sleep 2
done

echo "--- Running Network Diagnostics after tailscale started ---"

echo "DNS Configuration after tailscale started:"
cat /etc/resolv.conf
echo

echo "Pinging Google's DNS Server after tailscale started:"
ping -c 4 8.8.8.8
echo

echo "Resolving api.zaptec.com after tailscale started:"
nslookup api.zaptec.com
echo

# Run the evcc application using the correct config path and proxy settings.
exec env ALL_PROXY=socks5://127.0.0.1:1055/ \
     /app/entrypoint.sh evcc --config /etc/evcc.yaml