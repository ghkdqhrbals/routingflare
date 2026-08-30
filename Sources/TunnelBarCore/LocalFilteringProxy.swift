import Foundation

public enum LocalFilteringProxyError: Error, LocalizedError {
    case listenerNotReady
    case invalidRequest
    case helperUnavailable
    case helperFailed(String)

    public var errorDescription: String? {
        switch self {
        case .listenerNotReady: return "Proxy listener did not start."
        case .invalidRequest: return "Invalid HTTP request."
        case .helperUnavailable: return "The bundled routingflare proxy is missing. Reinstall routingflare."
        case .helperFailed(let message): return message
        }
    }
}

// HTTP framing and streaming belong to the bundled Go reverse proxy, not URLSession.
public final class LocalFilteringProxy: @unchecked Sendable {
    private let targetPort: Int
    private let routes: [LocalProxyRoute]
    private let accessPolicy: MutableProxyAccessPolicy
    private let routeSecurityPolicies: MutableRouteSecurityPolicies
    private let logHandler: @Sendable (String) -> Void
    private let failureHandler: @Sendable (String) -> Void
    private let lock = NSRecursiveLock()
    private var helper: ProxyHelperProcess?
    private var accessObserver: UUID?
    private var securityObserver: UUID?
    private var assignedPort: Int?

    public var port: Int? {
        lock.lock()
        defer { lock.unlock() }
        return assignedPort
    }

    public convenience init(
        targetPort: Int,
        accessPolicy: MutableProxyAccessPolicy,
        routeSecurityPolicies: MutableRouteSecurityPolicies = MutableRouteSecurityPolicies(),
        logHandler: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(routes: [], fallbackTargetPort: targetPort, accessPolicy: accessPolicy,
                  routeSecurityPolicies: routeSecurityPolicies, logHandler: logHandler, onFailure: onFailure)
    }

    public init(
        routes: [LocalProxyRoute],
        fallbackTargetPort: Int,
        accessPolicy: MutableProxyAccessPolicy,
        routeSecurityPolicies: MutableRouteSecurityPolicies = MutableRouteSecurityPolicies(),
        logHandler: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.routes = routes
        self.targetPort = fallbackTargetPort
        self.accessPolicy = accessPolicy
        self.routeSecurityPolicies = routeSecurityPolicies
        self.logHandler = logHandler
        self.failureHandler = onFailure
    }

    deinit { stop() }

    public func start() throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let assignedPort { return assignedPort }
        let instanceID = UUID()
        let next = try ProxyHelperProcess(id: instanceID, logHandler: logHandler) { [weak self] message in
            self?.failed(instanceID: instanceID, message: message)
        }
        helper = next
        accessObserver = accessPolicy.observe { [weak self] in self?.updatePolicies() }
        securityObserver = routeSecurityPolicies.observe { [weak self] in self?.updatePolicies() }
        do {
            let port = try next.start(configuration())
            assignedPort = port
            let description = routes.isEmpty ? "127.0.0.1:\(targetPort)" : "\(routes.count) routes"
            logHandler("Proxy listening on 127.0.0.1:\(port), forwarding to \(description)")
            return port
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let accessObserver { accessPolicy.removeObserver(accessObserver) }
        if let securityObserver { routeSecurityPolicies.removeObserver(securityObserver) }
        accessObserver = nil
        securityObserver = nil
        let previous = helper
        helper = nil
        assignedPort = nil
        previous?.stop()
    }

    private func configuration() -> ProxyHelperConfiguration {
        let defaults = accessPolicy.currentPolicy()
        let currentRoutes = routes.map { route in
            var configured = route
            configured.security = routeSecurityPolicies.accessPolicy(for: route, defaultPolicy: defaults).proxyConfiguration
            return configured
        }
        return ProxyHelperConfiguration(routes: currentRoutes, fallbackTargetPort: targetPort, defaultPolicy: defaults.proxyConfiguration)
    }

    private func updatePolicies() {
        lock.lock()
        defer { lock.unlock() }
        guard let helper else { return }
        do { try helper.apply(configuration()) }
        catch { failed(instanceID: helper.id, message: "Proxy security update failed: \(error.localizedDescription)") }
    }

    private func failed(instanceID: UUID, message: String) {
        lock.lock()
        guard helper?.id == instanceID else { lock.unlock(); return }
        stop() // Fail closed if policy synchronization or the proxy process fails.
        lock.unlock()
        logHandler(message)
        failureHandler(message)
    }
}
