import XCTest
@testable import TunnelBarCore

final class ProxyPolicyTests: XCTestCase {
    func testAllowsRequestWhenHeaderAddressIsAllowed() throws {
        let policy = ProxyAccessPolicy(allowlistEntries: ["203.0.113.0/24"])

        let decision = policy.decision(for: [
            "cf-connecting-ip": "203.0.113.42"
        ])

        XCTAssertEqual(decision, .allowed(sourceIP: "203.0.113.42"))
    }

    func testBlocksRequestWhenHeaderAddressIsNotAllowed() {
        let policy = ProxyAccessPolicy(allowlistEntries: ["203.0.113.0/24"])

        let decision = policy.decision(for: [
            "cf-connecting-ip": "198.51.100.42"
        ])

        XCTAssertEqual(decision, .blocked(sourceIP: "198.51.100.42"))
    }

    func testUsesFirstForwardedForAddressWhenCloudflareHeaderIsMissing() {
        let policy = ProxyAccessPolicy(allowlistEntries: ["198.51.100.0/24"])

        let decision = policy.decision(for: [
            "x-forwarded-for": "198.51.100.22, 10.0.0.1"
        ])

        XCTAssertEqual(decision, .allowed(sourceIP: "198.51.100.22"))
    }

    func testBlocksMissingSourceHeaderWhenAllowlistIsConfigured() {
        let policy = ProxyAccessPolicy(allowlistEntries: ["203.0.113.0/24"])

        XCTAssertEqual(policy.decision(for: [:]), .blocked(sourceIP: nil))
    }

    func testAllowsRequestWhenAuthHeaderMatches() {
        let policy = ProxyAccessPolicy(
            allowlistEntries: [],
            authHeader: ProxyAuthHeader(enabled: true, name: "X-Routingflare-Secret", secret: "secret")
        )

        let decision = policy.decision(for: [
            "X-Routingflare-Secret": "secret"
        ])

        XCTAssertEqual(decision, .allowed(sourceIP: nil))
    }

    func testBlocksRequestWhenAuthHeaderDoesNotMatch() {
        let policy = ProxyAccessPolicy(
            allowlistEntries: [],
            authHeader: ProxyAuthHeader(enabled: true, name: "X-Routingflare-Secret", secret: "secret")
        )

        let decision = policy.decision(for: [
            "X-Routingflare-Secret": "wrong"
        ])

        XCTAssertEqual(decision, .blocked(sourceIP: nil))
    }

    func testDisabledAuthHeaderAllowsRequestWithoutSecret() {
        let policy = ProxyAccessPolicy(
            allowlistEntries: [],
            authHeader: ProxyAuthHeader(enabled: false, name: "X-Routingflare-Secret", secret: "secret")
        )

        XCTAssertEqual(policy.decision(for: [:]), .allowed(sourceIP: nil))
    }
}
