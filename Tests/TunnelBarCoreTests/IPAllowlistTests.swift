import XCTest
@testable import TunnelBarCore

final class IPAllowlistTests: XCTestCase {
    func testEmptyAllowlistAllowsAnyAddress() throws {
        let allowlist = try IPAllowlist(entries: [])

        XCTAssertTrue(allowlist.allows("203.0.113.10"))
        XCTAssertTrue(allowlist.allows("2001:db8::1"))
    }

    func testExactIPv4AndCIDRMatching() throws {
        let allowlist = try IPAllowlist(entries: ["203.0.113.10", "198.51.100.0/24"])

        XCTAssertTrue(allowlist.allows("203.0.113.10"))
        XCTAssertTrue(allowlist.allows("198.51.100.77"))
        XCTAssertFalse(allowlist.allows("203.0.113.11"))
    }

    func testIPv6CIDRMatching() throws {
        let allowlist = try IPAllowlist(entries: ["2001:db8:abcd::/48"])

        XCTAssertTrue(allowlist.allows("2001:db8:abcd::55"))
        XCTAssertFalse(allowlist.allows("2001:db8:abce::55"))
    }

    func testInvalidEntryThrows() {
        XCTAssertThrowsError(try IPAllowlist(entries: ["bad-entry"]))
        XCTAssertThrowsError(try IPAllowlist(entries: ["203.0.113.10/99"]))
    }
}
