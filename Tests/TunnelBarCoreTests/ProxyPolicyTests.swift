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

    func testRouteSecurityBuildsRouteSpecificAccessPolicy() {
        let route = LocalProxyRoute(
            hostname: "dev.example.com",
            targetPort: 8080,
            targetPath: "/console",
            security: RouteSecurity(
                allowlistEntries: ["203.0.113.0/24"],
                authHeaderEnabled: true,
                authHeaderName: "X-Route-Secret",
                authHeaderSecret: "secret"
            )
        )

        let allowed = route.accessPolicy(defaultPolicy: .allowAll).decision(for: [
            "cf-connecting-ip": "203.0.113.12",
            "X-Route-Secret": "secret"
        ])
        let blockedByIP = route.accessPolicy(defaultPolicy: .allowAll).decision(for: [
            "cf-connecting-ip": "198.51.100.12",
            "X-Route-Secret": "secret"
        ])
        let blockedBySecret = route.accessPolicy(defaultPolicy: .allowAll).decision(for: [
            "cf-connecting-ip": "203.0.113.12",
            "X-Route-Secret": "wrong"
        ])

        XCTAssertEqual(allowed, .allowed(sourceIP: "203.0.113.12"))
        XCTAssertEqual(blockedByIP, .blocked(sourceIP: "198.51.100.12"))
        XCTAssertEqual(blockedBySecret, .blocked(sourceIP: "203.0.113.12"))
    }

    func testRouteWithoutSecurityUsesDefaultPolicy() {
        let route = LocalProxyRoute(hostname: "dev.example.com", targetPort: 8080, targetPath: "/")
        let defaultPolicy = ProxyAccessPolicy(allowlistEntries: ["203.0.113.0/24"])

        XCTAssertEqual(
            route.accessPolicy(defaultPolicy: defaultPolicy).decision(for: ["cf-connecting-ip": "198.51.100.12"]),
            .blocked(sourceIP: "198.51.100.12")
        )
    }

    func testMutableRouteSecurityPoliciesUpdatesPolicyForExistingRoute() {
        let route = LocalProxyRoute(hostname: "dev.example.com", targetPort: 8080, targetPath: "/")
        let policies = MutableRouteSecurityPolicies(routes: [route])

        XCTAssertEqual(
            policies.accessPolicy(for: route, defaultPolicy: .allowAll).decision(for: ["cf-connecting-ip": "198.51.100.12"]),
            .allowed(sourceIP: "198.51.100.12")
        )

        policies.update(routes: [
            LocalProxyRoute(
                hostname: "dev.example.com",
                targetPort: 8080,
                targetPath: "/",
                security: RouteSecurity(allowlistEntries: ["203.0.113.0/24"])
            )
        ])

        XCTAssertEqual(
            policies.accessPolicy(for: route, defaultPolicy: .allowAll).decision(for: ["cf-connecting-ip": "198.51.100.12"]),
            .blocked(sourceIP: "198.51.100.12")
        )
    }
}
