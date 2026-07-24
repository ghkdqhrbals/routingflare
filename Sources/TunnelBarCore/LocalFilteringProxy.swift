import Foundation
@preconcurrency import Network

public enum LocalFilteringProxyError: Error, LocalizedError {
    case listenerNotReady
    case invalidRequest

    public var errorDescription: String? {
        switch self {
        case .listenerNotReady:
            return "Proxy listener did not start."
        case .invalidRequest:
            return "Invalid HTTP request."
        }
    }
}

public final class LocalFilteringProxy {
    private let targetPort: Int
    private let routes: [LocalProxyRoute]
    private let accessPolicy: MutableProxyAccessPolicy
    private let routeSecurityPolicies: MutableRouteSecurityPolicies
    private let forwardingSession: URLSession
    private let queue = DispatchQueue(label: "TunnelBar.LocalFilteringProxy")
    private let logHandler: @Sendable (String) -> Void
    private var listener: NWListener?

    public private(set) var port: Int?

    public init(
        targetPort: Int,
        accessPolicy: MutableProxyAccessPolicy,
        routeSecurityPolicies: MutableRouteSecurityPolicies = MutableRouteSecurityPolicies(),
        logHandler: @escaping @Sendable (String) -> Void
    ) {
        self.targetPort = targetPort
        self.routes = []
        self.accessPolicy = accessPolicy
        self.routeSecurityPolicies = routeSecurityPolicies
        self.forwardingSession = Self.makeForwardingSession()
        self.logHandler = logHandler
    }

    public init(
        routes: [LocalProxyRoute],
        fallbackTargetPort: Int,
        accessPolicy: MutableProxyAccessPolicy,
        routeSecurityPolicies: MutableRouteSecurityPolicies = MutableRouteSecurityPolicies(),
        logHandler: @escaping @Sendable (String) -> Void
    ) {
        self.targetPort = fallbackTargetPort
        self.routes = routes
        self.accessPolicy = accessPolicy
        self.routeSecurityPolicies = routeSecurityPolicies
        self.forwardingSession = Self.makeForwardingSession()
        self.logHandler = logHandler
    }

    deinit {
        forwardingSession.invalidateAndCancel()
        stop()
    }

