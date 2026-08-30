import Foundation

public struct LocalProxyRoute: Codable, Equatable, Hashable, Sendable {
    public var hostname: String
    public var targetPort: Int
    public var targetPath: String
    public var security: RouteSecurity?
    public var isOpen: Bool

    enum CodingKeys: String, CodingKey {
        case hostname, targetPort, targetPath, security, isOpen
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
        guard let security, !security.isEmpty else { return defaultPolicy }
        return security.accessPolicy
    }

    public func matches(host: String, path: String) -> Bool {
        let candidateHost = host.split(separator: ":").first.map(String.init) ?? host
        guard hostname.isEmpty || candidateHost.caseInsensitiveCompare(hostname) == .orderedSame else { return false }
        let normalizedPath = normalizedTargetPath
        return normalizedPath == "/" || path == normalizedPath || path.hasPrefix(normalizedPath + "/")
    }

    public static func == (lhs: LocalProxyRoute, rhs: LocalProxyRoute) -> Bool {
        lhs.hostname == rhs.hostname && lhs.targetPort == rhs.targetPort && lhs.normalizedTargetPath == rhs.normalizedTargetPath
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(hostname)
        hasher.combine(targetPort)
        hasher.combine(normalizedTargetPath)
    }
}
