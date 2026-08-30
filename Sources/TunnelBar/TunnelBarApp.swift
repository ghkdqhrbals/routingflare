import AppKit
import SwiftUI
import TunnelBarCore

@main
struct TunnelBarApp: App {
    @NSApplicationDelegateAdaptor(RoutingFlareLaunchDelegate.self) private var launchDelegate
    @StateObject private var model: TunnelBarViewModel

    init() {
        RoutingFlareSingleInstance.terminateExistingInstances()
        _model = StateObject(wrappedValue: RoutingFlareRuntime.shared.model)
    }

    var body: some Scene {
        MenuBarExtra {
            NativeMenuContentView(model: model)
        } label: {
            Image(systemName: model.status.systemImage)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
private final class RoutingFlareRuntime {
    static let shared = RoutingFlareRuntime()
    let model = TunnelBarViewModel()

    private init() {}
}

@MainActor
private final class RoutingFlareLaunchDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        RoutingFlareWindowPresenter.shared.show(model: RoutingFlareRuntime.shared.model)
    }

    func applicationWillTerminate(_ notification: Notification) {
        RoutingFlareRuntime.shared.model.clearRouteStatusSnapshot()
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

private enum AppTypography {
    static let title = Font.system(size: 28, weight: .semibold)
    static let sectionTitle = Font.system(size: 16, weight: .semibold)
    static let content = Font.system(size: 14, weight: .regular)
    static let contentStrong = Font.system(size: 14, weight: .semibold)
    static let meta = Font.system(size: 12, weight: .medium)
}

private enum TunnelConfigurationState {
    case healthy
    case starting
    case down
    case inactive

    var label: String {
        switch self {
        case .healthy:
            return "Healthy"
        case .starting:
            return "Starting"
        case .down:
            return "Down"
        case .inactive:
            return "Inactive"
        }
    }

    var color: Color {
        switch self {
        case .healthy:
            return .green
        case .starting:
            return .orange
        case .down:
            return .red
        case .inactive:
            return .secondary
        }
    }
}

private struct TunnelConfigurationRow: Identifiable {
    let id: String
    let name: String
    let state: TunnelConfigurationState
    let replicas: Int
    let routes: [String]
}

enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case routes
    case options
    case logs
    case about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .routes:
            return "Routing"
        case .options:
            return "Options"
        case .logs:
            return "Logs"
        case .about:
            return "About"
        }
    }

    var tunnelMode: TunnelMode? {
        nil
    }

    var systemImage: String {
        switch self {
        case .routes:
            return "list.bullet.rectangle"
        case .options:
            return "slider.horizontal.3"
        case .logs:
            return "doc.text"
        case .about:
            return "info.circle"
        }
    }

    var subtitle: String? {
        nil
    }
}

enum UpdateStatus: Equatable {
    case idle
    case checking
    case available(version: String)
    case current
    case failed(String)
    case downloading
    case installing
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
        case .installing:
            return "Installing..."
        case .downloaded:
            return "Downloaded"
        }
    }
}

private enum RoutingFlareSingleInstance {
    static func terminateExistingInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let existingApplications = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { $0.processIdentifier != currentPID }

