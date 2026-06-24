# routingflare

Open public URLs from localhost in seconds.

routingflare is a tiny macOS menu bar app for Cloudflare Tunnel. Use Quick URL for an instant random `trycloudflare.com` address, or DNS routes for your own hostname.

[Download DMG](https://github.com/ghkdqhrbals/routingflare/releases/latest) · [Project page](https://ghkdqhrbals.github.io/routingflare/)

![routingflare](docs/assets/routingflare-hero.png)

## Features

- Quick URL: expose a local port with a temporary public URL.
- DNS: connect your own hostname to a local port and path.
- Security: inbound IP allowlist and optional auth header.
- Logs: Cloudflare Tunnel and local proxy events.
- Updates: check, install, and restart from the app.

## Screenshots

![DNS routes](docs/assets/routingflare-dns-live.png)

![Security](docs/assets/routingflare-security-live.png)

## Development

```bash
swift test --scratch-path .build
swift run TunnelBar
```

## License

routingflare is proprietary, non-commercial software. Use, redistribution, and
modified distribution require explicit written permission and attribution.
Commercial use is prohibited without a separate written license.

See [LICENSE](LICENSE).
