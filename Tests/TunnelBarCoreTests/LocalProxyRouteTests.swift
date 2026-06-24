import XCTest
@testable import TunnelBarCore

final class LocalProxyRouteTests: XCTestCase {
    func testMatchesHostAndPathPrefix() {
        let route = LocalProxyRoute(hostname: "lowfidev.cloud", targetPort: 8989, targetPath: "/console")

        XCTAssertTrue(route.matches(host: "lowfidev.cloud", path: "/console/index.html"))
        XCTAssertTrue(route.matches(host: "lowfidev.cloud:443", path: "/console/admin.html"))
        XCTAssertFalse(route.matches(host: "api.lowfidev.cloud", path: "/console/index.html"))
        XCTAssertFalse(route.matches(host: "lowfidev.cloud", path: "/scalar"))
    }

    func testRootPathMatchesAllPathsForHost() {
        let route = LocalProxyRoute(hostname: "lowfidev.cloud", targetPort: 8989, targetPath: "/")

        XCTAssertTrue(route.matches(host: "lowfidev.cloud", path: "/console/index.html"))
        XCTAssertTrue(route.matches(host: "lowfidev.cloud", path: "/"))
    }

    func testEmptyHostnameMatchesAnyQuickTunnelHost() {
        let route = LocalProxyRoute(hostname: "", targetPort: 8989, targetPath: "/console")

        XCTAssertTrue(route.matches(host: "random.trycloudflare.com", path: "/console/index.html"))
        XCTAssertFalse(route.matches(host: "random.trycloudflare.com", path: "/scalar"))
    }
}
