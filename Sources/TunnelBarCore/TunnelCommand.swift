import Foundation

public struct TunnelCommand: Equatable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum TunnelCommandBuilder {
    public static func quickURL(cloudflaredPath: String, proxyPort: Int) -> TunnelCommand {
        TunnelCommand(
            executable: cloudflaredPath,
            arguments: [
                "tunnel",
                "--url",
                "http://127.0.0.1:\(proxyPort)"
            ]
        )
    }

    public static func dns(cloudflaredPath: String, token: String) -> TunnelCommand {
        TunnelCommand(
            executable: cloudflaredPath,
            arguments: [
                "tunnel",
                "--no-autoupdate",
                "run",
                "--token",
                token
            ]
        )
    }

    public static func dnsLocalConfig(cloudflaredPath: String, configPath: String) -> TunnelCommand {
        TunnelCommand(
            executable: cloudflaredPath,
            arguments: [
                "tunnel",
                "--config",
                configPath,
                "run"
            ]
        )
    }
}

public enum TunnelURLParser {
    private static let pattern = #"https://[A-Za-z0-9.-]+\.trycloudflare\.com"#

    public static func parsePublicURL(from output: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              let urlRange = Range(match.range, in: output) else {
            return nil
        }
        return URL(string: String(output[urlRange]))
    }
}
