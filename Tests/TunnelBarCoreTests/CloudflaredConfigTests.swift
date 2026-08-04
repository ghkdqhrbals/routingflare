import XCTest
@testable import TunnelBarCore

final class CloudflaredConfigTests: XCTestCase {
    func testParsesNamedTunnelNameFromCloudflaredInfo() {
        let output = """
        NAME:     routingflare-dev
        ID:       bfa54c97-8cd1-4678-b283-0efb3c66022e
        CREATED:  2026-07-05 19:21:15.966352 +0000 UTC
        """

        XCTAssertEqual(
            CloudflaredTunnelInfoParser.parseName(from: output),
            "routingflare-dev"
        )
    }

    func testMissingNamedTunnelNameReturnsNil() {
        XCTAssertNil(CloudflaredTunnelInfoParser.parseName(from: "ID: tunnel-id"))
    }

    func testRendersNamedTunnelIngressToProxyPort() {
        let config = CloudflaredConfigRenderer.renderNamedTunnelConfig(
            tunnelID: "24c83c3f-3c20-402f-a9ca-247ca8d25fbb",
            credentialsFile: "~/.cloudflared/24c83c3f-3c20-402f-a9ca-247ca8d25fbb.json",
            hostname: "lowfidev.cloud",
            proxyPort: 64775
        )

        XCTAssertEqual(config, """
        tunnel: 24c83c3f-3c20-402f-a9ca-247ca8d25fbb
        credentials-file: ~/.cloudflared/24c83c3f-3c20-402f-a9ca-247ca8d25fbb.json

        ingress:
          - hostname: lowfidev.cloud
            service: http://127.0.0.1:64775
          - service: http_status:404
        """)
    }

    func testRendersMultipleHostnamesToSameProxyPort() {
        let config = CloudflaredConfigRenderer.renderNamedTunnelConfig(
            tunnelID: "24c83c3f-3c20-402f-a9ca-247ca8d25fbb",
            credentialsFile: "~/.cloudflared/24c83c3f-3c20-402f-a9ca-247ca8d25fbb.json",
            hostnames: ["lowfidev.cloud", "api.lowfidev.cloud"],
            proxyPort: 64775
        )

        XCTAssertEqual(config, """
        tunnel: 24c83c3f-3c20-402f-a9ca-247ca8d25fbb
        credentials-file: ~/.cloudflared/24c83c3f-3c20-402f-a9ca-247ca8d25fbb.json

        ingress:
          - hostname: lowfidev.cloud
            service: http://127.0.0.1:64775
          - hostname: api.lowfidev.cloud
            service: http://127.0.0.1:64775
          - service: http_status:404
        """)
    }
}
