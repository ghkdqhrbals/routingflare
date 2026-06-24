import Foundation

public enum TunnelMode: String, CaseIterable, Codable, Identifiable {
    case quickURL
    case dns

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .quickURL:
            return "Quick URL"
        case .dns:
            return "DNS"
        }
    }
}

public struct AppSettings: Codable, Equatable {
    public var targetPort: Int
    public var recentPorts: [Int]
    public var mode: TunnelMode
    public var dnsHostname: String
    public var dnsHostnames: [String]
    public var dnsTunnelID: String
    public var dnsCredentialsFile: String
    public var targetPath: String
    public var targetPaths: [String]
    public var quickRoutes: [LocalProxyRoute]
    public var dnsTargetPort: Int
    public var dnsTargetPath: String
    public var dnsTargetPaths: [String]
    public var dnsRoutes: [LocalProxyRoute]
    public var cloudflaredPath: String
    public var allowlistEntries: [String]
    public var authHeaderEnabled: Bool
    public var authHeaderName: String

    public init(
        targetPort: Int = 3000,
        recentPorts: [Int] = [3000, 5173, 8000],
        mode: TunnelMode = .quickURL,
        dnsHostname: String = "",
        dnsHostnames: [String] = [],
        dnsTunnelID: String = "",
        dnsCredentialsFile: String = "",
        targetPath: String = "/",
        targetPaths: [String] = ["/"],
        quickRoutes: [LocalProxyRoute] = [],
        dnsTargetPort: Int = 3000,
        dnsTargetPath: String = "/",
        dnsTargetPaths: [String] = ["/"],
        dnsRoutes: [LocalProxyRoute] = [],
        cloudflaredPath: String = "",
        allowlistEntries: [String] = [],
        authHeaderEnabled: Bool = false,
        authHeaderName: String = "X-Routingflare-Secret"
    ) {
        self.targetPort = targetPort
        self.recentPorts = recentPorts
        self.mode = mode
        self.dnsHostname = dnsHostname
        self.dnsHostnames = dnsHostnames
        self.dnsTunnelID = dnsTunnelID
        self.dnsCredentialsFile = dnsCredentialsFile
        self.targetPath = targetPath
        self.targetPaths = targetPaths
        self.quickRoutes = quickRoutes
        self.dnsTargetPort = dnsTargetPort
        self.dnsTargetPath = dnsTargetPath
        self.dnsTargetPaths = dnsTargetPaths
        self.dnsRoutes = dnsRoutes
        self.cloudflaredPath = cloudflaredPath
        self.allowlistEntries = allowlistEntries
        self.authHeaderEnabled = authHeaderEnabled
        self.authHeaderName = authHeaderName
    }

    enum CodingKeys: String, CodingKey {
        case targetPort
        case recentPorts
        case mode
        case dnsHostname
        case dnsHostnames
        case dnsTunnelID
        case dnsCredentialsFile
        case targetPath
        case targetPaths
        case quickRoutes
        case dnsTargetPort
        case dnsTargetPath
        case dnsTargetPaths
        case dnsRoutes
        case cloudflaredPath
        case allowlistEntries
        case authHeaderEnabled
        case authHeaderName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.targetPort = try container.decodeIfPresent(Int.self, forKey: .targetPort) ?? 3000
        self.recentPorts = try container.decodeIfPresent([Int].self, forKey: .recentPorts) ?? [3000, 5173, 8000]
        self.mode = try container.decodeIfPresent(TunnelMode.self, forKey: .mode) ?? .quickURL
        self.dnsHostname = try container.decodeIfPresent(String.self, forKey: .dnsHostname) ?? ""
        let decodedDNSHostnames = try container.decodeIfPresent([String].self, forKey: .dnsHostnames) ?? []
        self.dnsHostnames = decodedDNSHostnames.isEmpty && !self.dnsHostname.isEmpty ? [self.dnsHostname] : decodedDNSHostnames
        self.dnsTunnelID = try container.decodeIfPresent(String.self, forKey: .dnsTunnelID) ?? ""
        self.dnsCredentialsFile = try container.decodeIfPresent(String.self, forKey: .dnsCredentialsFile) ?? ""
        self.targetPath = try container.decodeIfPresent(String.self, forKey: .targetPath) ?? "/"
        let decodedTargetPaths = try container.decodeIfPresent([String].self, forKey: .targetPaths) ?? []
        self.targetPaths = decodedTargetPaths.isEmpty ? [self.targetPath] : decodedTargetPaths
        let decodedQuickRoutes = try container.decodeIfPresent([LocalProxyRoute].self, forKey: .quickRoutes) ?? []
        if decodedQuickRoutes.isEmpty {
            let targetPaths = self.targetPaths
            let targetPort = self.targetPort
            self.quickRoutes = targetPaths.map { LocalProxyRoute(hostname: "", targetPort: targetPort, targetPath: $0) }
        } else {
            self.quickRoutes = decodedQuickRoutes
        }
        self.dnsTargetPort = try container.decodeIfPresent(Int.self, forKey: .dnsTargetPort) ?? self.targetPort
        self.dnsTargetPath = try container.decodeIfPresent(String.self, forKey: .dnsTargetPath) ?? self.targetPath
        let decodedDNSTargetPaths = try container.decodeIfPresent([String].self, forKey: .dnsTargetPaths) ?? []
        self.dnsTargetPaths = decodedDNSTargetPaths.isEmpty ? self.targetPaths : decodedDNSTargetPaths
        let decodedDNSRoutes = try container.decodeIfPresent([LocalProxyRoute].self, forKey: .dnsRoutes) ?? []
        if decodedDNSRoutes.isEmpty {
            let hostnames = self.dnsHostnames
            let targetPaths = self.dnsTargetPaths
            let targetPort = self.dnsTargetPort
            self.dnsRoutes = hostnames.flatMap { hostname in
                targetPaths.map { path in
                    LocalProxyRoute(hostname: hostname, targetPort: targetPort, targetPath: path)
                }
            }
        } else {
            self.dnsRoutes = decodedDNSRoutes
        }
        self.cloudflaredPath = try container.decodeIfPresent(String.self, forKey: .cloudflaredPath) ?? ""
        self.allowlistEntries = try container.decodeIfPresent([String].self, forKey: .allowlistEntries) ?? []
        self.authHeaderEnabled = try container.decodeIfPresent(Bool.self, forKey: .authHeaderEnabled) ?? false
        self.authHeaderName = try container.decodeIfPresent(String.self, forKey: .authHeaderName) ?? "X-Routingflare-Secret"
    }
}

public protocol SettingsStoring {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

public final class UserDefaultsSettingsStore: SettingsStoring {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "TunnelBar.settings") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
