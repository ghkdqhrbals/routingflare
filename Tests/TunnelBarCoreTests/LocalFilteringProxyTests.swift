import XCTest
@preconcurrency import Network
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

    func testRouteSpecificSecurityDoesNotLeakBetweenRoutes() async throws {
        let apiServer = try TestHTTPServer(body: "api")
        let adminServer = try TestHTTPServer(body: "admin")
        defer {
            apiServer.stop()
            adminServer.stop()
        }

        let apiRoute = LocalProxyRoute(
            hostname: "api.example.com",
            targetPort: apiServer.port,
            targetPath: "/",
            security: RouteSecurity(
                allowlistEntries: ["203.0.113.0/24"],
                authHeaderEnabled: true,
                authHeaderName: "X-Api-Secret",
                authHeaderSecret: "api-secret"
            )
        )
        let adminRoute = LocalProxyRoute(
            hostname: "admin.example.com",
            targetPort: adminServer.port,
            targetPath: "/",
            security: RouteSecurity(
                allowlistEntries: ["198.51.100.0/24"],
                authHeaderEnabled: true,
                authHeaderName: "X-Admin-Secret",
                authHeaderSecret: "admin-secret"
            )
        )
        let proxy = LocalFilteringProxy(
            routes: [apiRoute, adminRoute],
            fallbackTargetPort: apiServer.port,
            accessPolicy: MutableProxyAccessPolicy(allowlistEntries: []),
            routeSecurityPolicies: MutableRouteSecurityPolicies(routes: [apiRoute, adminRoute]),
            logHandler: { _ in }
        )
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let allowedAPI = try await request(
            proxyPort: proxyPort,
            host: "api.example.com",
            path: "/status",
            headers: [
                "CF-Connecting-IP": "203.0.113.42",
                "X-Api-Secret": "api-secret"
            ]
        )
        let blockedAPIWithAdminCredentials = try await request(
            proxyPort: proxyPort,
            host: "api.example.com",
            path: "/status",
            headers: [
                "CF-Connecting-IP": "198.51.100.42",
                "X-Admin-Secret": "admin-secret"
            ]
        )
        let allowedAdmin = try await request(
            proxyPort: proxyPort,
            host: "admin.example.com",
            path: "/status",
            headers: [
                "CF-Connecting-IP": "198.51.100.42",
                "X-Admin-Secret": "admin-secret"
            ]
        )
        let blockedAdminWithAPICredentials = try await request(
            proxyPort: proxyPort,
            host: "admin.example.com",
            path: "/status",
            headers: [
                "CF-Connecting-IP": "203.0.113.42",
                "X-Api-Secret": "api-secret"
            ]
        )

        XCTAssertEqual(allowedAPI.statusCode, 200)
        XCTAssertEqual(allowedAPI.body, "api")
        XCTAssertEqual(blockedAPIWithAdminCredentials.statusCode, 403)
        XCTAssertEqual(allowedAdmin.statusCode, 200)
        XCTAssertEqual(allowedAdmin.body, "admin")
        XCTAssertEqual(blockedAdminWithAPICredentials.statusCode, 403)
    }

    func testRouteSpecificSecurityAppliesToMoreSpecificPathOnly() async throws {
        let publicServer = try TestHTTPServer(body: "public")
        let adminServer = try TestHTTPServer(body: "admin")
        defer {
            publicServer.stop()
            adminServer.stop()
        }

        let publicRoute = LocalProxyRoute(hostname: "dev.example.com", targetPort: publicServer.port, targetPath: "/")
        let adminRoute = LocalProxyRoute(
            hostname: "dev.example.com",
            targetPort: adminServer.port,
            targetPath: "/admin",
            security: RouteSecurity(
                authHeaderEnabled: true,
                authHeaderName: "X-Admin-Secret",
                authHeaderSecret: "admin-secret"
            )
        )
        let proxy = LocalFilteringProxy(
            routes: [publicRoute, adminRoute],
            fallbackTargetPort: publicServer.port,
            accessPolicy: MutableProxyAccessPolicy(allowlistEntries: []),
            routeSecurityPolicies: MutableRouteSecurityPolicies(routes: [publicRoute, adminRoute]),
            logHandler: { _ in }
        )
        let proxyPort = try proxy.start()
        defer { proxy.stop() }

        let publicResponse = try await request(proxyPort: proxyPort, host: "dev.example.com", path: "/health")
        let blockedAdmin = try await request(proxyPort: proxyPort, host: "dev.example.com", path: "/admin/users")
        let allowedAdmin = try await request(
            proxyPort: proxyPort,
            host: "dev.example.com",
            path: "/admin/users",
            headers: ["X-Admin-Secret": "admin-secret"]
        )

        XCTAssertEqual(publicResponse.statusCode, 200)
        XCTAssertEqual(publicResponse.body, "public")
        XCTAssertEqual(blockedAdmin.statusCode, 403)
        XCTAssertEqual(allowedAdmin.statusCode, 200)
        XCTAssertEqual(allowedAdmin.body, "admin")
    }

    func testResponseHeaderFilterRemovesHopByHopHeaders() {
        let headers = [
            "Content-Type": "application/json",
            "Content-Length": "128",
            "Connection": "X-Origin-Hop, keep-alive",
            "X-Origin-Hop": "remove-me",
            "Transfer-Encoding": "Identity",
            "Keep-Alive": "timeout=5",
            "TE": "trailers",
            "Trailer": "Expires",
            "Upgrade": "websocket",
            "Proxy-Authenticate": "Basic",
            "Proxy-Authorization": "Basic token",
            "X-App": "ok"
        ]

        let filtered = Dictionary(
            uniqueKeysWithValues: HTTPProxyHeaderFilter.responseHeaders(from: headers)
                .map { ($0.key.lowercased(), $0.value) }
        )

        XCTAssertEqual(filtered["content-type"], "application/json")
        XCTAssertEqual(filtered["x-app"], "ok")
        XCTAssertNil(filtered["content-length"])
        XCTAssertNil(filtered["connection"])
        XCTAssertNil(filtered["x-origin-hop"])
        XCTAssertNil(filtered["transfer-encoding"])
        XCTAssertNil(filtered["keep-alive"])
        XCTAssertNil(filtered["te"])
        XCTAssertNil(filtered["trailer"])
        XCTAssertNil(filtered["upgrade"])
        XCTAssertNil(filtered["proxy-authenticate"])
        XCTAssertNil(filtered["proxy-authorization"])
    }

    private func request(
        proxyPort: Int,
        host: String,
        path: String,
        headers: [String: String] = [:]
    ) async throws -> (statusCode: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(proxyPort)\(path)")!)
        request.setValue(host, forHTTPHeaderField: "Host")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
        return (statusCode, String(decoding: data, as: UTF8.self))
    }
}

private final class TestHTTPServer {
    let port: Int

    private let listener: NWListener
    private let queue = DispatchQueue(label: "routingflare.tests.http-server")
    private let body: String

    init(body: String) throws {
        self.body = body
        let parameters = NWParameters.tcp
        if let loopback = IPv4Address("127.0.0.1") {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: .any)
        }
        listener = try NWListener(using: parameters, on: .any)

        let ready = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [body] connection in
            connection.start(queue: DispatchQueue(label: "routingflare.tests.http-server.connection"))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                let responseBody = Data(body.utf8)
                var response = "HTTP/1.1 200 OK\r\n"
                response += "Content-Length: \(responseBody.count)\r\n"
                response += "Connection: close\r\n"
                response += "\r\n"
                var data = Data(response.utf8)
                data.append(responseBody)
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 2)
        port = Int(try XCTUnwrap(listener.port?.rawValue))
    }

    func stop() {
        listener.cancel()
    }
}
