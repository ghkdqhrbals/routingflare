import XCTest
@testable import TunnelBarCore

final class PublicURLBuilderTests: XCTestCase {
    func testAppendsTargetPathToQuickTunnelBaseURL() {
        let url = PublicURLBuilder.build(
            baseURL: URL(string: "https://example.trycloudflare.com")!,
            targetPath: "/console/admin.html"
        )

        XCTAssertEqual(url?.absoluteString, "https://example.trycloudflare.com/console/admin.html")
    }

    func testKeepsBaseURLWhenTargetPathIsRootOrEmpty() {
        let baseURL = URL(string: "https://example.trycloudflare.com")!

        XCTAssertEqual(PublicURLBuilder.build(baseURL: baseURL, targetPath: "")?.absoluteString, "https://example.trycloudflare.com")
        XCTAssertEqual(PublicURLBuilder.build(baseURL: baseURL, targetPath: "/")?.absoluteString, "https://example.trycloudflare.com/")
    }

    func testPreservesQueryInTargetPath() {
        let url = PublicURLBuilder.build(
            baseURL: URL(string: "https://example.trycloudflare.com")!,
            targetPath: "/console/admin.html?tab=streams"
        )

        XCTAssertEqual(url?.absoluteString, "https://example.trycloudflare.com/console/admin.html?tab=streams")
    }

    func testBuildsAllHostnameAndPathCombinations() {
        let urls = PublicURLBuilder.buildAll(
            hostnames: ["lowfidev.cloud", "api.lowfidev.cloud"],
            targetPaths: ["/console/index.html", "/console/admin.html"]
        ).map(\.absoluteString)

        XCTAssertEqual(urls, [
            "https://lowfidev.cloud/console/index.html",
            "https://lowfidev.cloud/console/admin.html",
            "https://api.lowfidev.cloud/console/index.html",
            "https://api.lowfidev.cloud/console/admin.html"
        ])
    }
}