        for application in existingApplications {
            application.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                if !application.isTerminated {
                    application.forceTerminate()
                }
            }
        }
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

    deinit {
        stop()
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
    @Published var newDNSPathText = ""
    @Published var newQuickPortText = "3000"
    @Published var newQuickPathText = ""
    @Published var newTargetPath = ""
    @Published var installInProgress = false
    @Published var automaticInstallAttempted = false
    @Published var authHeaderSecret = ""
    @Published var routeAuthHeaderEnabledDraft = false
    @Published var routeAuthHeaderNameDraft = "X-Routingflare-Secret"
    @Published var routeAuthSavedRecently = false
    @Published var selectedSecurityRouteKind: TunnelMode?
    @Published var selectedSecurityRoute: LocalProxyRoute?
    @Published var dnsTunnelName = ""
    @Published var updateStatus: UpdateStatus = .idle
    @Published var latestUpdateURL: URL?
    @Published private var dnsCloudflaredIssue: String?
    @Published private var dnsProxyIssue: String?
    @Published private var quickProxyIssues: [LocalProxyRoute: String] = [:]

    private let settingsStore: SettingsStoring
    private let routeStatusStore: RouteStatusStoring
    private let tunnelProcess = TunnelProcess()
    private let accessPolicy: MutableProxyAccessPolicy
    private let routeSecurityPolicies: MutableRouteSecurityPolicies
    private var proxy: LocalFilteringProxy?
    private var quickSessions: [QuickTunnelSession] = []
    private var dnsProxyGeneration = UUID()
    private var quickProxyGenerations: [LocalProxyRoute: UUID] = [:]
    private var cliCommandObserver: NSObjectProtocol?
    private var cloudflaredConfigURL: URL?
    private var activeTunnelModes: Set<TunnelMode> = []
    private var resolvedDNSTunnelIdentity: String?
    private static let releaseAPIURL = URL(string: "https://api.github.com/repos/ghkdqhrbals/routingflare/releases/latest")!
    static let projectPageURL = URL(string: "https://ghkdqhrbals.github.io/routingflare/")!
    static let releasesURL = URL(string: "https://github.com/ghkdqhrbals/routingflare/releases/latest")!
    static let aboutMeURL = URL(string: "https://github.com/ghkdqhrbals")!
    static let koFiURL = URL(string: "https://ko-fi.com/D8X421KF0U")!
    static let koFiImageURL = URL(string: "https://storage.ko-fi.com/cdn/kofi6.png?v=6")!

    init(
        settingsStore: SettingsStoring = UserDefaultsSettingsStore(),
        routeStatusStore: RouteStatusStoring = UserDefaultsRouteStatusStore()
    ) {
        self.settingsStore = settingsStore
        self.routeStatusStore = routeStatusStore
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
        self.selectedTab = .routes
        self.settings = loaded
        self.accessPolicy = MutableProxyAccessPolicy(allowlistEntries: [])
        self.routeSecurityPolicies = MutableRouteSecurityPolicies(routes: loaded.quickRoutes + loaded.dnsRoutes)
        setupCLICommandObserver()
        handlePendingCLICommand()
        autoInstallCLIIfNeeded()
        autoInstallCloudflaredIfNeeded()
        resolveDNSTunnelNameIfNeeded()
        if loaded.autoStart {
            Task { @MainActor in
                self.start()
            }
        }
        saveRouteStatusSnapshot()
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
        if let dnsProxyIssue { return dnsProxyIssue }
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
        let securedRoutes = (allQuickRoutes + allDNSRoutes).filter { route in
            guard let security = route.security else { return false }
            return !security.allowlistEntries.isEmpty || security.authHeaderEnabled
        }.count
        return securedRoutes == 0 ? "Route security off" : "\(securedRoutes) secured routes"
    }

    var runningModes: Set<TunnelMode> {
        status.isStarted ? activeTunnelModes : []
    }

    func saveSettings() {
        normalizeLists()
        updateRouteSecurityPolicies()
        settingsStore.save(settings)
        resolveDNSTunnelNameIfNeeded()
        saveRouteStatusSnapshot()
    }

    func clearRouteStatusSnapshot() {
        routeStatusStore.clear()
    }

    private func saveRouteStatusSnapshot() {
        let entries = allQuickRoutes.map { route in
            RouteStatusEntry(
                route: route,
                kind: .quickURL,
                state: quickRouteRuntimeState(route),
                publicURL: quickPublicURLs[route]?.absoluteString,
                message: quickRouteRuntimeMessage(route)
            )
        } + allDNSRoutes.map { route in
            RouteStatusEntry(
                route: route,
                kind: .dns,
                state: dnsRouteRuntimeState,
                publicURL: dnsPublicURL(for: route)?.absoluteString,
                message: dnsRouteRuntimeMessage
            )
        }
        routeStatusStore.save(
            RouteStatusSnapshot(
                appPID: ProcessInfo.processInfo.processIdentifier,
                entries: entries
            )
        )
    }

    private func quickRouteRuntimeState(_ route: LocalProxyRoute) -> RouteRuntimeState {
        if quickProxyIssue(for: route) != nil { return .error }
        if requiresRestart {
            return .restartRequired
        }
        if quickRouteIsPending(route) {
            return .pending
        }
        if quickPublicURLs[route] != nil && status.isStarted {
            return .opened
        }
        if case .error = status {
            return .error
        }
        return .stopped
    }

    private func quickRouteRuntimeMessage(_ route: LocalProxyRoute) -> String? {
        if let issue = quickProxyIssue(for: route) { return issue }
        if quickRouteIsPending(route) {
            return "Fetching URL"
        }
        if case .error(let message) = status {
            return message
        }
        return nil
    }

    private var dnsRouteRuntimeState: RouteRuntimeState {
        if dnsProxyIssue != nil { return .error }
        if let dnsCloudflaredIssue, !dnsCloudflaredIssue.isEmpty {
            return activeTunnelModes.contains(.dns) ? .degraded : .error
        }
        if requiresRestart {
            return .restartRequired
        }
        if status == .starting && !activeDNSRoutes.isEmpty {
            return .pending
        }
        if activeTunnelModes.contains(.dns), status.isStarted {
            return .opened
        }
        if case .error = status {
            return .error
        }
        return .stopped
    }

    private var dnsRouteRuntimeMessage: String? {
        if let dnsProxyIssue { return dnsProxyIssue }
        if let dnsCloudflaredIssue, !dnsCloudflaredIssue.isEmpty {
            return dnsCloudflaredIssue
        }
        if status == .starting && !activeDNSRoutes.isEmpty {
            return "Starting"
        }
        if case .error(let message) = status {
            return message
        }
        return nil
    }

    private func dnsPublicURL(for route: LocalProxyRoute) -> URL? {
        guard activeTunnelModes.contains(.dns) else {
            return nil
        }
        guard let baseURL = URL(string: "https://\(route.hostname)") else {
            return nil
        }
        return PublicURLBuilder.build(baseURL: baseURL, targetPath: route.targetPath)
    }

    func selectTab(_ tab: AppTab) {
        selectedTab = tab
        if let mode = tab.tunnelMode {
            settings.mode = mode
        }
        settingsStore.save(settings)
    }

    private func setupCLICommandObserver() {
        cliCommandObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(RoutingFlareDefaults.commandNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let command = notification.userInfo?["command"] as? String else { return }
            Task { @MainActor in
                self?.handleCLICommand(command)
            }
        }
    }

    private func handlePendingCLICommand() {
        let defaults = RoutingFlareDefaults.userDefaults()
        guard let command = defaults.string(forKey: RoutingFlareDefaults.pendingCommandKey) else {
            return
        }
        defaults.removeObject(forKey: RoutingFlareDefaults.pendingCommandKey)
        handleCLICommand(command)
    }

    private func handleCLICommand(_ command: String) {
        RoutingFlareDefaults.userDefaults().removeObject(forKey: RoutingFlareDefaults.pendingCommandKey)
        switch command {
        case "start":
            if status.isStarted || requiresRestart {
                restart()
            } else {
                start()
            }
        case "stop":
            stop()
        case "open":
            selectedTab = .routes
            RoutingFlareWindowPresenter.shared.show(model: self)
        case "settings":
            selectedTab = .options
            RoutingFlareWindowPresenter.shared.show(model: self)
        case "update":
            selectedTab = .about
            RoutingFlareWindowPresenter.shared.show(model: self)
            updateFromCLI()
        case "reload":
            reloadSettingsFromStore()
        default:
            appendLog("Unknown CLI command: \(command)")
        }
    }

    private func reloadSettingsFromStore() {
        defer { saveRouteStatusSnapshot() }
        let wasStarted = status.isStarted
        settings = settingsStore.load()
        syncSelectedSecurityRoute()
        loadSelectedRouteSecurityDraft()
        newDNSPortText = String(settings.dnsTargetPort)
        newQuickPortText = String(settings.targetPort)
        updateAccessPolicy()
        resolveDNSTunnelNameIfNeeded()
        if wasStarted {
            requiresRestart = true
            appendLog("Settings updated from CLI. Restart to apply route changes.")
        } else {
            appendLog("Settings updated from CLI.")
        }
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

    private func resolveDNSTunnelNameIfNeeded() {
        let tunnelID = settings.dnsTunnelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tunnelID.isEmpty,
              let cloudflared = CloudflaredLocator().find(configuredPath: settings.cloudflaredPath) else {
            dnsTunnelName = ""
            resolvedDNSTunnelIdentity = nil
            return
        }

        let identity = "\(cloudflared)|\(tunnelID)"
        guard resolvedDNSTunnelIdentity != identity else {
            return
        }
        resolvedDNSTunnelIdentity = identity

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: cloudflared)
            // JSON output gives us the canonical tunnel name instead of relying on
            // the human-readable table format, which can change between versions.
            process.arguments = ["tunnel", "info", "--output", "json", tunnelID]
            // Keep stderr out of the JSON stream. cloudflared may print warnings
            // there even when the JSON response is valid.
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
                process.waitUntilExit()
                let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let name = CloudflaredTunnelInfoParser.parseName(from: output)
                DispatchQueue.main.async {
                    guard let self,
                          self.settings.dnsTunnelID.trimmingCharacters(in: .whitespacesAndNewlines) == tunnelID else {
                        return
                    }
                    self.dnsTunnelName = name ?? ""
                    if let name {
                        self.appendLog("Resolved DNS tunnel: \(name)")
                    } else {
                        if !errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            self.appendLog("Tunnel name lookup failed: \(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))")
                        }
                        // A failed lookup must remain retryable; otherwise the
                        // UUID fallback can stay visible for the whole session.
                        self.resolvedDNSTunnelIdentity = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self,
                          self.settings.dnsTunnelID.trimmingCharacters(in: .whitespacesAndNewlines) == tunnelID else {
                        return
                    }
                    self.dnsTunnelName = ""
                    // Do not permanently cache a failed lookup. A later save,
                    // reload, or settings refresh should be able to resolve it.
                    self.resolvedDNSTunnelIdentity = nil
                }
            }
        }
    }

    func installCloudflaredWithBrew() {
        installCloudflaredWithBrew(automatic: false)
    }

    private func autoInstallCLIIfNeeded() {
        let fileManager = FileManager.default
        guard let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return
        }
        let bundledCLIURL = executableDirectory.appendingPathComponent("routingflare")

        do {
            let result = try CLIInstaller(fileManager: fileManager).install(bundledCLIURL: bundledCLIURL)
            if result.installedOrUpdatedLink {
                appendLog("CLI installed at ~/.local/bin/routingflare")
            }
            if result.addedPathToZshrc {
                appendLog("Added ~/.local/bin to ~/.zshrc")
            }
        } catch {
            appendLog("CLI install failed: \(error.localizedDescription)")
        }
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
        defer { saveRouteStatusSnapshot() }
        saveSettings()
        updateAccessPolicy()
        publicURL = nil
        quickPublicURLs = [:]
        dnsCloudflaredIssue = nil
        requiresRestart = false
        status = .starting
        activeTunnelModes = []
        var startedAnyTunnel = false

        do {
            if !activeQuickRoutes.isEmpty {
                if hasCloudflared {
                    try startQuickTunnels()
                    startedAnyTunnel = true
                } else {
                    appendLog("Random DNS routes not started: cloudflared was not found")
                }
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
            if let firstURL = publicURLs.first {
                publicURL = firstURL
            }
            addRecentPort(activeTargetPort)
        } catch {
            appendLog("Start failed: \(error.localizedDescription)")
            if startedAnyTunnel, !quickSessions.isEmpty {
                applyDNSFailure(error.localizedDescription)
            } else {
                stop()
                status = .error(error.localizedDescription)
            }
        }
    }

    private func startDNSTunnel() throws {
            defer { saveRouteStatusSnapshot() }
            dnsCloudflaredIssue = nil
            dnsProxyIssue = nil
            let generation = UUID()
            dnsProxyGeneration = generation
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
                routeSecurityPolicies: routeSecurityPolicies,
                logHandler: logHandler,
                onFailure: { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.dnsProxyGeneration == generation else { return }
                        self.dnsProxyIssue = message
                        self.stopDNSTunnelOnly()
                        self.applyDNSFailure(message)
                    }
                }
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

            activeTunnelModes.insert(.dns)
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
        defer { saveRouteStatusSnapshot() }
        guard !quickSessions.contains(where: { $0.route == route }) else { return }
        let generation = UUID()
        quickProxyGenerations[route] = generation
        quickProxyIssues[route] = nil
        let proxy = LocalFilteringProxy(
            routes: [route],
            fallbackTargetPort: route.targetPort,
            accessPolicy: accessPolicy,
            routeSecurityPolicies: routeSecurityPolicies,
            logHandler: { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(line)
                }
            },
            onFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.quickProxyGenerations[route] == generation else { return }
                    self.stopQuickRouteSession(route)
                    self.quickProxyIssues[route] = message
                    if self.activeTunnelModes.isEmpty { self.status = .error(message) }
                    self.saveRouteStatusSnapshot()
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
        defer { saveRouteStatusSnapshot() }
        dnsProxyGeneration = UUID()
        quickProxyGenerations = [:]
        quickProxyIssues = [:]
        dnsProxyIssue = nil
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
            guard selectedSecurityRoute != nil else {
                appendLog("Select a route before adding an allowlist entry.")
                return
            }
            updateSelectedSecurity { security in
                if !security.allowlistEntries.contains(candidate) {
                    security.allowlistEntries.append(candidate)
                }
            }
            newAllowlistEntry = ""
        } catch {
            appendLog(error.localizedDescription)
        }
    }

    func removeAllowlistEntry(_ entry: String) {
        updateSelectedSecurity { security in
            security.allowlistEntries.removeAll { $0 == entry }
        }
    }

    func saveAuthHeaderSettings() {
        guard selectedSecurityRoute != nil else {
            appendLog("Select a route before saving auth header settings.")
            return
        }
        updateSelectedSecurity { security in
            let trimmedName = routeAuthHeaderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            security.authHeaderEnabled = routeAuthHeaderEnabledDraft
            security.authHeaderName = trimmedName.isEmpty ? "X-Routingflare-Secret" : trimmedName
            security.authHeaderSecret = authHeaderSecret
        }
        loadSelectedRouteSecurityDraft()
        routeAuthSavedRecently = true
    }

    func setSelectedAuthHeaderEnabled(_ enabled: Bool) {
        routeAuthHeaderEnabledDraft = enabled
        routeAuthSavedRecently = false
    }

    func setSelectedAuthHeaderName(_ name: String) {
        routeAuthHeaderNameDraft = name
        routeAuthSavedRecently = false
    }

    func loadAuthHeaderSecretIfNeeded() {
        loadSelectedRouteSecurityDraft()
    }

    func updateAuthHeaderSecretDraft(_ secret: String) {
        authHeaderSecret = secret
        routeAuthSavedRecently = false
    }

    var selectedRouteSecurity: RouteSecurity {
        selectedSecurityRoute?.security ?? RouteSecurity()
    }

    var routeAuthHeaderHasChanges: Bool {
        let security = selectedRouteSecurity
        let savedName = security.authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let draftName = routeAuthHeaderNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return routeAuthHeaderEnabledDraft != security.authHeaderEnabled ||
        (draftName.isEmpty ? "X-Routingflare-Secret" : draftName) != (savedName.isEmpty ? "X-Routingflare-Secret" : savedName) ||
        authHeaderSecret != security.authHeaderSecret
    }

    var selectedRouteDisplayName: String {
        guard let route = selectedSecurityRoute else {
            return "Select a route"
        }
        switch selectedSecurityRouteKind {
        case .quickURL:
            return quickRouteFrom(route)
        case .dns:
            return "\(route.hostname)\(route.targetPath == "/" ? "" : route.targetPath)"
        case nil:
            return "\(route.hostname)\(route.targetPath == "/" ? "" : route.targetPath)"
        }
    }

    func selectRouteForSecurity(_ route: LocalProxyRoute, kind: TunnelMode) {
        let normalized = normalizedRoute(route, wildcardHost: kind == .quickURL)
        if selectedSecurityRouteKind == kind, selectedSecurityRoute == normalized {
            selectedSecurityRouteKind = nil
            selectedSecurityRoute = nil
            authHeaderSecret = ""
            routeAuthHeaderEnabledDraft = false
            routeAuthHeaderNameDraft = "X-Routingflare-Secret"
            routeAuthSavedRecently = false
            newAllowlistEntry = ""
            return
        }
        selectedSecurityRouteKind = kind
        selectedSecurityRoute = normalized
        loadSelectedRouteSecurityDraft()
        newAllowlistEntry = ""
    }

    @discardableResult
    func addDNSRoute() -> Bool {
        let hostname = newDNSHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = newDNSPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAddDNSRoute, let port = parsedPort(newDNSPortText), !hostname.isEmpty else { return false }
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
        newDNSPathText = ""
        saveSettings()
        if didAdd {
            reconcileDNSTunnelAfterRouteToggle()
        }
        return didAdd
    }

    @discardableResult
    func addQuickRoute() -> Bool {
        var path = newQuickPathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = parsedPort(newQuickPortText) else { return false }
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
        newQuickPathText = ""
        saveSettings()
        if didAdd {
            do {
                try openQuickRoute(normalizedRoute(route, wildcardHost: true))
            } catch {
                status = .error(error.localizedDescription)
                appendLog("Random DNS open failed: \(error.localizedDescription)")
            }
        }
        return didAdd
    }

    func removeQuickRoute(_ route: LocalProxyRoute) {
        let oldCount = settings.quickRoutes.count
        settings.quickRoutes.removeAll { $0 == route }
        saveSettings()
        if settings.quickRoutes.count != oldCount {
            stopQuickRouteSession(route)
            syncSelectedSecurityRoute()
        }
    }

    func removeDNSRoute(_ route: LocalProxyRoute) {
        let oldCount = settings.dnsRoutes.count
        settings.dnsRoutes.removeAll { $0 == route }
        saveSettings()
        if settings.dnsRoutes.count != oldCount {
            reconcileDNSTunnelAfterRouteToggle()
            syncSelectedSecurityRoute()
        }
    }

    func toggleQuickRoute(_ route: LocalProxyRoute) {
        guard let index = settings.quickRoutes.firstIndex(where: { normalizedRoute($0, wildcardHost: true) == normalizedRoute(route, wildcardHost: true) }) else {
            return
        }
        var updatedRoute = settings.quickRoutes[index]
        updatedRoute.isOpen.toggle()
        settings.quickRoutes[index] = updatedRoute
        saveSettings()

        let normalized = normalizedRoute(updatedRoute, wildcardHost: true)
        if normalized.isOpen {
            appendLog("Opening random DNS route \(normalized.targetPath). A new random DNS address will be assigned.")
            do {
                try openQuickRoute(normalized)
            } catch {
                status = .error(error.localizedDescription)
                appendLog("Random DNS open failed: \(error.localizedDescription)")
            }
        } else {
            appendLog("Closing random DNS route \(normalized.targetPath)")
            stopQuickRouteSession(normalized)
        }
        saveRouteStatusSnapshot()
    }

    func toggleDNSRoute(_ route: LocalProxyRoute) {
        guard let index = settings.dnsRoutes.firstIndex(where: { normalizedRoute($0, wildcardHost: false) == normalizedRoute(route, wildcardHost: false) }) else {
            return
        }
        var updatedRoute = settings.dnsRoutes[index]
        updatedRoute.isOpen.toggle()
        settings.dnsRoutes[index] = updatedRoute
        saveSettings()
        appendLog("\(updatedRoute.isOpen ? "Opening" : "Closing") DNS route \(updatedRoute.hostname)\(updatedRoute.normalizedTargetPath == "/" ? "" : updatedRoute.normalizedTargetPath)")
        reconcileDNSTunnelAfterRouteToggle()
        saveRouteStatusSnapshot()
    }

    private func updateSelectedSecurity(_ update: (inout RouteSecurity) -> Void) {
        guard let kind = selectedSecurityRouteKind, let selectedRoute = selectedSecurityRoute else {
            return
        }

        switch kind {
        case .quickURL:
            guard let index = settings.quickRoutes.firstIndex(where: { normalizedRoute($0, wildcardHost: true) == selectedRoute }) else {
                syncSelectedSecurityRoute()
                return
            }
            var route = settings.quickRoutes[index]
            var security = route.security ?? RouteSecurity()
            update(&security)
            route.security = security.isEmpty ? nil : security
            settings.quickRoutes[index] = route
            selectedSecurityRoute = normalizedRoute(route, wildcardHost: true)
        case .dns:
            guard let index = settings.dnsRoutes.firstIndex(where: { normalizedRoute($0, wildcardHost: false) == selectedRoute }) else {
                syncSelectedSecurityRoute()
                return
            }
            var route = settings.dnsRoutes[index]
            var security = route.security ?? RouteSecurity()
            update(&security)
            route.security = security.isEmpty ? nil : security
            settings.dnsRoutes[index] = route
            selectedSecurityRoute = normalizedRoute(route, wildcardHost: false)
        }

        updateAccessPolicy()
        saveSettings()
    }

    private func syncSelectedSecurityRoute() {
        guard let kind = selectedSecurityRouteKind, let selectedRoute = selectedSecurityRoute else {
            return
        }

        switch kind {
        case .quickURL:
            selectedSecurityRoute = allQuickRoutes.first { $0 == selectedRoute }
        case .dns:
            selectedSecurityRoute = allDNSRoutes.first { $0 == selectedRoute }
        }

        if selectedSecurityRoute == nil {
            selectedSecurityRouteKind = nil
            authHeaderSecret = ""
            routeAuthHeaderEnabledDraft = false
            routeAuthHeaderNameDraft = "X-Routingflare-Secret"
        } else {
            loadSelectedRouteSecurityDraft()
        }
    }

    private func loadSelectedRouteSecurityDraft() {
        let security = selectedRouteSecurity
        routeAuthHeaderEnabledDraft = security.authHeaderEnabled
        routeAuthHeaderNameDraft = security.authHeaderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "X-Routingflare-Secret"
            : security.authHeaderName
        authHeaderSecret = security.authHeaderSecret
        routeAuthSavedRecently = false
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

    func openAboutMePage() {
        NSWorkspace.shared.open(Self.aboutMeURL)
    }

    func openKoFiPage() {
        NSWorkspace.shared.open(Self.koFiURL)
    }

    func checkForUpdates() {
        guard updateStatus != .checking && updateStatus != .downloading && updateStatus != .installing else { return }
        checkForUpdates(installWhenAvailable: false)
    }

    func updateFromCLI() {
        guard updateStatus != .checking && updateStatus != .downloading && updateStatus != .installing else { return }
        appendLog("CLI requested update check")
        checkForUpdates(installWhenAvailable: true)
    }

    private func checkForUpdates(installWhenAvailable: Bool) {
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
                    if installWhenAvailable,
                       case .available = self?.updateStatus {
                        self?.installUpdate()
                    } else if installWhenAvailable,
                              self?.updateStatus == .current {
                        self?.appendLog("Update skipped: already up to date")
                    }
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
        guard updateStatus != .downloading && updateStatus != .installing else { return }
        let url = latestUpdateURL ?? Self.releasesURL
        guard url.pathExtension.lowercased() == "dmg" else {
            NSWorkspace.shared.open(url)
            return
        }

        updateStatus = .downloading
        Task { [weak self] in
            do {
                let (temporaryURL, _) = try await URLSession.shared.download(from: url)
                let updatesDirectory = try Self.applicationSupportDirectory()
                    .appendingPathComponent("Updates", isDirectory: true)
                try FileManager.default.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)
                let destination = updatesDirectory.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                await MainActor.run {
                    do {
                        try self?.installAndRestart(from: destination)
                    } catch {
                        self?.updateStatus = .failed(error.localizedDescription)
                        self?.appendLog("Update install failed: \(error.localizedDescription)")
                    }
                }
            } catch {
                await MainActor.run {
                    self?.updateStatus = .failed(error.localizedDescription)
                    self?.appendLog("Update download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func installAndRestart(from dmgURL: URL) throws {
        updateStatus = .installing
        appendLog("Installing update from \(dmgURL.path)")

        let helperURL = try Self.applicationSupportDirectory()
            .appendingPathComponent("routingflare-update-\(UUID().uuidString).zsh")
        let currentAppURL = Bundle.main.bundleURL
        let destinationAppURL = Self.updateDestinationAppURL(currentAppURL)
        let script = """
        #!/bin/zsh
        set -euo pipefail

        DMG_PATH="$1"
        DEST_APP="$2"
        OLD_PID="$3"
        APP_NAME="$4"
        LOG_PATH="$5"
        MOUNT_DIR="$(mktemp -d /tmp/routingflare-update.XXXXXX)"

        {
          echo "Mounting $DMG_PATH"
          hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$DMG_PATH"
          SRC_APP="$MOUNT_DIR/$APP_NAME.app"
          if [[ ! -d "$SRC_APP" ]]; then
            SRC_APP="$(find "$MOUNT_DIR" -maxdepth 1 -name '*.app' -type d | head -n 1)"
          fi
          if [[ -z "$SRC_APP" || ! -d "$SRC_APP" ]]; then
            echo "No app bundle found in DMG"
            exit 1
          fi

          while kill -0 "$OLD_PID" 2>/dev/null; do
            sleep 0.2
          done

          echo "Replacing $DEST_APP"
          rm -rf "$DEST_APP"
          ditto "$SRC_APP" "$DEST_APP"
          xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true
          hdiutil detach "$MOUNT_DIR"
          open "$DEST_APP"
          echo "Update installed"
        } >> "$LOG_PATH" 2>&1
        """
        try script.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        let logURL = try Self.applicationSupportDirectory().appendingPathComponent("update.log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            helperURL.path,
            dmgURL.path,
            destinationAppURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            currentAppURL.deletingPathExtension().lastPathComponent,
            logURL.path
        ]
        try process.run()
        quit()
    }

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    private func applyLatestRelease(_ release: GitHubRelease) {
        let plan = ReleasePlanner.plan(from: release, currentVersion: currentAppVersion)
        latestUpdateURL = plan.dmgURL ?? plan.releaseURL ?? Self.releasesURL
        if plan.isNewer {
            updateStatus = .available(version: plan.latestVersion)
        } else {
            updateStatus = .current
        }
    }

    private var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func updateDestinationAppURL(_ currentAppURL: URL) -> URL {
        let path = currentAppURL.path
        if path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            return URL(fileURLWithPath: "/Applications", isDirectory: true)
                .appendingPathComponent(currentAppURL.lastPathComponent)
        }
        return currentAppURL
    }

    private static func applicationSupportDirectory() throws -> URL {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TunnelBar", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        return supportDirectory
    }

    private var effectiveCloudflaredPath: String {
        if !settings.cloudflaredPath.isEmpty {
            return settings.cloudflaredPath
        }
        return CloudflaredLocator().find() ?? ""
    }

    private func handleTunnelOutput(_ output: String) {
        guard proxy?.port != nil else { return }
        defer { saveRouteStatusSnapshot() }
        let recoveredConnection = TunnelURLParser.outputShowsRegisteredConnection(output)
        let connectionRetryIssue = TunnelURLParser.outputShowsConnectionRetryIssue(output)
        let issue = recoveredConnection ? nil : cloudflaredIssue(from: output, previousLog: logs.last)
        appendLog(output)
        if connectionRetryIssue {
            dnsCloudflaredIssue = cloudflaredRetryIssue(from: output)
            activeTunnelModes.insert(.dns)
            status = .running
            publicURL = publicURLs.first
            return
        }
        if let issue {
            dnsCloudflaredIssue = issue
            activeTunnelModes.remove(.dns)
            applyDNSFailure(issue)
            return
        }
        if let parsedURL = TunnelURLParser.parsePublicURL(from: output) {
            dnsCloudflaredIssue = nil
            publicURL = PublicURLBuilder.build(baseURL: parsedURL, targetPath: activeTargetPaths.first ?? "/")
            activeTunnelModes.insert(.dns)
            status = .running
        } else if recoveredConnection {
            dnsCloudflaredIssue = nil
            activeTunnelModes.insert(.dns)
            status = .running
            publicURL = publicURLs.first
        } else if status == .starting {
            activeTunnelModes.insert(.dns)
            status = .running
        }
    }

    private func handleQuickTunnelOutput(_ output: String, route: LocalProxyRoute) {
        guard quickSessions.contains(where: { $0.route == route && $0.proxy.port != nil }) else { return }
        defer { saveRouteStatusSnapshot() }
        let recoveredConnection = TunnelURLParser.outputShowsRegisteredConnection(output)
        appendLog(output)
        if let parsedURL = TunnelURLParser.parsePublicURL(from: output),
           let routedURL = PublicURLBuilder.build(baseURL: parsedURL, targetPath: route.targetPath) {
            quickPublicURLs[route] = routedURL
            publicURL = quickPublicURLs.values.first
            activeTunnelModes.insert(.quickURL)
            status = .running
        } else if recoveredConnection {
            activeTunnelModes.insert(.quickURL)
            if case .error = status {
                status = .running
            }
        }
    }

    private func handleTunnelExit(mode: TunnelMode, statusCode: Int32) {
        defer { saveRouteStatusSnapshot() }
        if mode == .dns, let dnsProxyIssue { applyDNSFailure(dnsProxyIssue); return }
        guard status != .stopped else { return }
        activeTunnelModes.remove(mode)
        if statusCode != 0 {
            let exitIssue = "cloudflared exited with status \(statusCode)"
            let cloudflaredError = dnsCloudflaredIssue ?? recentCloudflaredIssueFromLogs()
            let issue = combinedCloudflaredIssue(error: cloudflaredError, exitIssue: exitIssue)
            dnsCloudflaredIssue = issue
            applyDNSFailure(issue)
            return
        }
        dnsCloudflaredIssue = nil
        if activeTunnelModes.isEmpty {
            status = .stopped
        }
    }

    private func handleQuickTunnelExit(route: LocalProxyRoute, statusCode: Int32) {
        defer { saveRouteStatusSnapshot() }
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

    private func openQuickRoute(_ route: LocalProxyRoute) throws {
        guard route.isOpen else { return }
        guard hasCloudflared else {
            throw TunnelStartError(message: "cloudflared was not found")
        }
        try startQuickTunnel(route)
        activeTunnelModes.insert(.quickURL)
        status = .running
        publicURL = publicURLs.first
    }

    private func stopQuickRouteSession(_ route: LocalProxyRoute) {
        defer { saveRouteStatusSnapshot() }
        let normalized = normalizedRoute(route, wildcardHost: true)
        quickProxyGenerations[normalized] = nil
        quickProxyIssues[normalized] = nil
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

    private func reconcileDNSTunnelAfterRouteToggle() {
        defer { saveRouteStatusSnapshot() }
        updateAccessPolicy()
        updateRouteSecurityPolicies()
        guard !activeDNSRoutes.isEmpty else {
            stopDNSTunnelOnly()
            dnsCloudflaredIssue = nil
            if quickSessions.isEmpty {
                status = .stopped
            }
            return
        }
        guard canStartDNS else {
            dnsCloudflaredIssue = dnsUnavailableReason
            if quickSessions.isEmpty {
                status = .error(dnsUnavailableReason ?? "DNS route is not configured")
            }
            return
        }
        stopDNSTunnelOnly()
        do {
            try startDNSTunnel()
            status = .running
            publicURL = publicURLs.first
        } catch {
            appendLog("DNS route open failed: \(error.localizedDescription)")
            applyDNSFailure(error.localizedDescription)
        }
    }

    private func applyDNSFailure(_ issue: String) {
        defer { saveRouteStatusSnapshot() }
        dnsCloudflaredIssue = issue
        activeTunnelModes.remove(.dns)
        if activeTunnelModes.contains(.quickURL) || !quickSessions.isEmpty {
            status = .running
            publicURL = quickPublicURLs.values.first
        } else {
            status = .error(issue)
        }
    }

    private func stopDNSTunnelOnly() {
        defer { saveRouteStatusSnapshot() }
        dnsProxyGeneration = UUID()
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

    private func updateAccessPolicy() {
        accessPolicy.update(allowlistEntries: [])
    }

    private func updateRouteSecurityPolicies() {
        routeSecurityPolicies.update(routes: allQuickRoutes + allDNSRoutes)
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
        let supportDirectory = try Self.applicationSupportDirectory()
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
        allQuickRoutes
            .filter(\.isOpen)
    }

    var activeDNSRoutes: [LocalProxyRoute] {
        allDNSRoutes
            .filter(\.isOpen)
    }

    var allQuickRoutes: [LocalProxyRoute] {
        settings.quickRoutes
            .map { normalizedRoute($0, wildcardHost: true) }
            .filter { $0.targetPort > 0 && $0.targetPort <= 65535 }
    }

    var allDNSRoutes: [LocalProxyRoute] {
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

    fileprivate var tunnelConfigurationRows: [TunnelConfigurationRow] {
        var rows: [TunnelConfigurationRow] = []

        if !allQuickRoutes.isEmpty {
            let openRoutes = activeQuickRoutes
            let pending = openRoutes.contains(where: quickRouteIsPending)
            let healthy = !openRoutes.isEmpty && openRoutes.allSatisfy { quickRouteIsOpen($0) }
            let state: TunnelConfigurationState
            if openRoutes.isEmpty {
                state = .inactive
            } else if pending {
                state = .starting
            } else if healthy && activeTunnelModes.contains(.quickURL) && !requiresRestart {
                state = .healthy
            } else {
                state = .down
            }

            rows.append(TunnelConfigurationRow(
                id: "quick",
                name: "Random DNS",
                state: state,
                replicas: quickSessions.count,
                routes: openRoutes.map { quickRouteFrom($0) }
            ))
        }

        if !allDNSRoutes.isEmpty || !settings.dnsTunnelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let tunnelID = settings.dnsTunnelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let openRoutes = activeDNSRoutes
            let hasConfiguration = !tunnelID.isEmpty && !settings.dnsCredentialsFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let state: TunnelConfigurationState
            if openRoutes.isEmpty {
                state = .inactive
            } else if !hasConfiguration || dnsUnavailableReason != nil {
                state = .down
            } else if status == .starting {
                state = .starting
            } else if activeTunnelModes.contains(.dns) && !requiresRestart {
                state = .healthy
            } else {
                state = .down
            }

            rows.append(TunnelConfigurationRow(
                id: "dns",
                name: dnsTunnelName.isEmpty
                    ? (tunnelID.isEmpty ? "DNS tunnel" : "DNS tunnel · \(tunnelID)")
                    : dnsTunnelName,
                state: state,
                replicas: activeTunnelModes.contains(.dns) ? 1 : 0,
                routes: openRoutes.map { "\($0.hostname)\($0.targetPath == "/" ? "" : $0.targetPath)" }
            ))
        }

        return rows
    }

    fileprivate var currentCloudflaredPath: String {
        effectiveCloudflaredPath.isEmpty ? "Not found" : effectiveCloudflaredPath
    }

    fileprivate var currentDNSConfigPath: String? {
        cloudflaredConfigURL?.path
    }

    func quickRouteFrom(_ route: LocalProxyRoute) -> String {
        guard let url = quickPublicURLs[route], let host = url.host else {
            if quickRouteIsPending(route) {
                return "Fetching URL..."
            }
            return "random dns\(route.targetPath == "/" ? "" : route.targetPath)"
        }
        return "\(host)\(url.path == "/" ? "" : url.path)"
    }

    func quickRouteIsPending(_ route: LocalProxyRoute) -> Bool {
        quickPublicURLs[route] == nil && quickSessions.contains(where: { $0.route == route })
    }

    func quickProxyIssue(for route: LocalProxyRoute) -> String? {
        quickProxyIssues[normalizedRoute(route, wildcardHost: true)]
    }

    func quickRouteIsOpen(_ route: LocalProxyRoute) -> Bool {
        quickPublicURLs[normalizedRoute(route, wildcardHost: true)] != nil
    }

    func dnsRouteIsOpen(_ route: LocalProxyRoute) -> Bool {
        normalizedRoute(route, wildcardHost: false).isOpen && activeTunnelModes.contains(.dns)
    }

    private func normalizeLists() {
        settings.targetPaths = normalizedPaths(settings.targetPaths, fallback: settings.targetPath)
        settings.targetPath = settings.targetPaths.first ?? "/"
        settings.quickRoutes = allQuickRoutes
        if let firstRoute = settings.quickRoutes.first {
            settings.targetPort = firstRoute.targetPort
            settings.targetPath = firstRoute.targetPath
            settings.targetPaths = Array(NSOrderedSet(array: settings.quickRoutes.map(\.targetPath)).compactMap { $0 as? String })
        }
        settings.dnsTargetPaths = normalizedPaths(settings.dnsTargetPaths, fallback: settings.dnsTargetPath)
        settings.dnsTargetPath = settings.dnsTargetPaths.first ?? "/"
        settings.dnsRoutes = allDNSRoutes
        settings.dnsHostnames = Array(NSOrderedSet(array: settings.dnsRoutes.map(\.hostname)).compactMap { $0 as? String })
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
            targetPath: path,
            security: route.security,
            isOpen: route.isOpen
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

    private func cloudflaredIssue(from output: String, previousLog: String?) -> String? {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let errorIndex = lines.firstIndex(where: isCloudflaredErrorLine) else {
            return nil
        }

        let errorLine = lines[errorIndex]
        let previousLine: String? = {
            if errorIndex > lines.startIndex {
                return lines[lines.index(before: errorIndex)]
            }
            return previousLog?
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .last { !$0.isEmpty }
        }()

        let message = cloudflaredErrorMessage(from: errorLine)

        if let previousLine, previousLine != errorLine {
            return "cloudflared: \(previousLine)\ncloudflared: \(message)"
        }
        return "cloudflared: \(message)"
    }

    private func cloudflaredRetryIssue(from output: String) -> String {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let retryLine = lines.last { $0.contains("Retrying connection in") }
        let errorLine = lines.first { line in
            line.contains("context canceled") ||
            line.contains("control stream encountered a failure") ||
            line.contains("failed to serve tunnel connection") ||
            line.contains("Serve tunnel error") ||
            line.contains("Connection terminated")
        }

        if let retryLine, let errorLine, retryLine != errorLine {
            return "cloudflared: \(cloudflaredErrorMessage(from: errorLine))\ncloudflared: \(retryLine)"
        }
        if let retryLine {
            return "cloudflared: \(retryLine)"
        }
        if let errorLine {
            return "cloudflared: \(cloudflaredErrorMessage(from: errorLine))"
        }
        return "cloudflared connection retrying"
    }

    private func recentCloudflaredIssueFromLogs() -> String? {
        let lines = logs
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("cloudflared exited with status") }

        guard let errorIndex = lines.lastIndex(where: isCloudflaredErrorLine) else {
            return nil
        }

        let errorLine = lines[errorIndex]
        let previousLine = errorIndex > lines.startIndex ? lines[lines.index(before: errorIndex)] : nil
        let message = cloudflaredErrorMessage(from: errorLine)

        if let previousLine, previousLine != errorLine {
            return "cloudflared: \(previousLine)\ncloudflared: \(message)"
        }
        return "cloudflared: \(message)"
    }

    private func combinedCloudflaredIssue(error: String?, exitIssue: String) -> String {
        guard let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return exitIssue
        }
        return error.contains(exitIssue) ? error : "\(error)\n\(exitIssue)"
    }

    private func isCloudflaredErrorLine(_ line: String) -> Bool {
        line.contains(" ERR ") || line.hasSuffix(" ERR") || line.contains(" ERR\t") || line.contains(" ERR:")
    }

    private func cloudflaredErrorMessage(from errorLine: String) -> String {
        if let range = errorLine.range(of: " ERR ") {
            return String(errorLine[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = errorLine.range(of: " ERR\t") {
            return String(errorLine[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let range = errorLine.range(of: " ERR:") {
            return String(errorLine[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return errorLine
    }
}

struct NativeMenuContentView: View {
    @ObservedObject var model: TunnelBarViewModel

    var body: some View {
        Section("Routing") {
            primaryRouteItems
            if hasMoreRoutes {
                Menu("More") {
                    allRouteItems
                }
            }
        }
        Divider()
        Button {
            openRoutesWindow()
        } label: {
            Label("Open routingflare", systemImage: "macwindow")
        }
        Button {
            openSettingsWindow()
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        Button {
            openAboutTab()
        } label: {
            Label("About", systemImage: "info.circle")
        }
        Divider()
        Button(action: model.quit) {
            Label("Quit routingflare", systemImage: "power")
        }
    }

    @ViewBuilder
    private var primaryRouteItems: some View {
        if model.allQuickRoutes.isEmpty && model.allDNSRoutes.isEmpty {
            Button {
                openRoutesWindow()
            } label: {
                Label("Add route...", systemImage: "plus.circle")
            }
        } else {
            ForEach(model.allQuickRoutes.prefix(2), id: \.self) { route in
                Button {
                    openRouteSecurity(route, kind: .quickURL)
                } label: {
                    routeMenuLabel(forQuickRoute: route)
                }
            }
            ForEach(model.allDNSRoutes.prefix(2), id: \.self) { route in
                Button {
                    openRouteSecurity(route, kind: .dns)
                } label: {
                    routeMenuLabel(forDNSRoute: route)
                }
            }
        }
    }

    @ViewBuilder
    private var allRouteItems: some View {
        ForEach(model.allQuickRoutes, id: \.self) { route in
            Button {
                openRouteSecurity(route, kind: .quickURL)
            } label: {
                routeMenuLabel(forQuickRoute: route)
            }
        }
        ForEach(model.allDNSRoutes, id: \.self) { route in
            Button {
                openRouteSecurity(route, kind: .dns)
            } label: {
                routeMenuLabel(forDNSRoute: route)
            }
        }
    }

    private var totalRouteCount: Int {
        model.allQuickRoutes.count + model.allDNSRoutes.count
    }

    private var hasMoreRoutes: Bool {
        model.allQuickRoutes.count > 2 || model.allDNSRoutes.count > 2
    }

    private func dnsRouteFrom(_ route: LocalProxyRoute) -> String {
        "\(route.hostname)\(route.targetPath == "/" ? "" : route.targetPath)"
    }

    private func routeMenuLabel(forQuickRoute route: LocalProxyRoute) -> some View {
        Text(routeMenuTitle(
            from: model.quickRouteFrom(route),
            to: "127.0.0.1:\(route.targetPort)",
            status: quickRouteStatus(route)
        ))
    }

    private func routeMenuLabel(forDNSRoute route: LocalProxyRoute) -> some View {
        Text(routeMenuTitle(
            from: dnsRouteFrom(route),
            to: "127.0.0.1:\(route.targetPort)",
            status: dnsRouteStatus(route)
        ))
    }

    private func routeMenuTitle(from: String, to: String, status: RouteMenuStatus) -> AttributedString {
        var dot = AttributedString("● ")
        dot.foregroundColor = status.color

        var title = AttributedString(from)
        title.foregroundColor = .primary
        dot.append(title)

        var target = AttributedString("\n\(status.title) · to \(to)")
        target.font = .caption
        target.foregroundColor = .secondary

        dot.append(target)
        return dot
    }

    private func quickRouteStatus(_ route: LocalProxyRoute) -> RouteMenuStatus {
        guard route.isOpen else {
            return .stopped
        }
        if model.quickProxyIssue(for: route) != nil { return .error }
        if model.quickRouteIsPending(route) {
            return .pending
        }
        if model.quickRouteIsOpen(route) && !model.requiresRestart {
            return .opened
        }
        return model.requiresRestart ? .restartRequired : .stopped
    }

    private func dnsRouteStatus(_ route: LocalProxyRoute) -> RouteMenuStatus {
        guard route.isOpen else {
            return .stopped
        }
        if model.dnsUnavailableReason != nil {
            return model.runningModes.contains(.dns) ? .degraded : .error
        }
        if model.runningModes.contains(.dns) && !model.requiresRestart {
            return .opened
        }
        return model.requiresRestart ? .restartRequired : .stopped
    }

    private func openRoutesWindow() {
        model.selectedTab = .routes
        RoutingFlareWindowPresenter.shared.show(model: model)
    }

    private func openSettingsWindow() {
        model.selectedTab = .options
        RoutingFlareWindowPresenter.shared.show(model: model)
    }

    private func openRouteSecurity(_ route: LocalProxyRoute, kind: TunnelMode) {
        model.selectRouteForSecurity(route, kind: kind)
        model.selectedTab = .routes
        RoutingFlareWindowPresenter.shared.show(model: model)
    }

    private func openAboutTab() {
        model.selectedTab = .about
        RoutingFlareWindowPresenter.shared.show(model: model)
    }
}

private enum RouteMenuStatus {
    case opened
    case degraded
    case pending
    case restartRequired
    case error
    case stopped

    var title: String {
        switch self {
        case .opened:
            return "Opened"
        case .degraded:
            return "Retrying"
        case .pending:
            return "Fetching"
        case .restartRequired:
            return "Restart needed"
        case .error:
            return "Error"
        case .stopped:
            return "Closed"
        }
    }

    var color: Color {
        switch self {
        case .opened:
            return .green
        case .degraded, .pending, .restartRequired, .error:
            return .orange
        case .stopped:
            return .secondary
        }
    }
}

@MainActor
private final class RoutingFlareWindowPresenter {
    static let shared = RoutingFlareWindowPresenter()

    private var window: NSWindow?

    func show(model: TunnelBarViewModel) {
        if let window {
            bringToFront(window)
            return
        }

        let hostingController = NSHostingController(
            rootView: AppWindowView(model: model)
                .frame(minWidth: 980, minHeight: 660)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "routingflare"
        window.setContentSize(NSSize(width: 980, height: 660))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        window.delegate = WindowCloseDelegate.shared
        WindowCloseDelegate.shared.onClose = { [weak self] in
            self?.window = nil
        }
        self.window = window
        bringToFront(window)
    }

    func bringToFront() {
        guard let window else { return }
        bringToFront(window)
    }

    private func bringToFront(_ window: NSWindow) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.unhide(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.deminiaturize(nil)
        window.level = .normal
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
    }
}

@MainActor
private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowCloseDelegate()
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private struct AboutPanelView: View {
    @ObservedObject var model: TunnelBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            aboutMeSection
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
                    .disabled(model.updateStatus == .checking || model.updateStatus == .downloading || model.updateStatus == .installing)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var koFiButton: some View {
        Button {
            model.openKoFiPage()
        } label: {
            Group {
                if let image = NSImage(named: "KoFiButton") {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    coffeeFallbackLabel
                }
            }
            .frame(width: 183, height: 36)
            .accessibilityLabel("Buy Me a Coffee at ko-fi.com")
        }
        .buttonStyle(.borderless)
    }

    private var coffeeFallbackLabel: some View {
        Text("Buy me a coffee")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: 183, height: 36)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6))
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
            .disabled(model.updateStatus == .checking || model.updateStatus == .downloading || model.updateStatus == .installing)
        }
    }

    private var projectLinkRow: some View {
        linkRow("Project", TunnelBarViewModel.projectPageURL.absoluteString, TunnelBarViewModel.projectPageURL)
    }

    private var aboutMeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About me")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text("I'm Gyumin Hwangbo. I build small developer tools for faster local testing, QA, and deployment workflows.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(TunnelBarViewModel.aboutMeURL.absoluteString, destination: TunnelBarViewModel.aboutMeURL)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
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
        case .installing:
            return "Installing update. routingflare will restart automatically."
        case .downloaded:
            return "Update downloaded. Open the DMG to install."
        }
    }

    private var shouldShowInstallUpdate: Bool {
        switch model.updateStatus {
        case .available, .downloaded:
            return true
        case .idle, .checking, .current, .failed, .downloading, .installing:
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

    private func linkRow(_ title: String, _ label: String, _ url: URL) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)
            Link(label, destination: url)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }
}

struct AppWindowView: View {
    @ObservedObject var model: TunnelBarViewModel

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 190, idealWidth: 208, maxWidth: 240, maxHeight: .infinity)

            detail
                .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section {
                ForEach(AppTab.allCases) { tab in
                    Text(tab.label)
                        .font(.system(size: 14, weight: model.selectedTab == tab ? .semibold : .regular))
                        .tag(tab)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.72))
    }

    private var sidebarSelection: Binding<AppTab?> {
        Binding(
            get: { model.selectedTab },
            set: { newTab in
                guard let newTab else { return }
                model.selectTab(newTab)
            }
        )
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 18) {
            detailHeader

            ScrollView(.vertical) {
                MenuContentView(
                    model: model,
                    showsHeader: false,
                    showsRoutes: false,
                    showsTabs: false,
                    showsFooter: false
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 34)
        .padding(.horizontal, 34)
        .padding(.bottom, 28)
    }

    private var detailHeader: some View {
        HStack(alignment: .center) {
            Text(model.selectedTab.label)
                .font(AppTypography.title)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

struct MenuContentView: View {
    @ObservedObject var model: TunnelBarViewModel
    @State private var showsAuthSecret = false
    @State private var expandedTunnelID: String?
    @State private var isShowingAddRoutePopover = false
    @State private var addRouteMode: TunnelMode = .quickURL
    var showsHeader = true
    var showsRoutes = true
    var showsTabs = true
    var showsFooter = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                header
            }
            if showsRoutes {
                routesTable
            }
            if showsTabs {
                modeControls
            }
            tabContent
            if showsFooter {
                Divider()
                footerControls
            }
        }
        .padding(showsTabs ? 16 : 0)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var routesTable: some View {
        RoutesTableView(
            model: model,
            quickRoutes: model.allQuickRoutes,
            dnsRoutes: model.allDNSRoutes,
            runningModes: model.runningModes,
            requiresRestart: model.requiresRestart,
            dnsUnavailableReason: model.dnsUnavailableReason,
            quickRouteFrom: { model.quickRouteFrom($0) },
            quickRouteIsOpen: { model.quickRouteIsOpen($0) },
            quickRouteIsPending: { model.quickRouteIsPending($0) },
            dnsRouteIsOpen: { model.dnsRouteIsOpen($0) },
            selectQuickRoute: { model.selectRouteForSecurity($0, kind: .quickURL) },
            selectDNSRoute: { model.selectRouteForSecurity($0, kind: .dns) },
            toggleQuickRoute: { model.toggleQuickRoute($0) },
            toggleDNSRoute: { model.toggleDNSRoute($0) },
            removeQuickRoute: { model.removeQuickRoute($0) },
            removeDNSRoute: { model.removeDNSRoute($0) },
            tableHeight: showsTabs ? 120 : nil
        )
    }

    @ViewBuilder
    private var tabContent: some View {
        if model.selectedTab == .routes {
            tunnelConfigurationsTable
        } else if model.selectedTab == .options {
            optionsControls
        } else if model.selectedTab == .logs {
            logsView
        } else if model.selectedTab == .about {
            AboutPanelView(model: model)
        }
    }

    private var tunnelConfigurationsTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                Text("Tunnels")
                    .font(AppTypography.sectionTitle)
                Spacer()
                Button {
                    addRouteMode = .quickURL
                    isShowingAddRoutePopover = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Add a tunnel route")
                .sheet(isPresented: $isShowingAddRoutePopover) {
                    AddRoutePopoverView(
                        model: model,
                        mode: $addRouteMode,
                        isPresented: $isShowingAddRoutePopover
                    )
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("Name")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Status")
                        .frame(width: 92, alignment: .leading)
                    Text("Replicas")
                        .frame(width: 72, alignment: .leading)
                    Text("Routes")
                        .frame(width: 240, alignment: .leading)
                }
                .font(AppTypography.meta)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if model.tunnelConfigurationRows.isEmpty {
                    Text("No tunnel configuration")
                        .font(AppTypography.content)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                } else {
                    ForEach(model.tunnelConfigurationRows) { row in
                        VStack(alignment: .leading, spacing: 0) {
                            tunnelConfigurationRow(row)
                            if expandedTunnelID == row.id {
                                tunnelConfigurationDetail(row)
                            }
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.28))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func tunnelConfigurationRow(_ row: TunnelConfigurationRow) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.16)) {
                expandedTunnelID = expandedTunnelID == row.id ? nil : row.id
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(row.name)
                    .font(AppTypography.contentStrong)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(row.state.label)
                    .font(AppTypography.meta)
                    .foregroundStyle(row.state.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(row.state.color.opacity(0.13))
                    .clipShape(Capsule())
                    .frame(width: 92, alignment: .leading)

                Text(String(row.replicas))
                    .font(AppTypography.content)
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)

                if row.routes.isEmpty {
                    Text("No routes")
                        .font(AppTypography.meta)
                        .foregroundStyle(.secondary)
                        .frame(width: 240, alignment: .leading)
                } else {
                    Text(row.routes.count == 1 ? "1 route" : "\(row.routes.count) routes")
                        .font(AppTypography.meta)
                        .foregroundStyle(.primary)
                        .frame(width: 240, alignment: .leading)
                        .help(row.routes.joined(separator: "\n"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            Divider()
                .opacity(0.45)
        }
    }

    private func tunnelConfigurationDetail(_ row: TunnelConfigurationRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            detailLine("Status", row.state.label)
            detailLine("Replicas", String(row.replicas))
            detailLine("cloudflared", model.currentCloudflaredPath)

            if row.id == "dns" {
                let tunnelID = model.settings.dnsTunnelID.trimmingCharacters(in: .whitespacesAndNewlines)
                let credentials = model.settings.dnsCredentialsFile.trimmingCharacters(in: .whitespacesAndNewlines)
                detailLine("Type", "cloudflared")
                detailLine("Tunnel ID", tunnelID.isEmpty ? "Not configured" : tunnelID)
                detailLine("Credentials", credentials.isEmpty ? "Not configured" : credentials)
                if let configPath = model.currentDNSConfigPath {
                    detailLine("Runtime config", configPath)
                }
            } else {
                detailLine("Type", "Quick Tunnel")
                detailLine("Address", row.routes.isEmpty ? "Not assigned" : row.routes.joined(separator: ", "))
            }

            if !row.routes.isEmpty {
                detailLine("Routes", row.routes.joined(separator: ", "))
            }

            tunnelRouteList(for: row.id)
        }
        .font(AppTypography.meta)
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.bottom, 12)
        .textSelection(.enabled)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.16))
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(value)
        }
    }

    @ViewBuilder
    private func tunnelRouteList(for tunnelID: String) -> some View {
        let isQuick = tunnelID == "quick"
        let routes = isQuick ? model.allQuickRoutes : model.allDNSRoutes

        VStack(alignment: .leading, spacing: 7) {
            Text("Routes")
                .font(AppTypography.contentStrong)
                .foregroundStyle(.primary)

            ForEach(routes, id: \.self) { route in
                let selected = model.selectedSecurityRouteKind == (isQuick ? .quickURL : .dns) &&
                    model.selectedSecurityRoute == route
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Button {
                            model.selectRouteForSecurity(route, kind: isQuick ? .quickURL : .dns)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(tunnelRouteDotColor(route, isQuick: isQuick))
                                    .frame(width: 7, height: 7)
                                Text(tunnelRouteName(route, isQuick: isQuick))
                                    .font(AppTypography.content)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 10)
                                Text("127.0.0.1:\(route.targetPort)")
                                    .font(AppTypography.meta)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Toggle("", isOn: Binding(
                            get: { route.isOpen },
                            set: { _ in
                                if isQuick {
                                    model.toggleQuickRoute(route)
                                } else {
                                    model.toggleDNSRoute(route)
                                }
                            }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.mini)

                        Button {
                            if isQuick {
                                model.removeQuickRoute(route)
                            } else {
                                model.removeDNSRoute(route)
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)

                    if selected {
                        RouteSecurityInlineView(model: model)
                            .padding(.leading, 16)
                    }
                }
                .background(selected ? Color.accentColor.opacity(0.12) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.top, 8)
    }

    private func tunnelRouteName(_ route: LocalProxyRoute, isQuick: Bool) -> String {
        if isQuick {
            return model.quickRouteFrom(route)
        }
        return "\(route.hostname)\(route.targetPath == "/" ? "" : route.targetPath)"
    }

    private func tunnelRouteDotColor(_ route: LocalProxyRoute, isQuick: Bool) -> Color {
        if !route.isOpen {
            return .secondary
        }
        if isQuick {
            if model.quickRouteIsPending(route) {
                return .orange
            }
            return model.quickRouteIsOpen(route) ? .green : .orange
        }
        if model.dnsUnavailableReason != nil {
            return .orange
        }
        return model.dnsRouteIsOpen(route) ? .green : .orange
    }

    private var header: some View {
        HStack {
            Label(model.status.label, systemImage: model.status.systemImage)
                .font(AppTypography.sectionTitle)
            Spacer()
            Text(model.allowlistSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var quickRouteForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageSectionHeader(
                "Add Random DNS",
                note: "Reopening a closed random DNS route creates a new public address."
            )
            HStack(spacing: 10) {
                TextField("8989", text: $model.newQuickPortText)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.content)
                    .frame(width: 104)
                    .onChange(of: model.newQuickPortText) { _, value in
                        model.newQuickPortText = digitsOnly(value)
                    }
                TextField("/console", text: $model.newQuickPathText)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.content)
                    .onSubmit(addQuickRouteAndShowRouting)
                Button(action: addQuickRouteAndShowRouting) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(width: 38)
            }
            .frame(maxWidth: .infinity)
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
        VStack(alignment: .leading, spacing: 10) {
            pageSectionHeader("Tunnel", note: nil)
            TextField("Tunnel ID, e.g. 24c83c3f-...", text: $model.settings.dnsTunnelID)
                .textFieldStyle(.roundedBorder)
                .font(AppTypography.content)
                .onSubmit(model.saveSettings)
            TextField("Credentials file, e.g. ~/.cloudflared/<id>.json", text: $model.settings.dnsCredentialsFile)
                .textFieldStyle(.roundedBorder)
                .font(AppTypography.content)
                .onSubmit(model.saveSettings)
        }
    }

    private var dnsRouteForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            pageSectionHeader("Add DNS", note: nil)
            HStack(spacing: 10) {
                TextField("dev.example.com", text: $model.newDNSHostname)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.content)
                    .frame(minWidth: 180)
                TextField("8989", text: $model.newDNSPortText)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.content)
                    .frame(width: 104)
                    .onChange(of: model.newDNSPortText) { _, value in
                        model.newDNSPortText = digitsOnly(value)
                    }
                TextField("/console", text: $model.newDNSPathText)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.content)
                    .frame(minWidth: 150)
                Button(action: addDNSRouteAndShowRouting) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(width: 38)
                .disabled(!model.canAddDNSRoute)
            }
        }
    }

    private func pageSectionHeader(_ title: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppTypography.sectionTitle)
                .foregroundStyle(.primary)
            if let note {
                Text(note)
                    .font(AppTypography.meta)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addQuickRouteAndShowRouting() {
        if model.addQuickRoute() {
            model.selectedTab = .routes
        }
    }

    private func addDNSRouteAndShowRouting() {
        if model.addDNSRoute() {
            model.selectedTab = .routes
        }
    }

    private func digitsOnly(_ value: String) -> String {
        String(value.filter(\.isNumber).prefix(5))
    }

    private var allowlistControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inbound IP Allowlist")
                .font(AppTypography.sectionTitle)
                .foregroundStyle(.secondary)
            HStack {
                TextField("203.0.113.10 or 198.51.100.0/24", text: $model.newAllowlistEntry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(model.addAllowlistEntry)
                Button(action: model.addAllowlistEntry) {
                    Image(systemName: "plus")
                }
            }
            ForEach(model.selectedRouteSecurity.allowlistEntries, id: \.self) { entry in
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
            if model.selectedSecurityRoute == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Route Security")
                        .font(AppTypography.sectionTitle)
                    Text("Select a route from the routing table.")
                        .font(AppTypography.content)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Route Security")
                        .font(AppTypography.sectionTitle)
                    Text(model.selectedRouteDisplayName)
                        .font(AppTypography.content)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                allowlistControls
                authHeaderControls
            }
        }
        .onAppear {
            model.loadAuthHeaderSecretIfNeeded()
        }
    }

    private var optionsControls: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                pageSectionHeader("Startup", note: nil)
                Toggle("Start routes when routingflare opens", isOn: $model.settings.autoStart)
                    .font(AppTypography.content)
                    .onChange(of: model.settings.autoStart) { _, _ in model.saveSettings() }
            }
            installControls
        }
    }

    private var authHeaderControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Auth Header", isOn: Binding(
                get: { model.routeAuthHeaderEnabledDraft },
                set: { model.setSelectedAuthHeaderEnabled($0) }
            ))
            TextField("Header name", text: Binding(
                get: { model.routeAuthHeaderNameDraft },
                set: { model.setSelectedAuthHeaderName($0) }
            ))
                .textFieldStyle(.roundedBorder)
                .disabled(!model.routeAuthHeaderEnabledDraft)
                .onSubmit(model.saveAuthHeaderSettings)
            HStack(spacing: 6) {
                if showsAuthSecret {
                    TextField("Secret", text: Binding(
                        get: { model.authHeaderSecret },
                        set: { model.updateAuthHeaderSecretDraft($0) }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.routeAuthHeaderEnabledDraft)
                        .onSubmit(model.saveAuthHeaderSettings)
                } else {
                    SecureField("Secret", text: Binding(
                        get: { model.authHeaderSecret },
                        set: { model.updateAuthHeaderSecretDraft($0) }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.routeAuthHeaderEnabledDraft)
                        .onSubmit(model.saveAuthHeaderSettings)
                }
                Button {
                    showsAuthSecret.toggle()
                } label: {
                    Image(systemName: showsAuthSecret ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .disabled(!model.routeAuthHeaderEnabledDraft)
                .help(showsAuthSecret ? "Hide secret" : "Show secret")
            }
            Button(action: model.saveAuthHeaderSettings) {
                Label(model.routeAuthSavedRecently ? "Saved Auth Header" : "Save Auth Header", systemImage: "key.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(model.routeAuthHeaderHasChanges ? .accentColor : .secondary)
            .disabled(!model.routeAuthHeaderHasChanges)
        }
    }

    private var footerControls: some View {
        HStack(spacing: 10) {
            Spacer()
            Button {
                model.selectedTab = .about
            } label: {
                Label("About", systemImage: "info.circle")
            }
            .buttonStyle(.plain)
            Button("Quit", action: model.quit)
        }
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
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                Text(model.logs.suffix(20).joined(separator: "\n"))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 420)
        }
    }
}

private struct AddRoutePopoverView: View {
    @ObservedObject var model: TunnelBarViewModel
    @Binding var mode: TunnelMode
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $mode) {
                Text("Random DNS").tag(TunnelMode.quickURL)
                Text("DNS").tag(TunnelMode.dns)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .quickURL {
                randomDNSForm
            } else {
                dnsForm
            }
        }
        .padding(16)
        .frame(width: 620)
    }

    private var randomDNSForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(
                "Random DNS",
                note: "Creates a temporary trycloudflare.com address. Reopening a closed route creates a new address."
            )
            HStack(spacing: 10) {
                portField(text: $model.newQuickPortText)
                TextField("/console", text: $model.newQuickPathText)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.content)
                    .onSubmit(addRandomDNS)
                formActions(addAction: addRandomDNS, addDisabled: false)
            }
        }
    }

    private var dnsForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Tunnel", note: nil)
                TextField("Tunnel ID, e.g. 24c83c3f-...", text: $model.settings.dnsTunnelID)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.content)
                    .onSubmit(model.saveSettings)
                TextField("Credentials file, e.g. ~/.cloudflared/<id>.json", text: $model.settings.dnsCredentialsFile)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.content)
                    .onSubmit(model.saveSettings)
            }

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("DNS route", note: nil)
                HStack(spacing: 10) {
                    TextField("dev.example.com", text: $model.newDNSHostname)
                        .textFieldStyle(.roundedBorder)
                        .font(AppTypography.content)
                    portField(text: $model.newDNSPortText)
                    TextField("/console", text: $model.newDNSPathText)
                        .textFieldStyle(.roundedBorder)
                        .font(AppTypography.content)
                    formActions(addAction: addDNS, addDisabled: !model.canAddDNSRoute)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AppTypography.sectionTitle)
            if let note {
                Text(note)
                    .font(AppTypography.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func portField(text: Binding<String>) -> some View {
        TextField("8989", text: text)
            .textFieldStyle(.roundedBorder)
            .font(AppTypography.content)
            .frame(width: 96)
            .onChange(of: text.wrappedValue) { _, value in
                text.wrappedValue = String(value.filter(\.isNumber).prefix(5))
            }
    }

    private func formActions(addAction: @escaping () -> Void, addDisabled: Bool) -> some View {
        HStack(spacing: 8) {
            Button("Cancel") {
                isPresented = false
            }
            .buttonStyle(.bordered)
            Button("Add", action: addAction)
                .buttonStyle(.borderedProminent)
                .disabled(addDisabled)
        }
    }

    private func addRandomDNS() {
        if model.addQuickRoute() {
            model.selectedTab = .routes
            isPresented = false
        }
    }

    private func addDNS() {
        if model.addDNSRoute() {
            model.selectedTab = .routes
            isPresented = false
        }
    }
}

private struct RoutesTableView: View {
    @State private var copiedValue: String?

    @ObservedObject var model: TunnelBarViewModel
    let quickRoutes: [LocalProxyRoute]
    let dnsRoutes: [LocalProxyRoute]
    let runningModes: Set<TunnelMode>
    let requiresRestart: Bool
    let dnsUnavailableReason: String?
    let quickRouteFrom: (LocalProxyRoute) -> String
    let quickRouteIsOpen: (LocalProxyRoute) -> Bool
    let quickRouteIsPending: (LocalProxyRoute) -> Bool
    let dnsRouteIsOpen: (LocalProxyRoute) -> Bool
    let selectQuickRoute: (LocalProxyRoute) -> Void
    let selectDNSRoute: (LocalProxyRoute) -> Void
    let toggleQuickRoute: (LocalProxyRoute) -> Void
    let toggleDNSRoute: (LocalProxyRoute) -> Void
    let removeQuickRoute: (LocalProxyRoute) -> Void
    let removeDNSRoute: (LocalProxyRoute) -> Void
    let tableHeight: CGFloat?

    private let statusColumnWidth: CGFloat = 16
    private let targetColumnWidth: CGFloat = 178
    private let toggleColumnWidth: CGFloat = 48
    private let actionColumnWidth: CGFloat = 30
    private let columnSpacing: CGFloat = 14
    private let tableInset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            tableHeader
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if quickRoutes.isEmpty && dnsRoutes.isEmpty {
                        emptyState
                    } else {
                        ForEach(quickRoutes, id: \.self) { route in
                            VStack(alignment: .leading, spacing: 0) {
                                routeRow(
                                    from: quickRouteFrom(route),
                                    port: route.targetPort,
                                    isRouteEnabled: route.isOpen,
                                    isActive: quickRouteIsOpen(route),
                                    isPending: quickRouteIsPending(route),
                                    statusText: route.isOpen ? nil : "Closed. Reopen assigns a new random DNS address.",
                                    isSelected: isExpanded(route, kind: .quickURL),
                                    select: { selectQuickRoute(route) },
                                    toggle: { toggleQuickRoute(route) },
                                    remove: { removeQuickRoute(route) }
                                )
                                if isExpanded(route, kind: .quickURL) {
                                    RouteSecurityInlineView(model: model)
                                }
                            }
                        }

                        ForEach(dnsRoutes, id: \.self) { route in
                            VStack(alignment: .leading, spacing: 0) {
                                routeRow(
                                    from: "\(route.hostname)\(displayPath(route.targetPath))",
                                    port: route.targetPort,
                                    isRouteEnabled: route.isOpen,
                                    isActive: dnsRouteIsOpen(route),
                                    isPending: route.isOpen && dnsUnavailableReason != nil,
                                    statusText: route.isOpen ? dnsUnavailableReason : "Closed",
                                    isSelected: isExpanded(route, kind: .dns),
                                    select: { selectDNSRoute(route) },
                                    toggle: { toggleDNSRoute(route) },
                                    remove: { removeDNSRoute(route) }
                                )
                                if isExpanded(route, kind: .dns) {
                                    RouteSecurityInlineView(model: model)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: tableHeight == nil ? .infinity : nil,
                alignment: .topLeading
            )
            .frame(height: tableHeight)
        }
        .frame(maxWidth: .infinity, maxHeight: tableHeight == nil ? .infinity : nil, alignment: .topLeading)
        .onDisappear {
            hideTooltip()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No routes yet")
                .font(AppTypography.sectionTitle)
            Text("Add a random DNS route or DNS route.")
                .font(AppTypography.content)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(86, (tableHeight ?? 180) - 8))
    }

    private var tableHeader: some View {
        HStack(spacing: columnSpacing) {
            Text("")
                .frame(width: statusColumnWidth)
            Text("From")
                .font(AppTypography.meta)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("To")
                .font(AppTypography.meta)
                .foregroundStyle(.tertiary)
                .frame(width: targetColumnWidth, alignment: .leading)
            Text("")
                .frame(width: toggleColumnWidth)
            Text("")
                .frame(width: actionColumnWidth)
        }
        .padding(.horizontal, tableInset)
        .padding(.bottom, 2)
    }

    private func routeRow(
        from: String,
        port: Int,
        isRouteEnabled: Bool,
        isActive: Bool,
        isPending: Bool,
        statusText: String?,
        isSelected: Bool,
        select: @escaping () -> Void,
        toggle: @escaping () -> Void,
        remove: @escaping () -> Void
    ) -> some View {
        let target = "127.0.0.1:\(String(port))"
        return HStack(spacing: 0) {
            Button(action: select) {
                HStack(spacing: columnSpacing) {
                    Circle()
                        .fill(routeDotColor(isActive: isActive, isPending: isPending))
                        .frame(width: 8, height: 8)
                        .frame(width: statusColumnWidth)
                    VStack(alignment: .leading, spacing: 2) {
                        routeLineText(from, width: nil, truncationMode: .middle, primary: true)
                        if let statusText {
                            tooltippedText(
                                statusText,
                                width: nil,
                                truncationMode: .tail,
                                font: AppTypography.meta,
                                foregroundStyle: .orange,
                                copyable: false
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    routeLineText(target, width: targetColumnWidth, truncationMode: .tail, primary: false)
                }
                .padding(.leading, tableInset)
                .padding(.trailing, columnSpacing)
                .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: Binding(
                get: { isRouteEnabled },
                set: { _ in toggle() }
            ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: toggleColumnWidth)
                .help(isRouteEnabled ? "Close this route" : "Open this route")

            Button(action: remove) {
                Image(systemName: "minus.circle")
                    .font(AppTypography.content)
            }
            .buttonStyle(.plain)
            .frame(width: actionColumnWidth, height: 28)
            .padding(.trailing, tableInset)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .contentShape(Rectangle())
    }

    private func isExpanded(_ route: LocalProxyRoute, kind: TunnelMode) -> Bool {
        model.selectedSecurityRouteKind == kind && model.selectedSecurityRoute == route
    }

    private func routeLineText(_ value: String, width: CGFloat?, truncationMode: Text.TruncationMode, primary: Bool) -> some View {
        tooltippedText(
            value,
            width: width,
            truncationMode: truncationMode,
            font: AppTypography.contentStrong,
            foregroundStyle: primary ? .primary : .secondary,
            copyable: false
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
            .onHover { hovering in
                if hovering {
                    scheduleTooltip(text: value)
                } else {
                    hideTooltip()
                }
            }
    }

    private func scheduleTooltip(text: String) {
        HoverTooltipPresenter.shared.schedule(text: text)
    }

    private func hideTooltip() {
        HoverTooltipPresenter.shared.hide()
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

private struct RouteSecurityInlineView: View {
    @ObservedObject var model: TunnelBarViewModel
    @State private var showsSecret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            selectedRouteSummary
            allowlist
            authHeader
        }
        .padding(.leading, 42)
        .padding(.trailing, 88)
        .padding(.vertical, 14)
    }

    private var selectedRouteSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected route")
                .font(AppTypography.contentStrong)
                .foregroundStyle(.primary)
            selectablePair("URL", model.selectedRouteDisplayName)
            if let route = model.selectedSecurityRoute {
                selectablePair("To", "127.0.0.1:\(route.targetPort)")
            }
        }
    }

    private func selectablePair(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(AppTypography.meta)
                .foregroundStyle(.tertiary)
                .frame(width: 34, alignment: .leading)
            Text(value)
                .font(AppTypography.content)
                .foregroundStyle(.primary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private var allowlist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inbound IP Allowlist")
                .font(AppTypography.contentStrong)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("203.0.113.10 or 198.51.100.0/24", text: $model.newAllowlistEntry)
                    .textFieldStyle(.roundedBorder)
                    .font(AppTypography.content)
                    .onSubmit(model.addAllowlistEntry)
                Button(action: model.addAllowlistEntry) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .frame(width: 36)
            }
            if model.selectedRouteSecurity.allowlistEntries.isEmpty {
                Text("Allow all inbound IPs")
                    .font(AppTypography.meta)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.selectedRouteSecurity.allowlistEntries, id: \.self) { entry in
                    HStack {
                        Text(entry)
                            .font(AppTypography.content)
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
    }

    private var authHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Auth Header", isOn: Binding(
                get: { model.routeAuthHeaderEnabledDraft },
                set: { model.setSelectedAuthHeaderEnabled($0) }
            ))
            .font(AppTypography.contentStrong)

            TextField("Header name", text: Binding(
                get: { model.routeAuthHeaderNameDraft },
                set: { model.setSelectedAuthHeaderName($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(AppTypography.content)
            .disabled(!model.routeAuthHeaderEnabledDraft)
            .onSubmit(model.saveAuthHeaderSettings)

            HStack(spacing: 8) {
                if showsSecret {
                    TextField("Secret", text: Binding(
                        get: { model.authHeaderSecret },
                        set: { model.updateAuthHeaderSecretDraft($0) }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .font(AppTypography.content)
                        .disabled(!model.routeAuthHeaderEnabledDraft)
                        .onSubmit(model.saveAuthHeaderSettings)
                } else {
                    SecureField("Secret", text: Binding(
                        get: { model.authHeaderSecret },
                        set: { model.updateAuthHeaderSecretDraft($0) }
                    ))
                        .textFieldStyle(.roundedBorder)
                        .font(AppTypography.content)
                        .disabled(!model.routeAuthHeaderEnabledDraft)
                        .onSubmit(model.saveAuthHeaderSettings)
                }
                Button {
                    showsSecret.toggle()
                } label: {
                    Image(systemName: showsSecret ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .disabled(!model.routeAuthHeaderEnabledDraft)

                Button(model.routeAuthSavedRecently ? "Saved" : "Save", action: model.saveAuthHeaderSettings)
                    .buttonStyle(.borderedProminent)
                    .font(AppTypography.meta)
                    .tint(model.routeAuthHeaderHasChanges ? .accentColor : .secondary)
                    .disabled(!model.routeAuthHeaderHasChanges)
            }
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func hide() {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func show(text: String) {
        let measuredView = NSHostingView(rootView: TooltipBubble(text: text, width: nil))
        let measuredSize = measuredView.fittingSize
        let width = min(max(measuredSize.width, 44), 340)
        let hostingView = NSHostingView(rootView: TooltipBubble(text: text, width: width))
        let fittingSize = hostingView.fittingSize
        let size = NSSize(
            width: min(max(fittingSize.width, 44), 340),
            height: min(max(fittingSize.height, 32), 220)
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
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let mouse = NSEvent.mouseLocation
        let visibleFrame = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? .zero
        var origin = NSPoint(x: mouse.x + 14, y: mouse.y - size.height - 12)
        origin.x = min(max(origin.x, visibleFrame.minX + 4), visibleFrame.maxX - size.width - 4)
        origin.y = min(max(origin.y, visibleFrame.minY + 4), visibleFrame.maxY - size.height - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
    }
}

private struct TooltipBubble: View {
    let text: String
    let width: CGFloat?

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.primary)
            .lineLimit(8)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }
}
