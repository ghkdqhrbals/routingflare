import Foundation

public struct CLIInstallResult: Equatable {
    public let installedOrUpdatedLink: Bool
    public let addedPathToZshrc: Bool

    public init(installedOrUpdatedLink: Bool, addedPathToZshrc: Bool) {
        self.installedOrUpdatedLink = installedOrUpdatedLink
        self.addedPathToZshrc = addedPathToZshrc
    }
}

public struct CLIInstaller {
    private let fileManager: FileManager
    private let homeURL: URL
    private let cliName: String
    private let pathLine: String

    public init(
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        cliName: String = "routingflare",
        pathLine: String = #"export PATH="$HOME/.local/bin:$PATH""#
    ) {
        self.fileManager = fileManager
        self.homeURL = homeURL
        self.cliName = cliName
        self.pathLine = pathLine
    }

    public func install(bundledCLIURL: URL) throws -> CLIInstallResult {
        guard fileManager.isExecutableFile(atPath: bundledCLIURL.path) else {
            throw CLIInstallerError.missingBundledCLI(bundledCLIURL.path)
        }

        let binDirectoryURL = homeURL.appendingPathComponent(".local/bin", isDirectory: true)
        let cliLinkURL = binDirectoryURL.appendingPathComponent(cliName)
        try fileManager.createDirectory(at: binDirectoryURL, withIntermediateDirectories: true)

        let didInstallLink = try installSymlink(from: bundledCLIURL, to: cliLinkURL)
        let didAddPath = try ensureLocalBinPath(in: homeURL.appendingPathComponent(".zshrc"))
        return CLIInstallResult(installedOrUpdatedLink: didInstallLink, addedPathToZshrc: didAddPath)
    }

    private func installSymlink(from bundledCLIURL: URL, to cliLinkURL: URL) throws -> Bool {
        if let existingTarget = try? fileManager.destinationOfSymbolicLink(atPath: cliLinkURL.path) {
            if existingTarget == bundledCLIURL.path {
                return false
            }
            try fileManager.removeItem(at: cliLinkURL)
        } else if fileManager.fileExists(atPath: cliLinkURL.path) {
            try fileManager.removeItem(at: cliLinkURL)
        }

        try fileManager.createSymbolicLink(at: cliLinkURL, withDestinationURL: bundledCLIURL)
        return true
    }

    private func ensureLocalBinPath(in zshrcURL: URL) throws -> Bool {
        let existingContent: String
        if fileManager.fileExists(atPath: zshrcURL.path) {
            existingContent = try String(contentsOf: zshrcURL, encoding: .utf8)
        } else {
            existingContent = ""
        }

        guard !existingContent.contains(".local/bin") else {
            return false
        }

        let separator = existingContent.isEmpty || existingContent.hasSuffix("\n") ? "" : "\n"
        let updatedContent = existingContent + separator + pathLine + "\n"
        try updatedContent.write(to: zshrcURL, atomically: true, encoding: .utf8)
        return true
    }
}

public enum CLIInstallerError: Error, LocalizedError, Equatable {
    case missingBundledCLI(String)

    public var errorDescription: String? {
        switch self {
        case .missingBundledCLI(let path):
            return "Bundled CLI was not found at \(path)"
        }
    }
}
