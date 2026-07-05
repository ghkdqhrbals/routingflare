import XCTest
@testable import TunnelBarCore

final class ReleaseUpdaterTests: XCTestCase {
    func testReleasePlannerFindsDMGAssetAndNormalizesVersion() {
        let dmgURL = URL(string: "https://example.com/routingflare-1.2.0.dmg")!
        let release = GitHubRelease(
            tagName: "v1.2.0",
            htmlURL: URL(string: "https://example.com/releases/v1.2.0"),
            assets: [
                GitHubReleaseAsset(name: "routingflare-1.2.0.zip", browserDownloadURL: URL(string: "https://example.com/app.zip")!),
                GitHubReleaseAsset(name: "routingflare-1.2.0.dmg", browserDownloadURL: dmgURL)
            ]
        )

        let plan = ReleasePlanner.plan(from: release, currentVersion: "1.1.0")

        XCTAssertTrue(plan.isNewer)
        XCTAssertEqual(plan.latestVersion, "1.2.0")
        XCTAssertEqual(plan.currentVersion, "1.1.0")
        XCTAssertEqual(plan.dmgURL, dmgURL)
    }

    func testReleasePlannerTreatsSameVersionAsCurrent() {
        let release = GitHubRelease(
            tagName: "1.1.0",
            htmlURL: nil,
            assets: []
        )

        let plan = ReleasePlanner.plan(from: release, currentVersion: "1.1.0")

        XCTAssertFalse(plan.isNewer)
    }

    func testVersionComparatorUsesNumericOrdering() {
        XCTAssertEqual(VersionComparator.compare("1.10.0", "1.9.0"), .orderedDescending)
        XCTAssertEqual(VersionComparator.compare("1.0.2", "1.0.10"), .orderedAscending)
    }
}
