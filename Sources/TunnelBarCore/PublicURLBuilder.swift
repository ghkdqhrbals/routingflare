import Foundation

public enum PublicURLBuilder {
    public static func build(baseURL: URL, targetPath: String) -> URL? {
        let trimmedPath = targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return baseURL
        }

        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let normalizedPath = trimmedPath.hasPrefix("/") ? trimmedPath : "/" + trimmedPath
        if let questionMark = normalizedPath.firstIndex(of: "?") {
            components.path = String(normalizedPath[..<questionMark])
            components.query = String(normalizedPath[normalizedPath.index(after: questionMark)...])
        } else {
            components.path = normalizedPath
            components.query = nil
        }

        return components.url
    }

    public static func buildAll(hostnames: [String], targetPaths: [String]) -> [URL] {
        let cleanedHosts = hostnames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanedPaths = targetPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let paths = cleanedPaths.isEmpty ? ["/"] : cleanedPaths

        return cleanedHosts.flatMap { hostname in
            paths.compactMap { path in
                guard let baseURL = URL(string: "https://\(hostname)") else {
                    return nil
                }
                return build(baseURL: baseURL, targetPath: path)
            }
        }
    }
}
