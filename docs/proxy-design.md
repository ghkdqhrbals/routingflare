# Streaming Proxy Contract

## Scope

The proxy preserves the body bytes, end-to-end header values, repeated headers,
status codes, trailers, and streaming behavior of supported, valid requests.
It does not promise identical HTTP wire bytes: HTTP/1 chunk boundaries, HTTP/2
frames, header casing/order, and hop-by-hop fields belong to each connection.

| Protocol | Local routingflare proxy | Public Cloudflare Tunnel |
| --- | --- | --- |
| HTTP/1.1, uploads, streaming responses | Streaming, without whole-body buffering | Subject to Cloudflare limits |
| WebSocket (HTTP/1.1 upgrade) | Handshake, subprotocols, compression, binary/text, ping/pong, close | Supported |
| SSE | Flushes events before the response ends | Use a named DNS tunnel; **Random DNS does not support SSE** |
| HTTP/2 prior knowledge (h2c) | Accepts HTTP/2 streams; ordinary HTTP uses an HTTP/1.1 origin | Not an end-to-end protocol guarantee |
| Native gRPC | h2c origin; unary, client/server/bidirectional streaming, metadata and trailers | **Public-hostname tunnels do not support gRPC** |

Cloudflare documents [Quick Tunnel's SSE limitation](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/)
and [gRPC's private-network-only Tunnel support](https://developers.cloudflare.com/cloudflare-one/faq/cloudflare-tunnels-faq/).
Changing the local proxy cannot remove those restrictions. End-to-end public
gRPC needs a different supported ingress architecture, not an `http2Origin`
toggle or a different header. This change does not create private network routes.

## Data Path

```text
Client -> Cloudflare -> cloudflared -> 127.0.0.1:ephemeral -> local port
                                    Go ReverseProxy       HTTP/1.1 or h2c
```

`LocalFilteringProxy` owns a bundled `routingflare-proxy` process. The data path
uses Go's standard `net/http` and `httputil.ReverseProxy`; Swift no longer parses
HTTP, reconstructs bodies, or uses URLSession to forward requests.

- No complete request/response buffering, cookie jar, redirect following, caching,
  automatic compression, or decompression.
- Preserve the original Host, Origin, Cookie, Authorization, raw path/query,
  repeated Set-Cookie fields, and application error responses. Security validates
  a supplied secret; it does not inject a secret into outgoing requests.
- The HTTP engine owns Content-Length, chunk framing, hop-by-hop fields,
  WebSocket upgrade negotiation, flow control and trailers. Request trailer
  storage stays linked to the incoming body reader until EOF.
- Flush every response write. Enable HTTP/1 full duplex so a response can arrive
  while its request is still uploading. Each copy buffer is 32 KiB, independent
  of total body size; HTTP/TCP flow-control buffers are additional.
- Native `application/grpc` and `application/grpc+...` requests use an h2c
  (plaintext HTTP/2) local origin. Other requests use HTTP/1.1. No failed POST or
  stream is replayed as a protocol-fallback strategy.
- Request cancellation reaches the origin. Stop/owner exit closes active HTTP,
  HTTP/2 and hijacked WebSocket sockets, not just the listening socket.

See [ReverseProxy](https://pkg.go.dev/net/http/httputil#ReverseProxy) and
[net/http protocols](https://pkg.go.dev/net/http#Protocols). As with
[nginx streaming configuration](https://nginx.org/en/docs/http/ngx_http_proxy_module.html#proxy_buffering),
buffering behavior must be explicit; selecting a proxy name alone is not a guarantee.

## Security And Updates

Each HTTP request, including requests on a reused connection and each HTTP/2
stream, independently selects its hostname/path route and checks its current
IP allowlist and secret-header policy. Path matching uses the decoded canonical
path so an encoded `/admin` does not skip an `/admin` policy; the actual forwarded
URL is not rewritten. Do not depend on framework-specific ambiguous URL parsing
as an authorization boundary; use a whole-host policy for sensitive services.

Settings are sent as versioned JSON snapshots through anonymous stdin/stdout
pipes, with monotonically increasing IDs. The helper acknowledges a revision
only after atomically installing it. Updating the shared Swift policy waits for
that acknowledgement. A failed synchronization closes the proxy and reports an
error to the app/CLI status snapshot. There is no public control endpoint and no
extra secret file, environment variable, or command-line secret.

Updates affect **new requests and handshakes**. An already-authorized WebSocket
or long-running HTTP/gRPC stream is not re-authenticated frame by frame and is
not interrupted by an unrelated policy change. Close its proxy to revoke an
established stream immediately.

The listener is IPv4 loopback-only. Cloudflare forwarding headers are trusted
only within that boundary. Other processes on the same machine can still send
loopback requests, so IP filtering is not authentication of an untrusted local
user. Use a secret/origin authentication when that is part of the threat model.

Conflicting Content-Length fields, unsupported transfer encodings and duplicate
security headers fail closed. The HTTP engine parses and regenerates framing;
raw HTTP is not tunneled after a rejected upgrade. An enabled but empty secret
does not disable authentication.
CONNECT, HTTP/1 `Upgrade: h2c`, arbitrary upgrades, HTTP/3/WebTransport, and RFC
8441 extended CONNECT are not supported. They must not become raw tunnels that
bypass subsequent per-request authorization. TLS origins are not added by this
change; the local destination remains `127.0.0.1` over HTTP or h2c.

## Limits And Diagnostics

- 1 MiB request/response headers; 10-second request-header read deadline.
- 90-second idle keepalive expiry, not a deadline on active SSE/WebSocket/gRPC.
- 10-second origin connection timeout; no whole-body or total-stream timeout.
- 2 MiB control-message limit; 5-second configuration acknowledgement deadline.
- Cloudflare's own request size, duration, caching and network limits still apply.
- Network outages cannot be made lossless by retrying a stateful stream. The
  application protocol/client owns reconnection and resumption.

WebSocket logs distinguish local policy rejection from an origin handshake
status (`101`, `401`, `403`, etc.). An origin `403` stays `403`; it is never removed
to make a connection appear healthy. Logs do not include bodies, cookies, auth
headers, or query strings. A native browser WebSocket cannot set arbitrary custom
headers; a required secret header must actually be supplied by a compatible
client. Do not bypass the policy to hide such a rejection.

## Verification

Run `scripts/test-proxy.sh`. It builds the helper with Go's race detector, tests
real loopback sockets, reruns the protocol suite through the same Swift
`LocalFilteringProxy` API used by the app, and runs the Swift unit tests.

For an opt-in Cloudflare WebSocket smoke test, run from `Proxy/` after that build:

```sh
ROUTINGFLARE_TEST_CLOUDFLARED=/opt/homebrew/bin/cloudflared \
ROUTINGFLARE_PROXY_TEST_BINARY=../.build/debug/ProxyIntegrationHost \
go test -v -run '^TestCloudflaredWebSocketEndToEnd$' -timeout 105s
```

This creates a temporary secret-protected echo service and Quick Tunnel, then
closes both. It does not use saved tunnel credentials or change DNS routes.
`ROUTINGFLARE_TEST_DNS_SERVER=1.1.1.1:53` optionally selects a resolver for the
test client only, to diagnose stale system/VPN DNS responses. TLS certificate
verification, SNI and the public hostname remain intact.

Coverage includes split multi-megabyte bodies; chunked uploads and trailers;
SSE before EOF; HTTP full duplex; compressed/binary responses; duplicate cookies;
raw URLs and Host; HEAD/204/304/206 and origin errors; Expect/100-continue and 103;
HTTP/2 trailers; real gRPC unary/streaming/cancellation; real WebSocket upgrade,
compression, frames, ping/pong, reconnect and close; policy changes on reused
connections; rejected upgrades; and cleanup after owner death.

These tests establish local-proxy behavior, not Cloudflare edge availability or
compatibility with every application framework. A user-reported failure still
requires the exact URL, client, handshake status and origin response to reproduce.

### Local Verification: 2026-08-31

- The previous Swift proxy failed split-body upload, chunked upload/trailer,
  incremental SSE/streaming, and rejected-upgrade authorization tests. A basic
  WebSocket echo passed; the user's specific failing endpoint was not provided.
- The replacement passed 20 loopback protocol tests through both the helper and
  the Swift host, plus 65 Swift tests. Go's race detector and `go vet` passed.
- The Release Swift host and the exact bundled, hardened-runtime helper passed
  the same protocol suite and the opt-in public Cloudflare WebSocket test: TLS,
  HTTP 101, subprotocol negotiation, text/binary round trips and close frames.
- The first public test could not resolve its generated hostname through system
  DNS (`100.100.100.100`, NXDOMAIN). `1.1.1.1` returned A records for that same
  hostname. Subsequent public tests used `1.1.1.1` only in the test client's
  resolver and passed. System/VPN DNS settings were not changed; this does not
  establish the cause of the user's unprovided WebSocket failure.
- The app and CLI built successfully; local ad-hoc signatures passed
  `codesign --verify --deep --strict`. The helper links only macOS system
  libraries, not a Homebrew runtime. This is not a notarization result.
- An additional Swift Thread Sanitizer run could not start: macOS rejected the
  sanitizer library in Xcode's `swiftpm-xctest-helper` with "Sanitizer load
  violates platform policy". That check is **unverified**, not passed. No OS
  security settings, signatures on Xcode tools, or installed app were changed.

During this local validation, the installed app was not replaced or restarted
and no release was published. Temporary public echo services were
secret-protected and were closed after their tests.

## Distribution

The helper is built with the pinned Go toolchain, packaged beside the app and
CLI executables, and signed before the app bundle is signed. Go is a build-time
dependency only. DMG and ZIP contain the same helper; it is not downloaded or
compiled on the user's machine. A missing helper fails closed and prompts a
reinstall. The release workflow runs both protocol and Swift tests before signing.
After packaging the app, `scripts/test-packaged-proxy.sh` verifies the helper's
signature and reruns the protocol suite using the Release-built Swift host and
the exact bundled helper, without relying on the Debug source-tree fallback.
