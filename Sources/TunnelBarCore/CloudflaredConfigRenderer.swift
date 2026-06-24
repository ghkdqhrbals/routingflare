import Foundation

public enum CloudflaredConfigRenderer {
    public static func renderNamedTunnelConfig(
        tunnelID: String,
        credentialsFile: String,
        hostname: String,
        proxyPort: Int
    ) -> String {
        renderNamedTunnelConfig(
            tunnelID: tunnelID,
            credentialsFile: credentialsFile,
            hostnames: [hostname],
            proxyPort: proxyPort
        )
    }

    public static func renderNamedTunnelConfig(
        tunnelID: String,
        credentialsFile: String,
        hostnames: [String],
        proxyPort: Int
    ) -> String {
        let ingress = hostnames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map {
                """
                  - hostname: \($0)
                    service: http://127.0.0.1:\(proxyPort)
                """
            }
            .joined(separator: "\n")

        return """
        tunnel: \(tunnelID)
        credentials-file: \(credentialsFile)

        ingress:
        \(ingress)
          - service: http_status:404
        """
    }
}
