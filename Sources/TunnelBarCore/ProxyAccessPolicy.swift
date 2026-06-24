import Foundation

public enum ProxyAccessDecision: Equatable {
    case allowed(sourceIP: String?)
    case blocked(sourceIP: String?)
}

public struct ProxyAccessPolicy {
    private let entries: [String]
    private let allowlist: IPAllowlist?

    public init(allowlistEntries: [String]) {
        self.entries = allowlistEntries
        self.allowlist = try? IPAllowlist(entries: allowlistEntries)
    }

    public var isAllowAll: Bool {
        (try? IPAllowlist(entries: entries).isEmpty) ?? true
    }

    public func decision(for headers: [String: String]) -> ProxyAccessDecision {
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

public final class MutableProxyAccessPolicy {
    private let lock = NSLock()
    private var policy: ProxyAccessPolicy

    public init(allowlistEntries: [String]) {
        self.policy = ProxyAccessPolicy(allowlistEntries: allowlistEntries)
    }

    public func update(allowlistEntries: [String]) {
        lock.lock()
        policy = ProxyAccessPolicy(allowlistEntries: allowlistEntries)
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
