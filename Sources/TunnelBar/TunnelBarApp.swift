import AppKit
import SwiftUI
import TunnelBarCore

@main
struct TunnelBarApp: App {
    @StateObject private var model = TunnelBarViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
                .frame(width: 360)
        } label: {
            Image(systemName: model.status.systemImage)
        }
        .menuBarExtraStyle(.window)
    }
}

enum TunnelStatus: Equatable {
    case stopped
    case starting
    case running
    case blockedRequest
    case error(String)

    var label: String {
        switch self {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Opened"
        case .blockedRequest:
            return "Opened"
        case .error:
            return "Error"
        }
    }

    var systemImage: String {
        switch self {
        case .stopped:
            return "globe"
        case .starting:
            return "arrow.triangle.2.circlepath"
        case .running:
            return "globe"
        case .blockedRequest:
            return "globe"
        case .error:
            return "globe"
        }
    }

    var canStartTunnel: Bool {
        switch self {
        case .stopped, .error:
            return true
        case .starting, .running, .blockedRequest:
            return false
        }
    }

    var isStarted: Bool {
        switch self {
        case .starting, .running, .blockedRequest:
            return true
        case .stopped, .error:
            return false
        }
    }
}

private struct TunnelStartError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case quickURL
    case dns
    case security
    case logs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quickURL:
            return "Quick URL"
        case .dns:
            return "DNS"
        case .security:
            return "Security"
        case .logs:
            return "Logs"
        }
    }

    var tunnelMode: TunnelMode? {
        switch self {
        case .quickURL:
            return .quickURL
        case .dns:
            return .dns
        case .security, .logs:
            return nil
        }
    }
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case available(version: String)
    case current
    case failed(String)
    case downloading
    case downloaded

    var label: String {
        switch self {
        case .idle:
            return "Check for Updates"
        case .checking:
            return "Checking..."
        case .available(let version):
            return "Update \(version)"
        case .current:
            return "Up to date"
        case .failed:
            return "Check failed"
        case .downloading:
            return "Downloading..."
        case .downloaded:
            return "Downloaded"
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}

private final class QuickTunnelSession {
    let route: LocalProxyRoute
    let proxy: LocalFilteringProxy
    let process: TunnelProcess
    let configURL: URL?

    init(route: LocalProxyRoute, proxy: LocalFilteringProxy, process: TunnelProcess, configURL: URL? = nil) {
        self.route = route
        self.proxy = proxy
        self.process = process
        self.configURL = configURL
    }

    func stop() {
        process.stop()
        proxy.stop()
        if let configURL {
            try? FileManager.default.removeItem(at: configURL)
        }
    }
}

@MainActor
final class TunnelBarViewModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var selectedTab: AppTab
    @Published var status: TunnelStatus = .stopped
    @Published var publicURL: URL?
    @Published var quickPublicURLs: [LocalProxyRoute: URL] = [:]
    @Published var proxyPort: Int?
    @Published var requiresRestart = false
    @Published var logs: [String] = []
    @Published var newAllowlistEntry = ""
    @Published var newDNSHostname = ""
    @Published var newDNSPortText = "3000"
    @Published var newQuickPortText = "3000"
    @Published var newTargetPath = ""
    @Published var installInProgress = false
    @Published var automaticInstallAttempted = false
    @Published var authHeaderSecret = ""
    @Published var updateStatus: UpdateStatus = .idle
    @Published var latestUpdateURL: URL?
    @Published private var dnsCloudflaredIssue: String?

    private let settingsStore: SettingsStoring
    private let secretStore: SecretStoring
    private let tunnelProcess = TunnelProcess()
    private let accessPolicy: MutableProxyAccessPolicy
    private var proxy: LocalFilteringProxy?
    private var quickSessions: [QuickTunnelSession] = []
    private var cloudflaredConfigURL: URL?
    private var activeTunnelModes: Set<TunnelMode> = []
    private static let authHeaderSecretAccount = "routingflare.authHeaderSecret"
    private static let releaseAPIURL = URL(string: "https://api.github.com/repos/ghkdqhrbals/routingflare/releases/latest")!
    static let projectPageURL = URL(string: "https://ghkdqhrbals.github.io/routingflare/")!
    static let releasesURL = URL(string: "https://github.com/ghkdqhrbals/routingflare/releases/latest")!
    static let koFiURL = URL(string: "https://ko-fi.com/D8X421KF0U")!
    static let koFiImageURL = URL(string: "https://storage.ko-fi.com/cdn/kofi6.png?v=6")!

    init(
        settingsStore: SettingsStoring = UserDefaultsSettingsStore(),
        secretStore: SecretStoring = KeychainStore()
    ) {
        self.settingsStore = settingsStore
        self.secretStore = secretStore
        var loaded = settingsStore.load()
            if loaded.cloudflaredPath.isEmpty,
           let detected = CloudflaredLocator().find() {
            loaded.cloudflaredPath = detected
        }
        if loaded.targetPath.isEmpty {
            loaded.targetPath = "/"
        }
        if loaded.targetPaths.isEmpty {
            loaded.targetPaths = [loaded.targetPath]
        }
        if loaded.quickRoutes.isEmpty {
            loaded.quickRoutes = loaded.targetPaths.map {
                LocalProxyRoute(hostname: "", targetPort: loaded.targetPort, targetPath: $0)
            }
        }
        if loaded.dnsTargetPath.isEmpty {
            loaded.dnsTargetPath = loaded.targetPath
        }
        if loaded.dnsTargetPaths.isEmpty {
            loaded.dnsTargetPaths = loaded.targetPaths
        }
        if loaded.dnsHostnames.isEmpty && !loaded.dnsHostname.isEmpty {
            loaded.dnsHostnames = [loaded.dnsHostname]
        }
        if loaded.dnsRoutes.isEmpty {
            loaded.dnsRoutes = loaded.dnsHostnames.flatMap { hostname in
                loaded.dnsTargetPaths.map {
                    LocalProxyRoute(hostname: hostname, targetPort: loaded.dnsTargetPort, targetPath: $0)
                }
            }
        }
        self.newDNSPortText = String(loaded.dnsTargetPort)
        self.newQuickPortText = String(loaded.targetPort)
        self.selectedTab = loaded.mode == .quickURL ? .quickURL : .dns
        let loadedAuthHeaderSecret = secretStore.read(account: Self.authHeaderSecretAccount) ?? ""
        self.authHeaderSecret = loadedAuthHeaderSecret
        self.settings = loaded
        self.accessPolicy = MutableProxyAccessPolicy(
            allowlistEntries: loaded.allowlistEntries,
            authHeader: Self.authHeader(
                enabled: loaded.authHeaderEnabled,
                name: loaded.authHeaderName,
                secret: loadedAuthHeaderSecret
            )
        )
        autoInstallCloudflaredIfNeeded()
    }

    var canStart: Bool {
        hasCloudflared && (!activeQuickRoutes.isEmpty || canStartDNS)
    }

    var hasCloudflared: Bool {
        !effectiveCloudflaredPath.isEmpty
    }

    private var canStartDNS: Bool {
        !activeDNSRoutes.isEmpty &&
        !settings.dnsTunnelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !settings.dnsCredentialsFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var dnsUnavailableReason: String? {
        if let dnsCloudflaredIssue {
            return dnsCloudflaredIssue
        }
        guard !activeDNSRoutes.isEmpty else {
            return nil
        }
        let missing = dnsMissingSettings
        guard !missing.isEmpty else {
            return nil
        }
        return "Missing \(missing.joined(separator: " and "))"
    }

    private var dnsMissingSettings: [String] {
        var missing: [String] = []
        if settings.dnsTunnelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("tunnel ID")
        }
        if settings.dnsCredentialsFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("credentials file")
        }
        return missing
    }

    var canAddDNSRoute: Bool {
        parsedPort(newDNSPortText) != nil &&
        !newDNSHostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !settings.dnsTunnelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !settings.dnsCredentialsFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var allowlistSummary: String {
        settings.allowlistEntries.isEmpty ? "Allow all inbound IPs" : "\(settings.allowlistEntries.count) allowed entries"
    }

    var runningModes: Set<TunnelMode> {
        status.isStarted ? activeTunnelModes : []
    }

    func saveSettings() {
        normalizeLists()
        settingsStore.save(settings)
    }

    func selectTab(_ tab: AppTab) {
        selectedTab = tab
        if let mode = tab.tunnelMode {
            settings.mode = mode
        }
        settingsStore.save(settings)
    }

    func detectCloudflared() {
        if let detected = CloudflaredLocator().find(configuredPath: settings.cloudflaredPath) {
            settings.cloudflaredPath = detected
            appendLog("Detected cloudflared at \(detected)")
        } else {
            appendLog("cloudflared was not found. Install it before starting a tunnel.")
        }
        saveSettings()
    }

    func installCloudflaredWithBrew() {
        installCloudflaredWithBrew(automatic: false)
    }

    private func autoInstallCloudflaredIfNeeded() {
        guard !hasCloudflared, !automaticInstallAttempted else { return }
        guard CloudflaredLocator().brewInstallCommand() != nil else {
            appendLog("cloudflared was not found. Homebrew was not found for automatic install.")
            return
        }
        automaticInstallAttempted = true
        installCloudflaredWithBrew(automatic: true)
    }

    private func installCloudflaredWithBrew(automatic: Bool) {
        guard let command = CloudflaredLocator().brewInstallCommand() else {
            appendLog("Homebrew was not found. Install cloudflared manually from Cloudflare or with Homebrew.")
            return
        }
        installInProgress = true
        let prefix = automatic ? "Automatic install:" : "Running"
        appendLog("\(prefix) \(command.executable) \(command.arguments.joined(separator: " "))")

        Task { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                self?.installInProgress = false
                self?.appendLog(output.isEmpty ? "Homebrew install finished." : output)
                self?.detectCloudflared()
            } catch {
                self?.installInProgress = false
                self?.appendLog("Install failed: \(error.localizedDescription)")
            }
        }
    }

    func start() {
        saveSettings()
        publicURL = nil
        quickPublicURLs = [:]
        dnsCloudflaredIssue = nil
        requiresRestart = false
        status = .starting
        activeTunnelModes = []

        do {
            var startedAnyTunnel = false
            if !activeQuickRoutes.isEmpty {
                try startQuickTunnels()
                startedAnyTunnel = true
            }

            if canStartDNS {
                try startDNSTunnel()
                startedAnyTunnel = true
            } else if let dnsUnavailableReason {
                appendLog("DNS routes not started: \(dnsUnavailableReason)")
            }

            guard startedAnyTunnel else {
                if let dnsUnavailableReason {
                    throw TunnelStartError(message: "DNS routes not started: \(dnsUnavailableReason)")
                }
                throw LocalFilteringProxyError.listenerNotReady
            }

            status = .running
            if let firstURL = quickPublicURLs.values.first {
                publicURL = firstURL
            }
            addRecentPort(activeTargetPort)
        } catch {
            stop()
            status = .error(error.localizedDescription)
            appendLog("Start failed: \(error.localizedDescription)")
        }
    }

    private func startDNSTunnel() throws {
            dnsCloudflaredIssue = nil
            let proxy: LocalFilteringProxy
            let logHandler: @Sendable (String) -> Void = { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(line)
                }
            }
            proxy = LocalFilteringProxy(
                routes: activeDNSRoutes,
                fallbackTargetPort: settings.dnsTargetPort,
                accessPolicy: accessPolicy,
                logHandler: logHandler
            )
            let proxyPort = try proxy.start()
            self.proxyPort = proxyPort
            self.proxy = proxy

            let configURL = try writeDNSConfig(proxyPort: proxyPort)
            let command = TunnelCommandBuilder.dnsLocalConfig(
                cloudflaredPath: effectiveCloudflaredPath,
                configPath: configURL.path
            )

            appendLog("Exposing DNS routes through proxy 127.0.0.1:\(String(proxyPort))")
            appendLog("Starting cloudflared: \(command.arguments.joined(separator: " "))")
            try tunnelProcess.start(
                command: command,
                onOutput: { [weak self] output in
                    Task { @MainActor in
                        self?.handleTunnelOutput(output)
                    }
                },
                onExit: { [weak self] statusCode in
                    Task { @MainActor in
                        self?.appendLog("cloudflared exited with status \(statusCode)")
                        self?.handleTunnelExit(mode: .dns, statusCode: statusCode)
                    }
                }
            )

    }

    private func startQuickTunnels() throws {
        let routes = activeQuickRoutes
        guard !routes.isEmpty else {
            throw LocalFilteringProxyError.listenerNotReady
        }

        for route in routes {
            try startQuickTunnel(route)
        }

        activeTunnelModes.insert(.quickURL)
    }

    private func startQuickTunnel(_ route: LocalProxyRoute) throws {
        guard !quickSessions.contains(where: { $0.route == route }) else { return }
        let proxy = LocalFilteringProxy(
            routes: [route],
            fallbackTargetPort: route.targetPort,
            accessPolicy: accessPolicy,
            logHandler: { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(line)
                }
            }
        )
        let proxyPort = try proxy.start()
        let command = TunnelCommandBuilder.quickURL(
            cloudflaredPath: effectiveCloudflaredPath,
            proxyPort: proxyPort
        )
        let process = TunnelProcess()
        let session = QuickTunnelSession(route: route, proxy: proxy, process: process)
        quickSessions.append(session)

        appendLog("Exposing quick route \(route.targetPath) -> 127.0.0.1:\(String(route.targetPort)) through proxy 127.0.0.1:\(String(proxyPort))")
        appendLog("Starting cloudflared: \(command.arguments.joined(separator: " "))")
        try process.start(
            command: command,
            onOutput: { [weak self, route] output in
                Task { @MainActor in
                    self?.handleQuickTunnelOutput(output, route: route)
                }
            },
            onExit: { [weak self, route] statusCode in
                Task { @MainActor in
                    self?.appendLog("quick route \(route.targetPath) cloudflared exited with status \(statusCode)")
                    self?.handleQuickTunnelExit(route: route, statusCode: statusCode)
                }
            }
        )
        activeTunnelModes.insert(.quickURL)
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        tunnelProcess.stop()
        proxy?.stop()
        proxy = nil
        for session in quickSessions {
            session.stop()
        }
        quickSessions = []
        quickPublicURLs = [:]
        proxyPort = nil
        if let cloudflaredConfigURL {
            try? FileManager.default.removeItem(at: cloudflaredConfigURL)
            self.cloudflaredConfigURL = nil
        }
        activeTunnelModes = []
        requiresRestart = false
        status = .stopped
        appendLog("Tunnel stopped")
    }

    func addAllowlistEntry() {
        let candidate = newAllowlistEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            return
        }
        do {
            _ = try IPAllowlist(entries: [candidate])
            if !settings.allowlistEntries.contains(candidate) {
                settings.allowlistEntries.append(candidate)
            }
            updateAccessPolicy()
            newAllowlistEntry = ""
            saveSettings()
        } catch {
            appendLog(error.localizedDescription)
        }
    }

    func removeAllowlistEntry(_ entry: String) {
        settings.allowlistEntries.removeAll { $0 == entry }
        updateAccessPolicy()
        saveSettings()
    }

    func saveAuthHeaderSettings() {
        settings.authHeaderName = normalizedAuthHeaderName
        if authHeaderSecret.isEmpty {
            try? secretStore.delete(account: Self.authHeaderSecretAccount)
        } else {
            do {
                try secretStore.write(authHeaderSecret, account: Self.authHeaderSecretAccount)
            } catch {
                appendLog("Auth header secret save failed: \(error.localizedDescription)")
            }
        }
        updateAccessPolicy()
        saveSettings()
    }

    func addDNSRoute() {
        let hostname = newDNSHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = newTargetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAddDNSRoute, let port = parsedPort(newDNSPortText), !hostname.isEmpty else { return }
        if path.isEmpty {
            path = "/"
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        let route = LocalProxyRoute(hostname: hostname, targetPort: port, targetPath: path)
        var didAdd = false
        if !settings.dnsRoutes.contains(route) {
            settings.dnsRoutes.insert(route, at: 0)
            didAdd = true
        }
        newDNSHostname = ""
        newTargetPath = ""
        saveSettings()
        if didAdd {
            refreshDNSTunnelIfNeeded()
        }
    }

    func addQuickRoute() {
        var path = newTargetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = parsedPort(newQuickPortText) else { return }
        if path.isEmpty {
            path = "/"
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        let route = LocalProxyRoute(hostname: "", targetPort: port, targetPath: path)
        var didAdd = false
        if !settings.quickRoutes.contains(route) {
            settings.quickRoutes.insert(route, at: 0)
            didAdd = true
        }
        newTargetPath = ""
        saveSettings()
        if didAdd {
            startQuickRouteIfNeeded(route)
        }
    }

    func removeQuickRoute(_ route: LocalProxyRoute) {
        let oldCount = settings.quickRoutes.count
        settings.quickRoutes.removeAll { $0 == route }
        saveSettings()
        if settings.quickRoutes.count != oldCount {
            stopQuickRouteSession(route)
        }
    }

    func removeDNSRoute(_ route: LocalProxyRoute) {
        let oldCount = settings.dnsRoutes.count
        settings.dnsRoutes.removeAll { $0 == route }
        saveSettings()
        if settings.dnsRoutes.count != oldCount {
            refreshDNSTunnelIfNeeded()
        }
    }

    func addTargetPath() {
        var candidate = newTargetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        if !candidate.hasPrefix("/") {
            candidate = "/" + candidate
        }
        switch settings.mode {
        case .quickURL:
            if !settings.targetPaths.contains(candidate) {
                settings.targetPaths.append(candidate)
            }
            settings.targetPath = settings.targetPaths.first ?? "/"
        case .dns:
            if !settings.dnsTargetPaths.contains(candidate) {
                settings.dnsTargetPaths.append(candidate)
            }
            settings.dnsTargetPath = settings.dnsTargetPaths.first ?? "/"
        }
        newTargetPath = ""
        saveSettings()
    }

    func removeTargetPath(_ path: String) {
        switch settings.mode {
        case .quickURL:
            settings.targetPaths.removeAll { $0 == path }
            if settings.targetPaths.isEmpty {
                settings.targetPaths = ["/"]
            }
            settings.targetPath = settings.targetPaths.first ?? "/"
        case .dns:
            settings.dnsTargetPaths.removeAll { $0 == path }
            if settings.dnsTargetPaths.isEmpty {
                settings.dnsTargetPaths = ["/"]
            }
            settings.dnsTargetPath = settings.dnsTargetPaths.first ?? "/"
        }
        saveSettings()
    }

    func copyPublicURL() {
        guard let publicURL else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicURL.absoluteString, forType: .string)
        appendLog("Copied \(publicURL.absoluteString)")
    }

    func openPublicURL() {
        guard let publicURL else {
            return
        }
        NSWorkspace.shared.open(publicURL)
    }

    func openProjectPage() {
        NSWorkspace.shared.open(Self.projectPageURL)
    }

    func openKoFiPage() {
        NSWorkspace.shared.open(Self.koFiURL)
    }

    func checkForUpdates() {
        guard updateStatus != .checking && updateStatus != .downloading else { return }
        updateStatus = .checking

        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: Self.releaseAPIURL)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
                await MainActor.run {
                    self?.applyLatestRelease(release)
                }
            } catch {
                await MainActor.run {
                    self?.updateStatus = .failed(error.localizedDescription)
                    self?.appendLog("Update check failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func installUpdate() {
        guard updateStatus != .downloading else { return }
        let url = latestUpdateURL ?? Self.releasesURL
        guard url.pathExtension.lowercased() == "dmg" else {
            NSWorkspace.shared.open(url)
            return
        }

        updateStatus = .downloading
        Task { [weak self] in
            do {
                let (temporaryURL, _) = try await URLSession.shared.download(from: url)
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ??
                    FileManager.default.homeDirectoryForCurrentUser
                let destination = downloads.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                await MainActor.run {
                    self?.updateStatus = .downloaded
                    NSWorkspace.shared.open(destination)
                }
            } catch {
                await MainActor.run {
                    self?.updateStatus = .failed(error.localizedDescription)
                    self?.appendLog("Update download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    private func applyLatestRelease(_ release: GitHubRelease) {
        let version = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        latestUpdateURL = release.assets.first { $0.name.lowercased().hasSuffix(".dmg") }?.browserDownloadURL ??
            release.htmlURL ??
            Self.releasesURL
        if Self.compareVersions(version, currentAppVersion) == .orderedDescending {
            updateStatus = .available(version: version)
        } else {
            updateStatus = .current
        }
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    private var effectiveCloudflaredPath: String {
        if !settings.cloudflaredPath.isEmpty {
            return settings.cloudflaredPath
        }
        return CloudflaredLocator().find() ?? ""
    }

    private func handleTunnelOutput(_ output: String) {
        appendLog(output)
        if let issue = cloudflaredIssue(from: output) {
            dnsCloudflaredIssue = issue
            activeTunnelModes.remove(.dns)
            if activeTunnelModes.subtracting([.dns]).isEmpty {
                status = .error(issue)
            }
            return
        }
        if let parsedURL = TunnelURLParser.parsePublicURL(from: output) {
            dnsCloudflaredIssue = nil
            publicURL = PublicURLBuilder.build(baseURL: parsedURL, targetPath: activeTargetPaths.first ?? "/")
            activeTunnelModes.insert(.dns)
            status = .running
        } else if status == .starting {
            activeTunnelModes.insert(.dns)
            status = .running
        }
    }

    private func handleQuickTunnelOutput(_ output: String, route: LocalProxyRoute) {
        appendLog(output)
        if let parsedURL = TunnelURLParser.parsePublicURL(from: output),
           let routedURL = PublicURLBuilder.build(baseURL: parsedURL, targetPath: route.targetPath) {
            quickPublicURLs[route] = routedURL
            publicURL = quickPublicURLs.values.first
            activeTunnelModes.insert(.quickURL)
            status = .running
        }
    }

    private func handleTunnelExit(mode: TunnelMode, statusCode: Int32) {
        guard status != .stopped else { return }
        activeTunnelModes.remove(mode)
        if statusCode != 0 {
            let issue = dnsCloudflaredIssue ?? "cloudflared exited with status \(statusCode)"
            dnsCloudflaredIssue = issue
            status = .error(issue)
            return
        }
        dnsCloudflaredIssue = nil
        if activeTunnelModes.isEmpty {
            status = .stopped
        }
    }

    private func handleQuickTunnelExit(route: LocalProxyRoute, statusCode: Int32) {
        guard status != .stopped else { return }
        if let index = quickSessions.firstIndex(where: { $0.route == route }) {
            let session = quickSessions.remove(at: index)
            session.proxy.stop()
            if let configURL = session.configURL {
                try? FileManager.default.removeItem(at: configURL)
            }
        }
        if quickSessions.isEmpty {
            activeTunnelModes.remove(.quickURL)
        }
        if statusCode != 0 {
            status = .error("cloudflared exited with status \(statusCode)")
            return
        }
        if activeTunnelModes.isEmpty {
            status = .stopped
        }
    }

    private func startQuickRouteIfNeeded(_ route: LocalProxyRoute) {
        guard status.isStarted else { return }
        do {
            try startQuickTunnel(normalizedRoute(route, wildcardHost: true))
            status = .running
        } catch {
            status = .error(error.localizedDescription)
            appendLog("Quick route start failed: \(error.localizedDescription)")
        }
    }

    private func stopQuickRouteSession(_ route: LocalProxyRoute) {
        let normalized = normalizedRoute(route, wildcardHost: true)
        quickPublicURLs[normalized] = nil
        if let index = quickSessions.firstIndex(where: { $0.route == normalized }) {
            let session = quickSessions.remove(at: index)
            session.stop()
        }
        if quickSessions.isEmpty {
            activeTunnelModes.remove(.quickURL)
        }
        publicURL = publicURLs.first
        if status.isStarted && activeTunnelModes.isEmpty {
            status = .stopped
        }
    }

    private func refreshDNSTunnelIfNeeded() {
        guard status.isStarted else { return }
        stopDNSTunnelOnly()
        guard canStartDNS else {
            if activeTunnelModes.isEmpty {
                status = .stopped
            }
            return
        }
        do {
            try startDNSTunnel()
            status = .running
            publicURL = quickPublicURLs.values.first
        } catch {
            status = .error(error.localizedDescription)
            appendLog("DNS tunnel refresh failed: \(error.localizedDescription)")
        }
    }

    private func stopDNSTunnelOnly() {
        tunnelProcess.stop()
        proxy?.stop()
        proxy = nil
        proxyPort = nil
        if let cloudflaredConfigURL {
            try? FileManager.default.removeItem(at: cloudflaredConfigURL)
            self.cloudflaredConfigURL = nil
        }
        activeTunnelModes.remove(.dns)
    }

    private var normalizedAuthHeaderName: String {
        let trimmed = settings.authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "X-Routingflare-Secret" : trimmed
    }

    private var currentAuthHeader: ProxyAuthHeader {
        Self.authHeader(
            enabled: settings.authHeaderEnabled,
            name: normalizedAuthHeaderName,
            secret: authHeaderSecret
        )
    }

    private static func authHeader(enabled: Bool, name: String, secret: String) -> ProxyAuthHeader {
        ProxyAuthHeader(enabled: enabled, name: name, secret: secret)
    }

    private func updateAccessPolicy() {
        accessPolicy.update(
            allowlistEntries: settings.allowlistEntries,
            authHeader: currentAuthHeader
        )
    }

    private func addRecentPort(_ port: Int) {
        settings.recentPorts.removeAll { $0 == port }
        settings.recentPorts.insert(port, at: 0)
        settings.recentPorts = Array(settings.recentPorts.prefix(6))
        saveSettings()
    }

    private func parsedPort(_ text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        guard let port = Int(digits), port > 0, port <= 65535 else {
            return nil
        }
        return port
    }

    private func writeDNSConfig(proxyPort: Int) throws -> URL {
        let configURL = try temporaryCloudflaredConfigURL()
        let config = CloudflaredConfigRenderer.renderNamedTunnelConfig(
            tunnelID: settings.dnsTunnelID.trimmingCharacters(in: .whitespacesAndNewlines),
            credentialsFile: settings.dnsCredentialsFile.trimmingCharacters(in: .whitespacesAndNewlines),
            hostnames: activeDNSHostnames,
            proxyPort: proxyPort
        )
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        cloudflaredConfigURL = configURL
        appendLog("Wrote DNS tunnel config for \(activeDNSHostnames.joined(separator: ", ")) -> 127.0.0.1:\(proxyPort)")
        return configURL
    }

    private func temporaryCloudflaredConfigURL() throws -> URL {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TunnelBar", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        return supportDirectory.appendingPathComponent("cloudflared-\(UUID().uuidString).yml")
    }

    var activeTargetPort: Int {
        switch settings.mode {
        case .quickURL:
            return activeQuickRoutes.first?.targetPort ?? settings.targetPort
        case .dns:
            return activeDNSRoutes.first?.targetPort ?? settings.dnsTargetPort
        }
    }

    var activeTargetPaths: [String] {
        let rawPaths: [String]
        let fallbackPath: String
        switch settings.mode {
        case .quickURL:
            rawPaths = activeQuickRoutes.map(\.targetPath)
            fallbackPath = settings.targetPath
        case .dns:
            rawPaths = activeDNSRoutes.map(\.targetPath)
            fallbackPath = settings.dnsTargetPath
        }

        let paths = rawPaths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paths.isEmpty ? [fallbackPath.isEmpty ? "/" : fallbackPath] : paths
    }

    var activeDNSHostnames: [String] {
        let routeHosts = activeDNSRoutes.map(\.hostname)
        if !routeHosts.isEmpty {
            return Array(NSOrderedSet(array: routeHosts).compactMap { $0 as? String })
        }
        let hostnames = settings.dnsHostnames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !hostnames.isEmpty {
            return hostnames
        }
        let legacy = settings.dnsHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        return legacy.isEmpty ? [] : [legacy]
    }

    var activeQuickRoutes: [LocalProxyRoute] {
        settings.quickRoutes
            .map { normalizedRoute($0, wildcardHost: true) }
            .filter { $0.targetPort > 0 && $0.targetPort <= 65535 }
    }

    var activeDNSRoutes: [LocalProxyRoute] {
        settings.dnsRoutes
            .map { normalizedRoute($0, wildcardHost: false) }
            .filter { !$0.hostname.isEmpty && $0.targetPort > 0 && $0.targetPort <= 65535 }
    }

    var publicURLs: [URL] {
        let quickURLs: [URL] = activeQuickRoutes.compactMap { quickPublicURLs[$0] }
        guard activeTunnelModes.contains(.dns), dnsCloudflaredIssue == nil else {
            return quickURLs
        }
        let dnsURLs: [URL] = activeDNSRoutes.compactMap { route in
            guard let baseURL = URL(string: "https://\(route.hostname)") else {
                return nil
            }
            return PublicURLBuilder.build(baseURL: baseURL, targetPath: route.targetPath)
        }
        return quickURLs + dnsURLs
    }

    func quickRouteFrom(_ route: LocalProxyRoute) -> String {
        guard let url = quickPublicURLs[route], let host = url.host else {
            if quickRouteIsPending(route) {
                return "받아오는중 ..."
            }
            return "Quick URL\(route.targetPath == "/" ? "" : route.targetPath)"
        }
        return "\(host)\(url.path == "/" ? "" : url.path)"
    }

    func quickRouteIsPending(_ route: LocalProxyRoute) -> Bool {
        quickPublicURLs[route] == nil && quickSessions.contains(where: { $0.route == route })
    }

    private func normalizeLists() {
        settings.targetPaths = normalizedPaths(settings.targetPaths, fallback: settings.targetPath)
        settings.targetPath = settings.targetPaths.first ?? "/"
        settings.quickRoutes = activeQuickRoutes
        if let firstRoute = settings.quickRoutes.first {
            settings.targetPort = firstRoute.targetPort
            settings.targetPath = firstRoute.targetPath
            settings.targetPaths = Array(NSOrderedSet(array: settings.quickRoutes.map(\.targetPath)).compactMap { $0 as? String })
        }
        settings.dnsTargetPaths = normalizedPaths(settings.dnsTargetPaths, fallback: settings.dnsTargetPath)
        settings.dnsTargetPath = settings.dnsTargetPaths.first ?? "/"
        settings.dnsRoutes = activeDNSRoutes
        settings.dnsHostnames = activeDNSHostnames
        settings.dnsHostname = settings.dnsHostnames.first ?? ""
        if let firstRoute = settings.dnsRoutes.first {
            settings.dnsTargetPort = firstRoute.targetPort
            settings.dnsTargetPath = firstRoute.targetPath
            settings.dnsTargetPaths = Array(NSOrderedSet(array: settings.dnsRoutes.map(\.targetPath)).compactMap { $0 as? String })
        }
    }

    private func normalizedPaths(_ paths: [String], fallback: String) -> [String] {
        let normalized = paths
            .map { path -> String in
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return "" }
                return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
            }
            .filter { !$0.isEmpty }
        if !normalized.isEmpty {
            return normalized
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFallback.isEmpty {
            return ["/"]
        }
        return [trimmedFallback.hasPrefix("/") ? trimmedFallback : "/" + trimmedFallback]
    }

    private func normalizedRoute(_ route: LocalProxyRoute, wildcardHost: Bool) -> LocalProxyRoute {
        var path = route.targetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            path = "/"
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        return LocalProxyRoute(
            hostname: wildcardHost ? "" : route.hostname.trimmingCharacters(in: .whitespacesAndNewlines),
            targetPort: route.targetPort,
            targetPath: path
        )
    }

    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        logs.append(trimmed)
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    private func cloudflaredIssue(from output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.contains(" ERR ") || $0.hasSuffix(" ERR") })
            .map { line in
                if let range = line.range(of: " ERR ") {
                    let message = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    return "cloudflared: \(message)"
                }
                return "cloudflared: \(line)"
            }
    }
}

struct MenuContentView: View {
    @ObservedObject var model: TunnelBarViewModel
    @State private var showsAbout = false
    @State private var showsAuthSecret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            routesTable
            modeControls
            tabContent
            Divider()
            footerControls
        }
        .padding(16)
        .frame(maxHeight: 1170, alignment: .top)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var routesTable: some View {
        RoutesTableView(
            quickRoutes: model.activeQuickRoutes,
            dnsRoutes: model.activeDNSRoutes,
            runningModes: model.runningModes,
            requiresRestart: model.requiresRestart,
            dnsUnavailableReason: model.dnsUnavailableReason,
            quickRouteFrom: { model.quickRouteFrom($0) },
            quickRouteIsPending: { model.quickRouteIsPending($0) },
            removeQuickRoute: { model.removeQuickRoute($0) },
            removeDNSRoute: { model.removeDNSRoute($0) }
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        if model.selectedTab == .quickURL {
            quickRouteForm
        } else if model.selectedTab == .dns {
            dnsControls
            dnsRouteForm
        } else if model.selectedTab == .security {
            securityControls
        } else if model.selectedTab == .logs {
            logsView
        }
    }

    private var header: some View {
        HStack {
            Label(model.status.label, systemImage: model.status.systemImage)
                .font(.headline)
            Spacer()
            Text(model.allowlistSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var quickRouteForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Quick Route")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("8989", text: $model.newQuickPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .onChange(of: model.newQuickPortText) { _, value in
                        model.newQuickPortText = digitsOnly(value)
                    }
                TextField("/console", text: $model.newTargetPath)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.addQuickRoute)
                Button(action: model.addQuickRoute) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var modeControls: some View {
        Picker("", selection: $model.selectedTab) {
            ForEach(AppTab.allCases) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: model.selectedTab) { _, tab in model.selectTab(tab) }
    }

    @ViewBuilder
    private var dnsControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tunnel")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Tunnel ID, e.g. 24c83c3f-...", text: $model.settings.dnsTunnelID)
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.saveSettings)
            TextField("Credentials file, e.g. ~/.cloudflared/<id>.json", text: $model.settings.dnsCredentialsFile)
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.saveSettings)
        }
    }

    private var dnsRouteForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add DNS Route")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("dev.example.com", text: $model.newDNSHostname)
                    .textFieldStyle(.roundedBorder)
                TextField("8989", text: $model.newDNSPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 66)
                    .onChange(of: model.newDNSPortText) { _, value in
                        model.newDNSPortText = digitsOnly(value)
                    }
                TextField("/console", text: $model.newTargetPath)
                    .textFieldStyle(.roundedBorder)
                Button(action: model.addDNSRoute) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canAddDNSRoute)
            }
        }
    }

    private func digitsOnly(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(5))
    }

    private var actionControls: some View {
        HStack {
            Button {
                if model.requiresRestart {
                    model.restart()
                } else if model.status.canStartTunnel {
                    model.start()
                } else {
                    model.stop()
                }
            } label: {
                Label(actionTitle, systemImage: actionIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.status == .starting || (!model.canStart && (model.status.canStartTunnel || model.requiresRestart)))
        }
    }

    private var actionTitle: String {
        if model.requiresRestart {
            return "Restart"
        }
        return model.status.canStartTunnel ? "Start" : "Stop"
    }

    private var actionIcon: String {
        if model.requiresRestart {
            return "arrow.clockwise"
        }
        return model.status.canStartTunnel ? "play.fill" : "stop.fill"
    }

    private var allowlistControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inbound IP Allowlist")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("203.0.113.10 or 198.51.100.0/24", text: $model.newAllowlistEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.addAllowlistEntry)
                Button(action: model.addAllowlistEntry) {
                    Image(systemName: "plus")
                }
            }
            ForEach(model.settings.allowlistEntries, id: \.self) { entry in
                HStack {
                    Text(entry)
                    Spacer()
                    Button {
                        model.removeAllowlistEntry(entry)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var securityControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            allowlistControls
            authHeaderControls
            installControls
        }
    }

    private var authHeaderControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Auth Header", isOn: $model.settings.authHeaderEnabled)
                .onChange(of: model.settings.authHeaderEnabled) { _, _ in
                    model.saveAuthHeaderSettings()
                }
            TextField("Header name", text: $model.settings.authHeaderName)
                .textFieldStyle(.roundedBorder)
                .disabled(!model.settings.authHeaderEnabled)
                .onSubmit(model.saveAuthHeaderSettings)
            HStack(spacing: 6) {
                if showsAuthSecret {
                    TextField("Secret", text: $model.authHeaderSecret)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.settings.authHeaderEnabled)
                        .onSubmit(model.saveAuthHeaderSettings)
                } else {
                    SecureField("Secret", text: $model.authHeaderSecret)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.settings.authHeaderEnabled)
                        .onSubmit(model.saveAuthHeaderSettings)
                }
                Button {
                    showsAuthSecret.toggle()
                } label: {
                    Image(systemName: showsAuthSecret ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .disabled(!model.settings.authHeaderEnabled)
                .help(showsAuthSecret ? "Hide secret" : "Show secret")
            }
            Button(action: model.saveAuthHeaderSettings) {
                Label("Save Auth Header", systemImage: "key.fill")
            }
            .disabled(!model.settings.authHeaderEnabled)
        }
    }

    private var footerControls: some View {
        HStack(spacing: 10) {
            Button {
                if model.requiresRestart {
                    model.restart()
                } else if model.status.canStartTunnel {
                    model.start()
                } else {
                    model.stop()
                }
            } label: {
                Label(actionTitle, systemImage: actionIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.status == .starting || (!model.canStart && (model.status.canStartTunnel || model.requiresRestart)))
            Spacer()
            Button {
                showsAbout = true
            } label: {
                Label("About", systemImage: "info.circle")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsAbout, arrowEdge: .bottom) {
                aboutPopup
            }
            Button("Quit", action: model.quit)
        }
    }

    private var aboutPopup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                koFiButton
                Spacer()
            }
            Divider()
            aboutRow("App", Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "routingflare")
            versionRow
            aboutRow("Creator", "Gyumin Hwangbo")
            projectLinkRow
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(updateSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if shouldShowInstallUpdate {
                    Button(action: model.installUpdate) {
                        Label("Install and Update", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.updateStatus == .checking || model.updateStatus == .downloading)
                }
            }
            HStack {
                Spacer()
                Button("Close") {
                    showsAbout = false
                }
            }
        }
        .padding(18)
        .frame(width: 340)
    }

    private var koFiButton: some View {
        Button {
            model.openKoFiPage()
        } label: {
            AsyncImage(url: TunnelBarViewModel.koFiImageURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                case .failure:
                    Text("Buy Me a Coffee")
                        .font(.caption.weight(.semibold))
                case .empty:
                    ProgressView()
                        .controlSize(.small)
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 183, height: 36)
            .accessibilityLabel("Buy Me a Coffee at ko-fi.com")
        }
        .buttonStyle(.borderless)
    }

    private var versionRow: some View {
        HStack {
            Text("Version")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)
            Text("\(appVersion) (\(appBuild))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Button(action: model.checkForUpdates) {
                Text(model.updateStatus == .checking ? "Checking..." : "Check")
                    .font(.caption.weight(.semibold))
            }
            .disabled(model.updateStatus == .checking || model.updateStatus == .downloading)
        }
    }

    private var projectLinkRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Project")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)
            Link(TunnelBarViewModel.projectPageURL.absoluteString, destination: TunnelBarViewModel.projectPageURL)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var updateSummary: String {
        switch model.updateStatus {
        case .idle:
            return "Current version: \(appVersion)"
        case .checking:
            return "Checking for updates. Current version: \(appVersion)"
        case .available(let version):
            return "New version available: \(version). Current version: \(appVersion)."
        case .current:
            return "Up to date. Current version: \(appVersion)."
        case .failed(let message):
            return "Update check failed. Current version: \(appVersion). \(message)"
        case .downloading:
            return "Downloading update. Current version: \(appVersion)."
        case .downloaded:
            return "Update downloaded. Open the DMG to install."
        }
    }

    private var shouldShowInstallUpdate: Bool {
        switch model.updateStatus {
        case .available, .downloaded:
            return true
        case .idle, .checking, .current, .failed, .downloading:
            return false
        }
    }

    private func aboutRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    @ViewBuilder
    private var installControls: some View {
        if !model.hasCloudflared {
            Button {
                model.installCloudflaredWithBrew()
            } label: {
                Label(model.installInProgress ? "Installing..." : "Install with Homebrew", systemImage: "arrow.down.circle")
            }
            .disabled(model.installInProgress)
        }
    }

    private var logsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Logs")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(model.logs.suffix(20).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 120)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct RoutesTableView: View {
    @State private var copiedValue: String?

    let quickRoutes: [LocalProxyRoute]
    let dnsRoutes: [LocalProxyRoute]
    let runningModes: Set<TunnelMode>
    let requiresRestart: Bool
    let dnsUnavailableReason: String?
    let quickRouteFrom: (LocalProxyRoute) -> String
    let quickRouteIsPending: (LocalProxyRoute) -> Bool
    let removeQuickRoute: (LocalProxyRoute) -> Void
    let removeDNSRoute: (LocalProxyRoute) -> Void

    private let statusColumnWidth: CGFloat = 14
    private let targetColumnWidth: CGFloat = 108
    private let actionColumnWidth: CGFloat = 22
    private let columnSpacing: CGFloat = 8
    private let tableInset: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            tableHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(quickRoutes, id: \.self) { route in
                        routeRow(
                            from: quickRouteFrom(route),
                            port: route.targetPort,
                            isActive: runningModes.contains(.quickURL),
                            isPending: quickRouteIsPending(route),
                            statusText: nil,
                            remove: { removeQuickRoute(route) }
                        )
                    }

                    ForEach(dnsRoutes, id: \.self) { route in
                        routeRow(
                            from: "\(route.hostname)\(displayPath(route.targetPath))",
                            port: route.targetPort,
                            isActive: runningModes.contains(.dns),
                            isPending: dnsUnavailableReason != nil,
                            statusText: runningModes.contains(.dns) ? nil : dnsUnavailableReason,
                            remove: { removeDNSRoute(route) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 86)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var tableHeader: some View {
        HStack(spacing: columnSpacing) {
            Text("")
                .frame(width: statusColumnWidth)
            Text("From")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("To")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: targetColumnWidth, alignment: .leading)
            Text("")
                .frame(width: actionColumnWidth)
        }
        .padding(.horizontal, tableInset)
    }

    private func routeRow(
        from: String,
        port: Int,
        isActive: Bool,
        isPending: Bool,
        statusText: String?,
        remove: @escaping () -> Void
    ) -> some View {
        let target = "127.0.0.1:\(String(port))"
        return HStack(spacing: columnSpacing) {
            Circle()
                .fill(routeDotColor(isActive: isActive, isPending: isPending))
                .frame(width: 7, height: 7)
                .frame(width: statusColumnWidth)
            VStack(alignment: .leading, spacing: 2) {
                copyableText(from, width: nil, truncationMode: .middle)
                if let statusText {
                    tooltippedText(
                        statusText,
                        width: nil,
                        truncationMode: .tail,
                        font: .caption2,
                        foregroundStyle: .orange,
                        copyable: false
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            copyableText(target, width: targetColumnWidth, truncationMode: .tail)
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .frame(width: actionColumnWidth, height: 22)
        }
        .frame(height: 43)
        .padding(.horizontal, tableInset)
    }

    private func copyableText(_ value: String, width: CGFloat?, truncationMode: Text.TruncationMode) -> some View {
        tooltippedText(
            value,
            width: width,
            truncationMode: truncationMode,
            font: .caption,
            foregroundStyle: .secondary,
            copyable: true
        )
    }

    private func tooltippedText(
        _ value: String,
        width: CGFloat?,
        truncationMode: Text.TruncationMode,
        font: Font,
        foregroundStyle: Color,
        copyable: Bool
    ) -> some View {
        let isCopied = copiedValue == value
        return Text(isCopied ? "Copied" : value)
            .font(font)
            .foregroundStyle(isCopied ? .secondary : foregroundStyle)
            .lineLimit(1)
            .truncationMode(truncationMode)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if copyable {
                    copy(value)
                }
            }
            .onHover { hovering in
                if hovering {
                    HoverTooltipPresenter.shared.schedule(text: value)
                } else {
                    HoverTooltipPresenter.shared.hide()
                }
            }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copiedValue = value
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if copiedValue == value {
                copiedValue = nil
            }
        }
    }

    private func routeDotColor(isActive: Bool, isPending: Bool) -> Color {
        if isPending {
            return .orange
        }
        return isActive && !requiresRestart ? .green : .secondary
    }

    private func displayPath(_ path: String) -> String {
        path == "/" ? "" : path
    }
}

@MainActor
private final class HoverTooltipPresenter {
    static let shared = HoverTooltipPresenter()

    private var pendingWorkItem: DispatchWorkItem?
    private var panel: NSPanel?

    func schedule(text: String) {
        hide()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.show(text: trimmed)
            }
        }
        pendingWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    func hide() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func show(text: String) {
        let content = TooltipBubble(text: text)
        let hostingView = NSHostingView(rootView: content)
        let fittingSize = hostingView.fittingSize
        let size = NSSize(
            width: min(max(fittingSize.width, 80), 340),
            height: min(max(fittingSize.height, 28), 180)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]

        let mouse = NSEvent.mouseLocation
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        var origin = NSPoint(x: mouse.x + 14, y: mouse.y - size.height - 12)
        origin.x = min(max(origin.x, visibleFrame.minX + 4), visibleFrame.maxX - size.width - 4)
        origin.y = min(max(origin.y, visibleFrame.minY + 4), visibleFrame.maxY - size.height - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFront(nil)
        self.panel = panel
    }
}

private struct TooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.primary)
            .lineLimit(8)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: 320, alignment: .leading)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }
}
