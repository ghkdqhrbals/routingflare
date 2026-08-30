#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/${APP_NAME:-routingflare}.app"
HELPER="$APP_DIR/Contents/MacOS/routingflare-proxy"
test -x "$HELPER"
codesign --verify --strict "$HELPER"
cd "$ROOT_DIR"
swift build -c release --product ProxyIntegrationHost
TEST_DIR="$(mktemp -d "$ROOT_DIR/.build/proxy-package-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cp "$ROOT_DIR/.build/release/ProxyIntegrationHost" "$TEST_DIR/ProxyIntegrationHost"
cp "$HELPER" "$TEST_DIR/routingflare-proxy"
cd "$ROOT_DIR/Proxy"
ROUTINGFLARE_PROXY_TEST_BINARY="$TEST_DIR/ProxyIntegrationHost" go test -v -count=1 -timeout 180s ./...
