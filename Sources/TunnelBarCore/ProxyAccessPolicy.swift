import Foundation

public enum ProxyAccessDecision: Equatable {
    case allowed(sourceIP: String?)
    case blocked(sourceIP: String?)
}

public struct ProxyAccessPolicy {
    private let entries: [String]
    private let allowlist: IPAllowlist?
    private let authHeader: ProxyAuthHeader

    public init(allowlistEntries: [String], authHeader: ProxyAuthHeader = .disabled) {
        self.entries = allowlistEntries
        self.allowlist = try? IPAllowlist(entries: allowlistEntries)
        self.authHeader = authHeader
    }

    public var isAllowAll: Bool {
        (try? IPAllowlist(entries: entries).isEmpty) ?? true
    }

    public func decision(for headers: [String: String]) -> ProxyAccessDecision {
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
        let normalized = Dictionary(uniqueKeysWithValues: headers.map { key, value in
            (key.lowercased(), value)
        })

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
        guard isActive else { return true }
        let normalizedName = name.lowercased()
        let value = headers.first { key, _ in
            key.lowercased() == normalizedName
        }?.value
        return value == secret
    }
}

public final class MutableProxyAccessPolicy {
    private let lock = NSLock()
    private var policy: ProxyAccessPolicy

    public init(allowlistEntries: [String], authHeader: ProxyAuthHeader = .disabled) {
        self.policy = ProxyAccessPolicy(allowlistEntries: allowlistEntries, authHeader: authHeader)
    }

    public func update(allowlistEntries: [String], authHeader: ProxyAuthHeader = .disabled) {
        lock.lock()
        policy = ProxyAccessPolicy(allowlistEntries: allowlistEntries, authHeader: authHeader)
        lock.unlock()
    }

    public func decision(for headers: [String: String]) -> ProxyAccessDecision {
        lock.lock()
        let currentPolicy = policy
        lock.unlock()
        return currentPolicy.decision(for: headers)
    }
}

extension MutableProxyAccessPolicy: @unchecked Sendable {}
