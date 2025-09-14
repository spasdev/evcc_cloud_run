#!/bin/sh

/app/tailscaled --tun=userspace-networking --socks5-server=127.0.0.1:1055 &
/app/tailscale up --auth-key=${TAILSCALE_AUTHKEY} --hostname=cloudrun-evcc --accept-dns=true --accept-routes=true
echo Tailscale started
ALL_PROXY=socks5://127.0.0.1:1055/ evcc --config /etc/evcc.yaml