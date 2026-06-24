# RoutingFlare

RoutingFlare is a native macOS menu bar app for exposing local development servers through Cloudflare Tunnel.

Project page: https://ghkdqhrbals.github.io/routingflare/

## Features

- Quick URL routes for temporary `trycloudflare.com` URLs without Cloudflare login.
- DNS routes for existing named Cloudflare Tunnels.
- Route list that maps public host/path entries to local ports.
- Local loopback filtering proxy with exact IP and CIDR inbound allowlists.
- Optional auth header secret filtering.
- Security tab for managing inbound IP allowlist entries.
- Logs tab for tunnel and proxy events.
- About popup with project page, update check, and DMG install/update actions.
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

Local release:

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

GitHub Actions release:

Run **Build Release DMG and Pages** from the Actions tab with a version such as `1.0.0`.
The workflow builds and tests the app, creates `routingflare-<version>.dmg`, notarizes and staples it, creates or updates the GitHub Release, writes `docs/release.json`, and deploys the GitHub Pages introduction page with the current DMG link.

Required repository secrets:

- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `CODESIGN_IDENTITY`
- `APPLE_NOTARY_KEY_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`
