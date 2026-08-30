#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${PROXY_OUTPUT:-$ROOT_DIR/.build/proxy/routingflare-proxy}"
mkdir -p "$(dirname "$OUTPUT")"
FLAGS=(-trimpath)
if [[ "${PROXY_RACE:-0}" == "1" ]]; then
  FLAGS+=(-race)
fi
cd "$ROOT_DIR/Proxy"
go build "${FLAGS[@]}" -ldflags='-s -w' -o "$OUTPUT" .
echo "$OUTPUT"
