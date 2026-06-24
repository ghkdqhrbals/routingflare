import XCTest
@testable import TunnelBarCore

final class TunnelCommandTests: XCTestCase {
    func testQuickUrlCommandExposesProxyPort() {
        let command = TunnelCommandBuilder.quickURL(
            cloudflaredPath: "/usr/local/bin/cloudflared",
            proxyPort: 61422,
            configPath: "/tmp/tunnelbar-empty.yml"
        )

        XCTAssertEqual(command.executable, "/usr/local/bin/cloudflared")
        XCTAssertEqual(command.arguments, [
            "tunnel",
            "--config",
            "/tmp/tunnelbar-empty.yml",
            "--url",
            "http://127.0.0.1:61422"
        ])
    }

    func testDNSCommandUsesToken() {
        let command = TunnelCommandBuilder.dns(
            cloudflaredPath: "/opt/tunnelbar/cloudflared",
            token: "secret-token"
        )

        XCTAssertEqual(command.executable, "/opt/tunnelbar/cloudflared")
        XCTAssertEqual(command.arguments, [
            "tunnel",
            "--no-autoupdate",
            "run",
            "--token",
            "secret-token"
        ])
    }

    func testDNSLocalConfigCommandUsesConfigFile() {
        let command = TunnelCommandBuilder.dnsLocalConfig(
            cloudflaredPath: "/opt/homebrew/bin/cloudflared",
            configPath: "/tmp/tunnelbar/config.yml"
        )

        XCTAssertEqual(command.executable, "/opt/homebrew/bin/cloudflared")
        XCTAssertEqual(command.arguments, [
            "tunnel",
            "--config",
            "/tmp/tunnelbar/config.yml",
            "run"
        ])
    }

    func testParsesTryCloudflareURLFromOutput() {
        let output = """
        2026-06-24T12:00:00Z INF Requesting new quick Tunnel on trycloudflare.com...
        2026-06-24T12:00:01Z INF +--------------------------------------------------------------------------------------------+
        2026-06-24T12:00:01Z INF |  Your quick Tunnel has been created! Visit it at (it may take some time to be reachable):  |
        2026-06-24T12:00:01Z INF |  https://example-widget.trycloudflare.com                                                     |
        """

        XCTAssertEqual(TunnelURLParser.parsePublicURL(from: output), URL(string: "https://example-widget.trycloudflare.com"))
    }
}
