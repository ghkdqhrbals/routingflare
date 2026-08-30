import Foundation

public enum ProxyAccessDecision: Equatable {
    case allowed(sourceIP: String?)
    case blocked(sourceIP: String?)
}

public struct ProxyAccessPolicy: @unchecked Sendable {
    private let entries: [String]
    private let allowlist: IPAllowlist?
    private let authHeader: ProxyAuthHeader

    public static let allowAll = ProxyAccessPolicy(allowlistEntries: [])

    public init(allowlistEntries: [String], authHeader: ProxyAuthHeader = .disabled) {
        self.entries = allowlistEntries
        self.allowlist = try? IPAllowlist(entries: allowlistEntries)
        self.authHeader = authHeader
    }

    public var isAllowAll: Bool {
        (try? IPAllowlist(entries: entries).isEmpty) ?? false
    }

    var proxyConfiguration: RouteSecurity {
        RouteSecurity(
            allowlistEntries: entries,
            authHeaderEnabled: authHeader.enabled,
            authHeaderName: authHeader.name,
            authHeaderSecret: authHeader.secret
        )
    }

    public func decision(for headers: [String: String]) -> ProxyAccessDecision {
        let names = headers.keys.map { $0.lowercased() }
        guard Set(names).count == names.count else {
            return .blocked(sourceIP: nil)
        }
        guard authHeader.allows(headers: headers) else {
            return .blocked(sourceIP: sourceIP(from: headers))
        }
        guard let allowlist else {
            return .blocked(sourceIP: sourceIP(from: headers))
        }
        let sourceIP = sourceIP(from: headers)
        guard !allowlist.isEmpty else {
            return .allowed(sourceIP: sourceIP)
        }
        guard let sourceIP, allowlist.allows(sourceIP) else {
            return .blocked(sourceIP: sourceIP)
        }
        return .allowed(sourceIP: sourceIP)
    }

    private func sourceIP(from headers: [String: String]) -> String? {
        let normalized = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })

        if let cfConnectingIP = normalized["cf-connecting-ip"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cfConnectingIP.isEmpty {
            return cfConnectingIP
        }

        if let forwarded = normalized["x-forwarded-for"] {
            return forwarded
                .split(separator: ",")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }
}

public struct RouteSecurity: Codable, Equatable, Hashable, Sendable {
    public var allowlistEntries: [String]
    public var authHeaderEnabled: Bool
    public var authHeaderName: String
    public var authHeaderSecret: String

    public init(
        allowlistEntries: [String] = [],
        authHeaderEnabled: Bool = false,
        authHeaderName: String = "X-Routingflare-Secret",
        authHeaderSecret: String = ""
    ) {
        self.allowlistEntries = allowlistEntries
        self.authHeaderEnabled = authHeaderEnabled
        self.authHeaderName = authHeaderName
        self.authHeaderSecret = authHeaderSecret
    }

    public var isEmpty: Bool {
        allowlistEntries.isEmpty && !authHeaderEnabled && authHeaderSecret.isEmpty
    }

    public var accessPolicy: ProxyAccessPolicy {
        ProxyAccessPolicy(
            allowlistEntries: allowlistEntries,
            authHeader: ProxyAuthHeader(
                enabled: authHeaderEnabled,
                name: authHeaderName,
                secret: authHeaderSecret
            )
        )
    }
}

public struct ProxyAuthHeader: Equatable, Sendable {
    public let enabled: Bool
    public let name: String
    public let secret: String

    public static let disabled = ProxyAuthHeader(enabled: false, name: "", secret: "")

    public init(enabled: Bool, name: String, secret: String) {
        self.enabled = enabled
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.secret = secret
    }

    public var isActive: Bool {
        enabled && !name.isEmpty && !secret.isEmpty
    }

    public func allows(headers: [String: String]) -> Bool {
        guard enabled else { return true }
        guard isActive else { return false }
        let normalizedName = name.lowercased()
        let matches = headers.filter { key, _ in
            key.lowercased() == normalizedName
        }
        return matches.count == 1 && matches.first?.value == secret
    }
}

public final class MutableProxyAccessPolicy {
    private let lock = NSLock()
    private var policy: ProxyAccessPolicy
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init(allowlistEntries: [String], authHeader: ProxyAuthHeader = .disabled) {
        self.policy = ProxyAccessPolicy(allowlistEntries: allowlistEntries, authHeader: authHeader)
    }

    public func update(allowlistEntries: [String], authHeader: ProxyAuthHeader = .disabled) {
        lock.lock()
        policy = ProxyAccessPolicy(allowlistEntries: allowlistEntries, authHeader: authHeader)
        let callbacks = Array(observers.values)
        lock.unlock()
        callbacks.forEach { $0() }
    }

    func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        observers[id] = callback
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }

    public func currentPolicy() -> ProxyAccessPolicy {
        lock.lock()
        let currentPolicy = policy
        lock.unlock()
        return currentPolicy
    }

    public func decision(for headers: [String: String]) -> ProxyAccessDecision {
        currentPolicy().decision(for: headers)
    }
}

extension MutableProxyAccessPolicy: @unchecked Sendable {}

public final class MutableRouteSecurityPolicies {
    private let lock = NSLock()
    private var policies: [LocalProxyRoute: RouteSecurity] = [:]
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init(routes: [LocalProxyRoute] = []) {
        update(routes: routes)
    }

    public func update(routes: [LocalProxyRoute]) {
        let nextPolicies: [LocalProxyRoute: RouteSecurity] = Dictionary(routes.compactMap { route -> (LocalProxyRoute, RouteSecurity)? in
            guard let security = route.security, !security.isEmpty else {
                return nil
            }
            return (route, security)
        }, uniquingKeysWith: { _, latest in latest })
        lock.lock()
        policies = nextPolicies
        let callbacks = Array(observers.values)
        lock.unlock()
        callbacks.forEach { $0() }
    }

    func observe(_ callback: @escaping @Sendable () -> Void) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        observers[id] = callback
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock()
        observers[id] = nil
        lock.unlock()
    }

    public func accessPolicy(for route: LocalProxyRoute, defaultPolicy: ProxyAccessPolicy) -> ProxyAccessPolicy {
        lock.lock()
        let security = policies[route]
        lock.unlock()
        guard let security else {
            return defaultPolicy
        }
        return security.accessPolicy
    }
}

extension MutableRouteSecurityPolicies: @unchecked Sendable {}
