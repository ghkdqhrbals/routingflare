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
            return "exclamationmark.triangle.fill"
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

enum AppTab: String, CaseIterable, Identifiable {
    case quickURL
    case dns
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .quickURL:
            return "Quick URL"
        case .dns:
            return "DNS"
        case .settings:
            return "Settings"
        }
    }

    var tunnelMode: TunnelMode? {
        switch self {
        case .quickURL:
            return .quickURL
        case .dns:
            return .dns
        case .settings:
            return nil
        }
    }
}

@MainActor
final class TunnelBarViewModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var selectedTab: AppTab
    @Published var status: TunnelStatus = .stopped
    @Published var publicURL: URL?
    @Published var proxyPort: Int?
    @Published var requiresRestart = false
    @Published var logs: [String] = []
    @Published var newAllowlistEntry = ""
    @Published var newDNSHostname = ""
    @Published var newDNSPortText = "3000"
    @Published var newQuickPortText = "3000"
    @Published var newTargetPath = ""
    @Published var installInProgress = false

    private let settingsStore: SettingsStoring
    private let secretStore: SecretStoring
    private let tunnelProcess = TunnelProcess()
    private let accessPolicy: MutableProxyAccessPolicy
    private var proxy: LocalFilteringProxy?
    private var cloudflaredConfigURL: URL?
    private var activeTunnelMode: TunnelMode?

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
        self.settings = loaded
        self.accessPolicy = MutableProxyAccessPolicy(allowlistEntries: loaded.allowlistEntries)
    }

    var canStart: Bool {
        activeTargetPort > 0 &&
        activeTargetPort <= 65535 &&
        hasCloudflared &&
        ((settings.mode == .quickURL && !activeQuickRoutes.isEmpty) || canStartDNS)
    }

    var hasCloudflared: Bool {
        !effectiveCloudflaredPath.isEmpty
    }

    private var canStartDNS: Bool {
        !activeDNSRoutes.isEmpty &&
        !settings.dnsTunnelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !settings.dnsCredentialsFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var allowlistSummary: String {
        settings.allowlistEntries.isEmpty ? "Allow all inbound IPs" : "\(settings.allowlistEntries.count) allowed entries"
    }

    var runningMode: TunnelMode? {
        status.isStarted ? activeTunnelMode : nil
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
        guard let command = CloudflaredLocator().brewInstallCommand() else {
            appendLog("Homebrew was not found. Install cloudflared manually from Cloudflare or with Homebrew.")
            return
        }
        installInProgress = true
        appendLog("Running \(command.executable) \(command.arguments.joined(separator: " "))")

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
        requiresRestart = false
        status = .starting

        do {
            let proxy: LocalFilteringProxy
            let logHandler: @Sendable (String) -> Void = { [weak self] line in
                Task { @MainActor in
                    self?.appendLog(line)
                }
            }
            switch settings.mode {
            case .quickURL:
                proxy = LocalFilteringProxy(
                    routes: activeQuickRoutes,
                    fallbackTargetPort: activeTargetPort,
                    accessPolicy: accessPolicy,
                    logHandler: logHandler
                )
            case .dns:
                proxy = LocalFilteringProxy(
                    routes: activeDNSRoutes,
                    fallbackTargetPort: activeTargetPort,
                    accessPolicy: accessPolicy,
                    logHandler: logHandler
                )
            }
            let proxyPort = try proxy.start()
            self.proxyPort = proxyPort
            self.proxy = proxy

            let command: TunnelCommand
            switch settings.mode {
            case .quickURL:
                let configURL = try writeQuickTunnelConfig()
                command = TunnelCommandBuilder.quickURL(
                    cloudflaredPath: effectiveCloudflaredPath,
                    proxyPort: proxyPort,
                    configPath: configURL.path
                )
            case .dns:
                let configURL = try writeDNSConfig(proxyPort: proxyPort)
                command = TunnelCommandBuilder.dnsLocalConfig(
                    cloudflaredPath: effectiveCloudflaredPath,
                    configPath: configURL.path
                )
            }

            appendLog("Exposing local 127.0.0.1:\(activeTargetPort) through proxy 127.0.0.1:\(proxyPort)")
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
                        if self?.status != .stopped {
                            self?.status = statusCode == 0 ? .stopped : .error("cloudflared exited with status \(statusCode)")
                        }
                    }
                }
            )

            if settings.mode == .dns {
                status = .running
                if let firstURL = publicURLs.first {
                    publicURL = firstURL
                }
            }
            activeTunnelMode = settings.mode
            addRecentPort(activeTargetPort)
        } catch {
            stop()
            status = .error(error.localizedDescription)
            appendLog("Start failed: \(error.localizedDescription)")
        }
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        tunnelProcess.stop()
        proxy?.stop()
        proxy = nil
        proxyPort = nil
        if let cloudflaredConfigURL {
            try? FileManager.default.removeItem(at: cloudflaredConfigURL)
            self.cloudflaredConfigURL = nil
        }
        activeTunnelMode = nil
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
            accessPolicy.update(allowlistEntries: settings.allowlistEntries)
            newAllowlistEntry = ""
            saveSettings()
        } catch {
            appendLog(error.localizedDescription)
        }
    }

    func removeAllowlistEntry(_ entry: String) {
        settings.allowlistEntries.removeAll { $0 == entry }
        accessPolicy.update(allowlistEntries: settings.allowlistEntries)
        saveSettings()
    }

    func addDNSRoute() {
        let hostname = newDNSHostname.trimmingCharacters(in: .whitespacesAndNewlines)
        var path = newTargetPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = parsedPort(newDNSPortText), !hostname.isEmpty else { return }
        if path.isEmpty {
            path = "/"
        }
        if !path.hasPrefix("/") {
            path = "/" + path
        }
        let route = LocalProxyRoute(hostname: hostname, targetPort: port, targetPath: path)
        if !settings.dnsRoutes.contains(route) {
            settings.dnsRoutes.append(route)
            markRestartRequiredIfStarted()
        }
        newDNSHostname = ""
        newTargetPath = ""
        saveSettings()
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
        if !settings.quickRoutes.contains(route) {
            settings.quickRoutes.append(route)
        }
        newTargetPath = ""
        saveSettings()
    }

    func removeQuickRoute(_ route: LocalProxyRoute) {
        let oldCount = settings.quickRoutes.count
        settings.quickRoutes.removeAll { $0 == route }
        if settings.quickRoutes.count != oldCount {
            markRestartRequiredIfStarted()
        }
        saveSettings()
    }

    func removeDNSRoute(_ route: LocalProxyRoute) {
        let oldCount = settings.dnsRoutes.count
        settings.dnsRoutes.removeAll { $0 == route }
        if settings.dnsRoutes.count != oldCount {
            markRestartRequiredIfStarted()
        }
        saveSettings()
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

    func quit() {
        stop()
        NSApplication.shared.terminate(nil)
    }

    private var effectiveCloudflaredPath: String {
        if !settings.cloudflaredPath.isEmpty {
            return settings.cloudflaredPath
        }
        return CloudflaredLocator().find() ?? ""
    }

    private func handleTunnelOutput(_ output: String) {
        appendLog(output)
        if let parsedURL = TunnelURLParser.parsePublicURL(from: output) {
            publicURL = PublicURLBuilder.build(baseURL: parsedURL, targetPath: activeTargetPaths.first ?? "/")
            status = .running
        } else if status == .starting && settings.mode == .dns {
            status = .running
        }
    }

    private func addRecentPort(_ port: Int) {
        settings.recentPorts.removeAll { $0 == port }
        settings.recentPorts.insert(port, at: 0)
        settings.recentPorts = Array(settings.recentPorts.prefix(6))
        saveSettings()
    }

    private func markRestartRequiredIfStarted() {
        guard status.isStarted else { return }
        requiresRestart = true
    }

    private func parsedPort(_ text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        guard let port = Int(digits), port > 0, port <= 65535 else {
            return nil
        }
        return port
    }

    private func writeQuickTunnelConfig() throws -> URL {
        let configURL = try temporaryCloudflaredConfigURL()
        try "".write(to: configURL, atomically: true, encoding: .utf8)
        cloudflaredConfigURL = configURL
        appendLog("Using isolated empty cloudflared config for Quick URL mode")
        return configURL
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
        switch settings.mode {
        case .quickURL:
            guard let publicURL,
                  let base = URL(string: "\(publicURL.scheme ?? "https")://\(publicURL.host ?? publicURL.absoluteString)") else {
                return []
            }
            return activeQuickRoutes.compactMap { PublicURLBuilder.build(baseURL: base, targetPath: $0.targetPath) }
        case .dns:
            return activeDNSRoutes.compactMap { route in
                guard let baseURL = URL(string: "https://\(route.hostname)") else {
                    return nil
                }
                return PublicURLBuilder.build(baseURL: baseURL, targetPath: route.targetPath)
            }
        }
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
}

struct MenuContentView: View {
    @ObservedObject var model: TunnelBarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            actionControls
            routingList
            modeControls
            if model.selectedTab == .quickURL {
                quickRouteForm
            } else if model.selectedTab == .dns {
                dnsRouteForm
                dnsControls
            } else {
                settingsControls
            }
            logsView
            Divider()
            Button("Quit TunnelBar", action: model.quit)
        }
        .padding(16)
        .frame(minHeight: 560, alignment: .top)
        .transaction { transaction in
            transaction.animation = nil
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

    private var routingList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Routes")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(model.activeQuickRoutes, id: \.self) { route in
                routeRow(
                    title: "\(quickRoutePrefix)\(displayPath(route.targetPath))",
                    port: route.targetPort,
                    isActive: activeMode == .quickURL,
                    remove: { model.removeQuickRoute(route) }
                )
            }

            ForEach(model.activeDNSRoutes, id: \.self) { route in
                routeRow(
                    title: "\(route.hostname)\(displayPath(route.targetPath))",
                    port: route.targetPort,
                    isActive: activeMode == .dns,
                    remove: { model.removeDNSRoute(route) }
                )
            }
        }
    }

    private func routeRow(title: String, port: Int, isActive: Bool, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive && !model.requiresRestart ? .green : .secondary)
                .frame(width: 7, height: 7)
            Text("\(title) -> 127.0.0.1:\(String(port))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
        }
    }

    private var activeMode: TunnelMode? {
        model.runningMode
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

    private var quickRoutePrefix: String {
        guard let publicURL = model.publicURL, let host = publicURL.host else {
            return "Quick URL"
        }
        return host
    }

    private var modeControls: some View {
        Picker("Tab", selection: $model.selectedTab) {
            ForEach(AppTab.allCases) { tab in
                Text(tab.label).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: model.selectedTab) { _, tab in model.selectTab(tab) }
    }

    @ViewBuilder
    private var dnsControls: some View {
        if model.settings.mode == .dns {
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
            }
        }
    }

    private func displayPath(_ path: String) -> String {
        path == "/" ? "" : path
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

    private var settingsControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            allowlistControls
            installControls
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
