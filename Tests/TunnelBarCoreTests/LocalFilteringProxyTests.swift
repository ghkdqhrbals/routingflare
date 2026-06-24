import XCTest
@testable import TunnelBarCore

final class LocalFilteringProxyTests: XCTestCase {
    func testStartReturnsAssignedNonZeroLoopbackPort() throws {
        let proxy = LocalFilteringProxy(
            targetPort: 9,
            accessPolicy: MutableProxyAccessPolicy(allowlistEntries: []),
            logHandler: { _ in }
        )
        let port = try proxy.start()
        defer { proxy.stop() }

        XCTAssertGreaterThan(port, 0)
        XCTAssertLessThanOrEqual(port, 65535)
    }
}
