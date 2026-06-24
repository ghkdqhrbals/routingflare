import Foundation

public struct CloudflaredLocator {
    public let fileManager: FileManager
    public let environmentPath: String
    public let homeDirectory: URL

    public init(
        fileManager: FileManager = .default,
        environmentPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.environmentPath = environmentPath
        self.homeDirectory = homeDirectory
    }

    public func find(configuredPath: String = "") -> String? {
        if isExecutable(configuredPath) {
            return configuredPath
        }

        let appManaged = homeDirectory
            .appendingPathComponent("Library/Application Support/TunnelBar/bin/cloudflared")
            .path
        if isExecutable(appManaged) {
            return appManaged
        }

        let candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/usr/bin/cloudflared"
        ] + environmentPath
            .split(separator: ":")
            .map { String($0) + "/cloudflared" }

        return candidates.first(where: isExecutable)
    }

    public func brewInstallCommand() -> TunnelCommand? {
        let brewCandidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        guard let brew = brewCandidates.first(where: isExecutable) else {
            return nil
        }
        return TunnelCommand(executable: brew, arguments: ["install", "cloudflared"])
    }

    private func isExecutable(_ path: String) -> Bool {
        guard !path.isEmpty else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }
}
