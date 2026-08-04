import Foundation

public enum CloudflaredTunnelInfoParser {
    public static func parseName(from output: String) -> String? {
        if let data = output.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let payload = object as? [String: Any],
           let name = payload["name"] as? String {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

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
