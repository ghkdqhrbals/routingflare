import Foundation

public enum CloudflaredTunnelInfoParser {
    public static func parseName(from output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.uppercased().hasPrefix("NAME:") else {
                continue
            }
            let name = trimmed.dropFirst("NAME:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }
        return nil
    }
}
