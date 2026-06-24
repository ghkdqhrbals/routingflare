import XCTest
@testable import TunnelBarCore

final class CloudflaredConfigTests: XCTestCase {
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
