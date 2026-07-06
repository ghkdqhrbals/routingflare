import XCTest
@testable import TunnelBarCore

final class TunnelCommandTests: XCTestCase {
    func testQuickUrlCommandExposesProxyPort() {
        let command = TunnelCommandBuilder.quickURL(
            cloudflaredPath: "/usr/local/bin/cloudflared",
            proxyPort: 61422
        )

        XCTAssertEqual(command.executable, "/usr/local/bin/cloudflared")
        XCTAssertEqual(command.arguments, [
            "tunnel",
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

    func testDetectsRegisteredTunnelConnectionOutput() {
        let output = """
        2026-07-06T09:28:13Z INF Registered tunnel connection connIndex=1 connection=bb1577e2-a492-46ab-82ef-34a567834fd0 event=0 ip=198.41.192.37 location=icn06 protocol=quic
        """

        XCTAssertTrue(TunnelURLParser.outputShowsRegisteredConnection(output))
        XCTAssertFalse(TunnelURLParser.outputShowsRegisteredConnection("2026-07-06T09:28:13Z INF Retrying connection in up to 1m4s"))
    }

    func testDetectsCloudflaredConnectionRetryIssue() {
        let output = """
        2026-07-06T15:16:15Z ERR failed to run the datagram handler error="context canceled" connIndex=2 event=0 ip=198.41.192.37
        2026-07-06T15:16:15Z WRN failed to serve tunnel connection error="control stream encountered a failure while serving" connIndex=2 event=0 ip=198.41.192.37
        2026-07-06T15:16:15Z WRN Serve tunnel error error="control stream encountered a failure while serving" connIndex=2 event=0 ip=198.41.192.37
        2026-07-06T15:16:15Z INF Retrying connection in up to 16s connIndex=2 event=0 ip=198.41.192.37
        """

        XCTAssertTrue(TunnelURLParser.outputShowsConnectionRetryIssue(output))
    }

    func testDoesNotClassifyOriginFailureAsConnectionRetryIssue() {
        let output = """
        2026-07-06T13:50:59Z ERR error="Unable to reach the origin service. The service may be down or it may not be responding to traffic from cloudflared: net/http: HTTP/1.x transport connection broken: unsupported transfer encoding: \\"Identity\\"" connIndex=1 event=1 ingressRule=0 originService=http://127.0.0.1:64027
        """

        XCTAssertFalse(TunnelURLParser.outputShowsConnectionRetryIssue(output))
    }
}
