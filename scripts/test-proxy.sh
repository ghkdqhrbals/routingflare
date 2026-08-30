#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export GORACE="${GORACE:-atexit_sleep_ms=0}"
PROXY_RACE=1 "$ROOT_DIR/scripts/build-proxy.sh"
cd "$ROOT_DIR/Proxy"
go test -race -count=1 -timeout 180s ./...
cd "$ROOT_DIR"
swift build --product ProxyIntegrationHost
cd "$ROOT_DIR/Proxy"
ROUTINGFLARE_PROXY_TEST_BINARY="$ROOT_DIR/.build/debug/ProxyIntegrationHost" go test -count=1 -timeout 180s ./...
cd "$ROOT_DIR"
swift test
