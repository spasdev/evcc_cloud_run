#!/bin/sh
set -e

# CHANGE 1: Use the IP address 127.0.0.1 instead of "localhost"
/app/tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 --state=mem: -verbose 2 & 

echo "start the tailscale checks"

# --- Wait for Tailscale to start ---
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

/app/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=evcc-container

echo "Tailscale started successfully."

# CHANGE 2: Also update the ALL_PROXY variable to use the IP address
exec env ALL_PROXY=socks5://127.0.0.1:1055/ \
     EVCC_HOST="0.0.0.0" \
     EVCC_PORT="${PORT}" \
     /app/entrypoint.sh evcc --config /app/evcc.yaml