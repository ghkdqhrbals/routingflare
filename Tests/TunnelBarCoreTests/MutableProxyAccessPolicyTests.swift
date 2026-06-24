import XCTest
@testable import TunnelBarCore

final class MutableProxyAccessPolicyTests: XCTestCase {
    func testUpdatesAllowlistWithoutRecreatingPolicy() {
        let policy = MutableProxyAccessPolicy(allowlistEntries: [])

        XCTAssertEqual(
            policy.decision(for: ["cf-connecting-ip": "198.51.100.42"]),
            .allowed(sourceIP: "198.51.100.42")
        )

        policy.update(allowlistEntries: ["203.0.113.0/24"])

        XCTAssertEqual(
            policy.decision(for: ["cf-connecting-ip": "198.51.100.42"]),
            .blocked(sourceIP: "198.51.100.42")
        )
        XCTAssertEqual(
            policy.decision(for: ["cf-connecting-ip": "203.0.113.42"]),
            .allowed(sourceIP: "203.0.113.42")
        )
    }
}
