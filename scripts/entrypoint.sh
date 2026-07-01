#!/bin/sh
set -e
if [ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]; then
  cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TUNNEL_TOKEN" &
fi
exec ./blt-server