    private static func makeForwardingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(
            configuration: configuration,
            delegate: RedirectPreservingSessionDelegate(),
            delegateQueue: nil
        )
    }

    public func start() throws -> Int {
        let parameters = NWParameters.tcp
        if let loopback = IPv4Address("127.0.0.1") {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: .any)
        }
        let listener = try NWListener(using: parameters, on: .any)
        let readySemaphore = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                readySemaphore.signal()
            }
        }
        listener.start(queue: queue)
        self.listener = listener

        _ = readySemaphore.wait(timeout: .now() + 2)
        for _ in 0..<200 {
            if let assignedPort = listener.port?.rawValue, assignedPort > 0 {
                self.port = Int(assignedPort)
                let targetDescription = routes.isEmpty ? "127.0.0.1:\(targetPort)" : "\(routes.count) routes"
                logHandler("Proxy listening on 127.0.0.1:\(assignedPort), forwarding to \(targetDescription)")
                return Int(assignedPort)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw LocalFilteringProxyError.listenerNotReady
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }
            if let error {
                self.logHandler("Proxy read failed: \(error.localizedDescription)")
                connection.cancel()
                return
            }
            guard let data, let request = HTTPProxyRequest(data: data) else {
                self.send(status: 400, body: "Bad Request", to: connection)
                return
            }
            self.forward(request, connection: connection)
        }
    }

    private func forward(_ request: HTTPProxyRequest, connection: NWConnection) {
        guard let targetRoute = route(for: request) else {
            send(status: 404, body: "Not Found", to: connection)
            return
        }

        let decision = routeSecurityPolicies
            .accessPolicy(for: targetRoute, defaultPolicy: accessPolicy.currentPolicy())
            .decision(for: request.headers)
        guard case .allowed(let sourceIP) = decision else {
            let blockedIP: String
            if case .blocked(let ip) = decision {
                blockedIP = ip ?? "unknown"
            } else {
                blockedIP = "unknown"
            }
            logHandler("Blocked request from \(blockedIP) to :\(targetRoute.targetPort)\(request.path)")
            send(status: 403, body: "Forbidden", to: connection)
            return
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = targetRoute.targetPort
        components.percentEncodedPath = request.path.isEmpty ? "/" : request.path
        components.percentEncodedQuery = request.query

        guard let url = components.url else {
            send(status: 400, body: "Bad Request", to: connection)
            return
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (key, value) in HTTPProxyHeaderFilter.requestHeaders(from: request.headers) {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = request.body.isEmpty ? nil : request.body

        Task {
            do {
                let (data, response) = try await forwardingSession.data(for: urlRequest)
                let httpResponse = response as? HTTPURLResponse
                let statusCode = httpResponse?.statusCode ?? 200
                let headerFields = httpResponse?.allHeaderFields ?? [:]
                self.send(status: statusCode, headers: headerFields, bodyData: data, to: connection)
                self.logHandler("Allowed request from \(sourceIP ?? "unknown") to :\(targetRoute.targetPort)\(request.path)")
            } catch {
                self.logHandler("Proxy forward failed: \(error.localizedDescription)")
                self.send(status: 502, body: "Bad Gateway", to: connection)
            }
        }
    }

    private func route(for request: HTTPProxyRequest) -> LocalProxyRoute? {
        guard !routes.isEmpty else {
            return LocalProxyRoute(hostname: "", targetPort: targetPort, targetPath: "/")
        }
        let host = request.headers.first { key, _ in
            key.caseInsensitiveCompare("host") == .orderedSame
        }?.value ?? ""
        return routes
            .filter { $0.matches(host: host, path: request.path) }
            .max { lhs, rhs in
                lhs.normalizedTargetPath.count < rhs.normalizedTargetPath.count
            }
    }

    private func send(status: Int, body: String, to connection: NWConnection) {
        send(status: status, headers: [:], bodyData: Data(body.utf8), to: connection)
    }

    private func send(status: Int, headers: [AnyHashable: Any], bodyData: Data, to connection: NWConnection) {
        var response = "HTTP/1.1 \(status) \(reasonPhrase(for: status))\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Connection: close\r\n"
        for (key, value) in HTTPProxyHeaderFilter.responseHeaders(from: headers) {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(bodyData)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 403:
            return "Forbidden"
        case 502:
            return "Bad Gateway"
        default:
            return "HTTP"
        }
    }
}

extension LocalFilteringProxy: @unchecked Sendable {}

private final class RedirectPreservingSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum HTTPProxyHeaderFilter {
    private static let excludedHeaders: Set<String> = [
        "host",
        "connection",
        "content-length",
        "transfer-encoding",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "upgrade"
    ]

    static func requestHeaders(from headers: [String: String]) -> [(key: String, value: String)] {
        filteredHeaders(from: headers.map { ($0.key, $0.value) })
    }

    static func responseHeaders(from headers: [AnyHashable: Any]) -> [(key: String, value: String)] {
        filteredHeaders(from: headers.compactMap { key, value in
            guard let headerName = key as? String else {
                return nil
            }
            return (headerName, String(describing: value))
        })
    }

    static func responseHeaders(from headers: [String: String]) -> [(key: String, value: String)] {
        filteredHeaders(from: headers.map { ($0.key, $0.value) })
    }

    private static func filteredHeaders(from headers: [(key: String, value: String)]) -> [(key: String, value: String)] {
        let connectionHeaderTokens = headers.flatMap { key, value -> [String] in
            guard key.caseInsensitiveCompare("connection") == .orderedSame else {
                return []
            }
            return value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }
        let excludedHeaders = Self.excludedHeaders.union(connectionHeaderTokens)

        return headers.filter { key, _ in
            !excludedHeaders.contains(key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
    }
}

public struct LocalProxyRoute: Codable, Equatable, Hashable, Sendable {
    public var hostname: String
    public var targetPort: Int
    public var targetPath: String
    public var security: RouteSecurity?
    public var isOpen: Bool

    enum CodingKeys: String, CodingKey {
        case hostname
        case targetPort
        case targetPath
        case security
        case isOpen
    }

    public init(hostname: String, targetPort: Int, targetPath: String, security: RouteSecurity? = nil, isOpen: Bool = true) {
        self.hostname = hostname
        self.targetPort = targetPort
        self.targetPath = targetPath
        self.security = security
        self.isOpen = isOpen
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hostname = try container.decode(String.self, forKey: .hostname)
        self.targetPort = try container.decode(Int.self, forKey: .targetPort)
        self.targetPath = try container.decode(String.self, forKey: .targetPath)
        self.security = try container.decodeIfPresent(RouteSecurity.self, forKey: .security)
        self.isOpen = try container.decodeIfPresent(Bool.self, forKey: .isOpen) ?? true
    }

    public var normalizedTargetPath: String {
        targetPath.isEmpty ? "/" : (targetPath.hasPrefix("/") ? targetPath : "/" + targetPath)
    }

    public func accessPolicy(defaultPolicy: ProxyAccessPolicy) -> ProxyAccessPolicy {
        guard let security, !security.isEmpty else {
            return defaultPolicy
        }
        return security.accessPolicy
    }

    public func matches(host: String, path: String) -> Bool {
        let candidateHost = host.split(separator: ":").first.map(String.init) ?? host
        guard hostname.isEmpty || candidateHost.caseInsensitiveCompare(hostname) == .orderedSame else {
            return false
        }
        let normalizedPath = normalizedTargetPath
        if normalizedPath == "/" {
            return true
        }
        return path == normalizedPath || path.hasPrefix(normalizedPath + "/")
    }

    public static func == (lhs: LocalProxyRoute, rhs: LocalProxyRoute) -> Bool {
        lhs.hostname == rhs.hostname &&
        lhs.targetPort == rhs.targetPort &&
        lhs.normalizedTargetPath == rhs.normalizedTargetPath
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hostname)
        hasher.combine(targetPort)
        hasher.combine(normalizedTargetPath)
    }
}

struct HTTPProxyRequest {
    let method: String
    let path: String
    let query: String?
    let headers: [String: String]
    let body: Data

    init?(data: Data) {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            return nil
        }

        self.method = requestParts[0]
        let rawTarget = requestParts[1]
        let targetComponents = URLComponents(string: rawTarget)
        self.path = targetComponents?.percentEncodedPath.isEmpty == false ? targetComponents?.percentEncodedPath ?? "/" : rawTarget
        self.query = targetComponents?.percentEncodedQuery

        var parsedHeaders: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            parsedHeaders[key] = value
        }
        self.headers = parsedHeaders
        self.body = data[separator.upperBound...]
    }
}
