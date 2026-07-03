# routingflare

Open public URLs from localhost in seconds.

routingflare is a tiny macOS app for Cloudflare Tunnel. Use Random DNS for an instant `trycloudflare.com` address, or DNS routes for your own hostname.

[Download DMG](https://github.com/ghkdqhrbals/routingflare/releases/latest) · [Project page](https://ghkdqhrbals.github.io/routingflare/)

![routingflare](docs/assets/routingflare-hero.png)

## Features

- Random DNS: expose a local port with a temporary public URL.
- DNS: connect your own hostname to a local port and path.
- Security: inbound IP allowlist and optional auth header.
- Logs: Cloudflare Tunnel and local proxy events.
- Updates: check, install, and restart from the app.
- CLI: add, remove, list, start, stop, and open routingflare from Terminal.

## CLI

The DMG includes a CLI binary inside the app bundle:

```bash
/Applications/routingflare.app/Contents/MacOS/routingflare
```

Optional shell install:

```bash
mkdir -p ~/.local/bin
ln -sf /Applications/routingflare.app/Contents/MacOS/routingflare ~/.local/bin/routingflare
```

Make sure `~/.local/bin` is in your `PATH`.

### Common Commands

```bash
routingflare list
routingflare add random --port 3000
routingflare add random --port 3000 --path /console
routingflare add dns --host dev.example.com --port 8080 --path /console
routingflare remove random 1
routingflare remove dns 1
routingflare start
routingflare stop
routingflare open
routingflare settings
```

### Options

```bash
routingflare autostart on
routingflare autostart off
routingflare cloudflared /opt/homebrew/bin/cloudflared
```

### How The CLI Works

The CLI writes routingflare settings to the same local preferences used by the app, then sends the running app a reload/start/stop/open command. If the app is not open, `start`, `open`, and `settings` try to launch it automatically.

Examples:

```bash
# Create a temporary trycloudflare.com route for localhost:3000
routingflare add random --port 3000
routingflare start

# Route only a path to a local dev server
routingflare add random --port 3000 --path /admin

# Use your own hostname with an existing Cloudflare tunnel config
routingflare add dns --host dev.example.com --port 8080 --path /console
```

## Screenshots

![DNS routes](docs/assets/routingflare-dns-live.png)

![Security](docs/assets/routingflare-security-live.png)

## Development

```bash
swift test --scratch-path .build
swift run TunnelBar
swift run routingflare help
```

## License

routingflare is proprietary, non-commercial software. Use, redistribution, and
modified distribution require explicit written permission and attribution.
Commercial use is prohibited without a separate written license.

See [LICENSE](LICENSE).
