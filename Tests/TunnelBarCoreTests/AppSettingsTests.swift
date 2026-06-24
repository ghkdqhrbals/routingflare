import XCTest
@testable import TunnelBarCore

final class AppSettingsTests: XCTestCase {
    func testDefaultsKeepQuickAndDNSRoutesSeparate() {
        let settings = AppSettings()

        XCTAssertEqual(settings.targetPort, 3000)
        XCTAssertEqual(settings.targetPaths, ["/"])
        XCTAssertEqual(settings.dnsTargetPort, 3000)
        XCTAssertEqual(settings.dnsTargetPaths, ["/"])
    }

    func testDecodingLegacySettingsCopiesExistingLocalRouteToDNSDefaults() throws {
        let json = """
        {
          "targetPort": 8989,
          "targetPath": "/console/index.html",
          "targetPaths": ["/console/index.html", "/console/admin.html"],
          "mode": "dns",
          "dnsHostname": "lowfidev.cloud"
        }
        """.data(using: .utf8)!

        let settings = try JSONDecoder().decode(AppSettings.self, from: json)

        XCTAssertEqual(settings.targetPort, 8989)
        XCTAssertEqual(settings.targetPaths, ["/console/index.html", "/console/admin.html"])
        XCTAssertEqual(settings.dnsTargetPort, 8989)
        XCTAssertEqual(settings.dnsTargetPaths, ["/console/index.html", "/console/admin.html"])
        XCTAssertEqual(settings.dnsHostnames, ["lowfidev.cloud"])
    }
}
