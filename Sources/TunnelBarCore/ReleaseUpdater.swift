import Foundation

public struct GitHubRelease: Decodable, Equatable {
    public let tagName: String
    public let htmlURL: URL?
    public let assets: [GitHubReleaseAsset]

    public init(tagName: String, htmlURL: URL?, assets: [GitHubReleaseAsset]) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.assets = assets
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

public struct GitHubReleaseAsset: Decodable, Equatable {
    public let name: String
    public let browserDownloadURL: URL

    public init(name: String, browserDownloadURL: URL) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
    }

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

public enum VersionComparator {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }
}

public struct ReleaseUpdatePlan: Equatable {
    public let latestVersion: String
    public let currentVersion: String
    public let dmgURL: URL?
    public let releaseURL: URL?

    public init(latestVersion: String, currentVersion: String, dmgURL: URL?, releaseURL: URL?) {
        self.latestVersion = latestVersion
        self.currentVersion = currentVersion
        self.dmgURL = dmgURL
        self.releaseURL = releaseURL
    }

    public var isNewer: Bool {
        VersionComparator.compare(latestVersion, currentVersion) == .orderedDescending
    }
}

public enum ReleasePlanner {
    public static func plan(from release: GitHubRelease, currentVersion: String) -> ReleaseUpdatePlan {
        let latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let dmgURL = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadURL
        return ReleaseUpdatePlan(
            latestVersion: latestVersion,
            currentVersion: currentVersion,
            dmgURL: dmgURL,
            releaseURL: release.htmlURL
        )
    }
}
