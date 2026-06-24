# RoutingFlare

RoutingFlare is a native macOS menu bar app for exposing local development servers through Cloudflare Tunnel.

## Features

- Quick URL routes for temporary `trycloudflare.com` URLs without Cloudflare login.
- DNS routes for existing named Cloudflare Tunnels.
- Route list that maps public host/path entries to local ports.
- Local loopback filtering proxy with exact IP and CIDR inbound allowlists.
- Settings tab for managing inbound IP allowlist entries.
- Signed DMG release scripts with hardened runtime and notarization support.

## Quick URL

Add a local port and path, then press `Start`.

```text
Quick URL /console -> 127.0.0.1:8989
```

RoutingFlare starts a local proxy and runs:

```bash
cloudflared tunnel --url http://127.0.0.1:<proxyPort>
```

## DNS

DNS mode uses an existing Cloudflare named tunnel. Add hostname, port, and path routes, then set:

- Tunnel ID
- Credentials file path, for example `~/.cloudflared/<tunnel-id>.json`

## Development

```bash
swift test --scratch-path .build
swift run TunnelBar
```

## Release

```bash
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export BUNDLE_ID="com.example.RoutingFlare"
export VERSION="1.0.0"
export BUILD_NUMBER="1"
export NOTARY_KEY_ID="..."
export NOTARY_ISSUER_ID="..."
export NOTARY_KEY_PATH="/path/to/AuthKey_XXXX.p8"

scripts/release-dmg.sh
```

The release flow builds the app bundle, signs it with hardened runtime, creates a DMG, submits it with `xcrun notarytool`, staples the ticket, and verifies with `spctl`.
