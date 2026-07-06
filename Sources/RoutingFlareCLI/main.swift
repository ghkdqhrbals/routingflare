import Foundation
import Darwin
import TunnelBarCore

enum CLIError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

struct RoutingFlareCLI {
    private let store = UserDefaultsSettingsStore()
    private let routeStatusStore = UserDefaultsRouteStatusStore()
    private let releaseAPIURL = URL(string: "https://api.github.com/repos/ghkdqhrbals/routingflare/releases/latest")!

    func run(_ arguments: [String]) throws {
        let command = Array(arguments.dropFirst())
        guard let first = command.first else {
            printHelp()
            return
        }

        switch first {
        case "help", "--help", "-h":
            printHelp()
        case "list", "ls":
            printList()
        case "add":
            try add(Array(command.dropFirst()))
        case "remove", "rm":
            try remove(Array(command.dropFirst()))
        case "start", "stop":
            sendAppCommand(first)
            if first == "start" {
                launchAppIfNeeded()
            }
            print("Sent \(first) to routingflare.")
        case "settings":
            try settings(Array(command.dropFirst()))
        case "security":
            try routeSecurity(Array(command.dropFirst()))
        case "update":
            try updateFromCLI()
        case "autostart":
            try setAutoStart(Array(command.dropFirst()))
        case "cloudflared":
            try setCloudflaredPath(Array(command.dropFirst()))
        default:
            throw CLIError.message("Unknown command: \(first)")
        }
    }

    private func add(_ arguments: [String]) throws {
        guard let type = arguments.first else {
            throw CLIError.message("Usage: routingflare add random|dns ...")
        }
        var settings = store.load()
        let options = parseOptions(Array(arguments.dropFirst()))

        switch type {
        case "random", "quick":
            let port = try requiredPort(options["port"], name: "port")
            let path = normalizedPath(options["path"] ?? "/")
            let route = LocalProxyRoute(hostname: "", targetPort: port, targetPath: path)
            settings.quickRoutes.removeAll { $0 == route }
            settings.quickRoutes.insert(route, at: 0)
            settings.targetPort = port
            settings.targetPath = path
            settings.targetPaths = unique([path] + settings.quickRoutes.map(\.targetPath))
            store.save(settings)
            sendAppCommand("reload")
            print("Added Random DNS route: random dns\(path == "/" ? "" : path) to 127.0.0.1:\(port)")
        case "dns":
            guard let host = options["host"]?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
                throw CLIError.message("Missing --host.")
            }
            let port = try requiredPort(options["port"], name: "port")
            let path = normalizedPath(options["path"] ?? "/")
            let route = LocalProxyRoute(hostname: host, targetPort: port, targetPath: path)
            settings.dnsRoutes.removeAll { $0 == route }
            settings.dnsRoutes.insert(route, at: 0)
            settings.dnsHostname = host
            settings.dnsHostnames = unique([host] + settings.dnsRoutes.map(\.hostname))
            settings.dnsTargetPort = port
            settings.dnsTargetPath = path
            settings.dnsTargetPaths = unique([path] + settings.dnsRoutes.map(\.targetPath))
            store.save(settings)
            sendAppCommand("reload")
            print("Added DNS route: \(host)\(path == "/" ? "" : path) -> 127.0.0.1:\(port)")
        default:
            throw CLIError.message("Unknown route type: \(type)")
        }
    }

    private func remove(_ arguments: [String]) throws {
        guard arguments.count >= 2 else {
            throw CLIError.message("Usage: routingflare remove random|dns <index>")
        }
        let type = arguments[0]
        guard let index = Int(arguments[1]), index > 0 else {
            throw CLIError.message("Index must be a positive number.")
        }

        var settings = store.load()
        switch type {
        case "random", "quick":
            try removeIndex(index, from: &settings.quickRoutes, label: "random DNS route")
        case "dns":
            try removeIndex(index, from: &settings.dnsRoutes, label: "DNS route")
            settings.dnsHostnames = unique(settings.dnsRoutes.map(\.hostname))
            settings.dnsHostname = settings.dnsHostnames.first ?? ""
        default:
            throw CLIError.message("Unknown route type: \(type)")
        }

        store.save(settings)
        sendAppCommand("reload")
    }

    private func removeIndex<T>(_ index: Int, from values: inout [T], label: String) throws {
        guard values.indices.contains(index - 1) else {
            throw CLIError.message("No \(label) at index \(index).")
        }
        values.remove(at: index - 1)
        print("Removed \(label) \(index).")
    }

    private func setAutoStart(_ arguments: [String]) throws {
        guard let value = arguments.first, ["on", "off"].contains(value) else {
            throw CLIError.message("Usage: routingflare autostart on|off")
        }
        var settings = store.load()
        settings.autoStart = value == "on"
        store.save(settings)
        sendAppCommand("reload")
        print("Auto start is \(settings.autoStart ? "on" : "off").")
    }

    private func setCloudflaredPath(_ arguments: [String]) throws {
        guard let path = arguments.first, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.message("Usage: routingflare cloudflared /path/to/cloudflared")
        }
        var settings = store.load()
        settings.cloudflaredPath = path
        store.save(settings)
        sendAppCommand("reload")
        print("cloudflared path set to \(path).")
    }

    private func settings(_ arguments: [String]) throws {
        guard let action = arguments.first else {
            printSettings()
            return
        }

        switch action {
        case "get", "show", "list":
            printSettings()
        case "set":
            try setSettings(Array(arguments.dropFirst()))
        case "allowlist":
            try updateAllowlist(Array(arguments.dropFirst()))
        case "auth":
            try updateAuthHeader(Array(arguments.dropFirst()))
        default:
            throw CLIError.message("Usage: routingflare settings get|set|allowlist|auth ...")
        }
    }

    private func printSettings() {
        let settings = store.load()

        print("Settings")
        print("  autostart: \(settings.autoStart ? "on" : "off")")
        print("  cloudflared: \(settings.cloudflaredPath.isEmpty ? "auto-detect" : settings.cloudflaredPath)")
        print("  dns tunnel id: \(settings.dnsTunnelID.isEmpty ? "-" : settings.dnsTunnelID)")
        print("  dns credentials: \(settings.dnsCredentialsFile.isEmpty ? "-" : settings.dnsCredentialsFile)")
        print("  allowlist: \(settings.allowlistEntries.isEmpty ? "allow all" : settings.allowlistEntries.joined(separator: ", "))")
        print("  auth header: \(settings.authHeaderEnabled ? "on" : "off")")
        print("  auth header name: \(settings.authHeaderName)")
        print("  auth secret: \(settings.authHeaderSecret.isEmpty ? "not set" : "set")")
    }

    private func setSettings(_ arguments: [String]) throws {
        guard !arguments.isEmpty else {
            throw CLIError.message("Usage: routingflare settings set [--autostart on|off] [--cloudflared path] [--dns-tunnel-id id] [--dns-credentials file]")
        }

        let options = parseOptions(arguments)
        var settings = store.load()
        var changed = false

        if let value = options["autostart"] {
            settings.autoStart = try boolValue(value, name: "autostart")
            changed = true
        }
        if let path = options["cloudflared"] {
            settings.cloudflaredPath = path
            changed = true
        }
        if let id = options["dns-tunnel-id"] {
            settings.dnsTunnelID = id
            changed = true
        }
        if let file = options["dns-credentials"] {
            settings.dnsCredentialsFile = file
            changed = true
        }

        guard changed else {
            throw CLIError.message("No supported settings were provided.")
        }

        store.save(settings)
        sendAppCommand("reload")
        print("Settings updated.")
    }

    private func updateAllowlist(_ arguments: [String]) throws {
        guard let action = arguments.first else {
            throw CLIError.message("Usage: routingflare settings allowlist add|remove|clear [entry]")
        }

        var settings = store.load()
        switch action {
        case "add":
            guard let entry = arguments.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines), !entry.isEmpty else {
                throw CLIError.message("Usage: routingflare settings allowlist add <ip-or-cidr>")
            }
            _ = try IPAllowlist(entries: [entry])
            if !settings.allowlistEntries.contains(entry) {
                settings.allowlistEntries.append(entry)
            }
            print("Allowlist added: \(entry)")
        case "remove", "rm":
            guard let entry = arguments.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines), !entry.isEmpty else {
                throw CLIError.message("Usage: routingflare settings allowlist remove <ip-or-cidr>")
            }
            settings.allowlistEntries.removeAll { $0 == entry }
            print("Allowlist removed: \(entry)")
        case "clear":
            settings.allowlistEntries.removeAll()
            print("Allowlist cleared. All inbound IPs are allowed.")
        default:
            throw CLIError.message("Usage: routingflare settings allowlist add|remove|clear [entry]")
        }

        store.save(settings)
        sendAppCommand("reload")
    }

    private func updateAuthHeader(_ arguments: [String]) throws {
        guard let action = arguments.first else {
            throw CLIError.message("Usage: routingflare settings auth on|off|set [--name header] [--secret value]")
        }

        let options = parseOptions(Array(arguments.dropFirst()))
        var settings = store.load()

        switch action {
        case "on", "enable":
            settings.authHeaderEnabled = true
        case "off", "disable":
            settings.authHeaderEnabled = false
        case "set":
            break
        default:
            throw CLIError.message("Usage: routingflare settings auth on|off|set [--name header] [--secret value]")
        }

        if let name = options["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            settings.authHeaderName = name
        }
        if let secret = options["secret"] {
            settings.authHeaderSecret = secret
        }

        store.save(settings)
        sendAppCommand("reload")
        print("Auth header \(settings.authHeaderEnabled ? "enabled" : "disabled").")
    }

    private func printList() {
        let settings = store.load()
        let snapshot = liveRouteStatusSnapshot()

        print("Random DNS")
        printRoutes(settings.quickRoutes, from: { route in
            let normalized = normalizedRoute(route, kind: .quickURL)
            let entry = statusEntry(for: normalized, kind: .quickURL, snapshot: snapshot)
            let from = entry?.publicURL.flatMap { URL(string: $0)?.host } ?? "random dns"
            return "\(from)\(normalized.normalizedTargetPath == "/" ? "" : normalized.normalizedTargetPath) to 127.0.0.1:\(normalized.targetPort)\(securitySuffix(for: normalized))\(statusSuffix(for: entry))"
        })

        print("\nDNS")
        printRoutes(settings.dnsRoutes, from: { route in
            let normalized = normalizedRoute(route, kind: .dns)
            let entry = statusEntry(for: normalized, kind: .dns, snapshot: snapshot)
            return "\(normalized.hostname)\(normalized.normalizedTargetPath == "/" ? "" : normalized.normalizedTargetPath) -> 127.0.0.1:\(normalized.targetPort)\(securitySuffix(for: normalized))\(statusSuffix(for: entry))"
        })

        print("\nOptions")
        print("  autoStart: \(settings.autoStart ? "on" : "off")")
        print("  cloudflared: \(settings.cloudflaredPath.isEmpty ? "auto-detect" : settings.cloudflaredPath)")
        print("  allowlist: \(settings.allowlistEntries.isEmpty ? "allow all" : settings.allowlistEntries.joined(separator: ", "))")
        print("  authHeader: \(settings.authHeaderEnabled ? "on" : "off")")
    }

    private func routeSecurity(_ arguments: [String]) throws {
        guard arguments.count >= 3 else {
            throw CLIError.message("Usage: routingflare security random|dns <index> show|allowlist|auth ...")
        }
        let type = arguments[0]
        guard let index = Int(arguments[1]), index > 0 else {
            throw CLIError.message("Index must be a positive number.")
        }
        let action = arguments[2]
        let rest = Array(arguments.dropFirst(3))
        var settings = store.load()
        let changed: Bool

        switch type {
        case "random", "quick":
            changed = try updateRouteSecurity(action: action, arguments: rest, index: index, routes: &settings.quickRoutes, label: "random DNS")
        case "dns":
            changed = try updateRouteSecurity(action: action, arguments: rest, index: index, routes: &settings.dnsRoutes, label: "DNS")
        default:
            throw CLIError.message("Usage: routingflare security random|dns <index> show|allowlist|auth ...")
        }

        if changed {
            store.save(settings)
            sendAppCommand("reload")
        }
    }

    private func updateRouteSecurity(
        action: String,
        arguments: [String],
        index: Int,
        routes: inout [LocalProxyRoute],
        label: String
    ) throws -> Bool {
        guard routes.indices.contains(index - 1) else {
            throw CLIError.message("No \(label) route at index \(index).")
        }

        var route = routes[index - 1]
        var security = route.security ?? RouteSecurity()

        switch action {
        case "show", "get":
            printRouteSecurity(security, label: "\(label) route \(index)")
            return false
        case "allowlist":
            try updateRouteAllowlist(&security, arguments: arguments)
        case "auth":
            try updateRouteAuth(&security, arguments: arguments)
        default:
            throw CLIError.message("Usage: routingflare security random|dns <index> show|allowlist|auth ...")
        }

        route.security = security.isEmpty ? nil : security
        routes[index - 1] = route
        print("Updated \(label) route \(index) security.")
        return true
    }

    private func updateRouteAllowlist(_ security: inout RouteSecurity, arguments: [String]) throws {
        guard let action = arguments.first else {
            throw CLIError.message("Usage: routingflare security <type> <index> allowlist add|remove|clear [entry]")
        }
        switch action {
        case "add":
            guard let entry = arguments.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines), !entry.isEmpty else {
                throw CLIError.message("Usage: routingflare security <type> <index> allowlist add <ip-or-cidr>")
            }
            _ = try IPAllowlist(entries: [entry])
            if !security.allowlistEntries.contains(entry) {
                security.allowlistEntries.append(entry)
            }
        case "remove", "rm":
            guard let entry = arguments.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines), !entry.isEmpty else {
                throw CLIError.message("Usage: routingflare security <type> <index> allowlist remove <ip-or-cidr>")
            }
            security.allowlistEntries.removeAll { $0 == entry }
        case "clear":
            security.allowlistEntries.removeAll()
        default:
            throw CLIError.message("Usage: routingflare security <type> <index> allowlist add|remove|clear [entry]")
        }
    }

    private func updateRouteAuth(_ security: inout RouteSecurity, arguments: [String]) throws {
        guard let action = arguments.first else {
            throw CLIError.message("Usage: routingflare security <type> <index> auth on|off|set [--name header] [--secret value]")
        }
        let options = parseOptions(Array(arguments.dropFirst()))

        switch action {
        case "on", "enable":
            security.authHeaderEnabled = true
        case "off", "disable":
            security.authHeaderEnabled = false
        case "set":
            break
        default:
            throw CLIError.message("Usage: routingflare security <type> <index> auth on|off|set [--name header] [--secret value]")
        }

        if let name = options["name"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            security.authHeaderName = name
        }
        if let secret = options["secret"] {
            security.authHeaderSecret = secret
        }
    }

    private func printRouteSecurity(_ security: RouteSecurity, label: String) {
        print(label)
        print("  allowlist: \(security.allowlistEntries.isEmpty ? "allow all" : security.allowlistEntries.joined(separator: ", "))")
        print("  auth header: \(security.authHeaderEnabled ? "on" : "off")")
        print("  auth header name: \(security.authHeaderName)")
        print("  auth secret: \(security.authHeaderSecret.isEmpty ? "not set" : "set")")
    }

    private func updateFromCLI() throws {
        let appURL = installedAppURL()
        let currentVersion = installedAppVersion(appURL: appURL) ?? "0"
        print("Checking for updates...")

        let releaseData = try Data(contentsOf: releaseAPIURL)
        let release = try JSONDecoder().decode(GitHubRelease.self, from: releaseData)
        let plan = ReleasePlanner.plan(from: release, currentVersion: currentVersion)

        guard plan.isNewer else {
            print("routingflare is up to date. Current version: \(currentVersion)")
            return
        }

        guard let dmgURL = plan.dmgURL else {
            if let releaseURL = plan.releaseURL {
                print("Version \(plan.latestVersion) is available: \(releaseURL.absoluteString)")
            }
            throw CLIError.message("No DMG asset found in the latest release.")
        }

        print("Version \(plan.latestVersion) is available. Current version: \(currentVersion)")
        let dmgPath = try downloadDMG(from: dmgURL)
        print("Downloaded \(dmgPath.path)")
        try installDMG(dmgPath, to: appURL)
        print("Installed routingflare \(plan.latestVersion) at \(appURL.path)")
    }

    private func installedAppURL() -> URL {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var current = executableURL
        while current.path != "/" {
            if current.pathExtension == "app" {
                return current
            }
            current.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: "/Applications/routingflare.app", isDirectory: true)
    }

    private func installedAppVersion(appURL: URL) -> String? {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: infoURL) else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }

    private func downloadDMG(from url: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("routingflare-\(UUID().uuidString).dmg")
        try runProcess("/usr/bin/curl", ["-fL", url.absoluteString, "-o", destination.path])
        return destination
    }

    private func installDMG(_ dmgURL: URL, to appURL: URL) throws {
        let mountDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("routingflare-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountDirectory, withIntermediateDirectories: true)
        defer {
            try? runProcess("/usr/bin/hdiutil", ["detach", mountDirectory.path, "-quiet"])
            try? FileManager.default.removeItem(at: mountDirectory)
        }

        quitRunningApp()
        try runProcess("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-mountpoint", mountDirectory.path, dmgURL.path])
        let sourceAppURL = try findAppBundle(in: mountDirectory)

        if FileManager.default.fileExists(atPath: appURL.path) {
            try FileManager.default.removeItem(at: appURL)
        }
        try runProcess("/usr/bin/ditto", [sourceAppURL.path, appURL.path])
        try? runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path])

        let executableURL = appURL.appendingPathComponent("Contents/MacOS/routingflare")
        _ = try CLIInstaller().install(bundledCLIURL: executableURL)
    }

    private func findAppBundle(in mountDirectory: URL) throws -> URL {
        let urls = try FileManager.default.contentsOfDirectory(
            at: mountDirectory,
            includingPropertiesForKeys: nil
        )
        if let appURL = urls.first(where: { $0.pathExtension == "app" }) {
            return appURL
        }
        throw CLIError.message("No app bundle found in DMG.")
    }

    private func quitRunningApp() {
        for bundleID in ["com.gyuminhwangbo.RoutingFlare", "dev.local.tunnelbar", "dev.local.routingflare"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", #"tell application id "\#(bundleID)" to quit"#]
            try? process.run()
            process.waitUntilExit()
        }
        Thread.sleep(forTimeInterval: 1)
    }

    private func runProcess(_ executablePath: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CLIError.message(output.isEmpty ? "\(executablePath) failed with status \(process.terminationStatus)" : output)
        }
    }

    private func printRoutes<T>(_ routes: [T], from title: (T) -> String) {
        if routes.isEmpty {
            print("  none")
            return
        }
        for (index, route) in routes.enumerated() {
            print("  \(index + 1). \(title(route))")
        }
    }

    private func liveRouteStatusSnapshot() -> RouteStatusSnapshot? {
        guard let snapshot = routeStatusStore.load(),
              snapshot.appPID > 0,
              kill(snapshot.appPID, 0) == 0 else {
            return nil
        }
        return snapshot
    }

    private func statusEntry(
        for route: LocalProxyRoute,
        kind: TunnelMode,
        snapshot: RouteStatusSnapshot?
    ) -> RouteStatusEntry? {
        snapshot?.entries.first { $0.kind == kind && $0.route == route }
    }

    private func statusSuffix(for entry: RouteStatusEntry?) -> String {
        guard let entry else { return "" }
        switch entry.state {
        case .opened:
            return " [opened]"
        case .pending:
            return " [pending\(messageSuffix(entry.message))]"
        case .stopped:
            return " [stopped]"
        case .restartRequired:
            return " [restart required]"
        case .error:
            return " [error\(messageSuffix(entry.message))]"
        }
    }

    private func securitySuffix(for route: LocalProxyRoute) -> String {
        guard let security = route.security, !security.isEmpty else {
            return ""
        }
        return " [secured]"
    }

    private func messageSuffix(_ message: String?) -> String {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty else {
            return ""
        }
        return ": \(message)"
    }

    private func normalizedRoute(_ route: LocalProxyRoute, kind: TunnelMode) -> LocalProxyRoute {
        LocalProxyRoute(
            hostname: kind == .quickURL ? "" : route.hostname.trimmingCharacters(in: .whitespacesAndNewlines),
            targetPort: route.targetPort,
            targetPath: normalizedPath(route.targetPath),
            security: route.security
        )
    }

    private func sendAppCommand(_ command: String) {
        let defaults = RoutingFlareDefaults.userDefaults()
        defaults.set(command, forKey: RoutingFlareDefaults.pendingCommandKey)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(RoutingFlareDefaults.commandNotificationName),
            object: nil,
            userInfo: ["command": command],
            deliverImmediately: true
        )
    }

    private func launchAppIfNeeded() {
        for bundleID in ["com.gyuminhwangbo.RoutingFlare", "dev.local.tunnelbar", "dev.local.routingflare"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-b", bundleID]
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    return
                }
            } catch {
                continue
            }
        }
    }

    private func parseOptions(_ arguments: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if key.hasPrefix("--"), index + 1 < arguments.count {
                result[String(key.dropFirst(2))] = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        return result
    }

    private func requiredPort(_ value: String?, name: String) throws -> Int {
        guard let value, let port = Int(value), port > 0, port <= 65_535 else {
            throw CLIError.message("Missing or invalid --\(name) port.")
        }
        return port
    }

    private func boolValue(_ value: String, name: String) throws -> Bool {
        switch value.lowercased() {
        case "on", "true", "yes", "1":
            return true
        case "off", "false", "no", "0":
            return false
        default:
            throw CLIError.message("--\(name) must be on or off.")
        }
    }

    private func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    private func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    private func printHelp() {
        print("""
        routingflare

        Usage:
          routingflare list
          routingflare add random --port 3000 [--path /]
          routingflare add dns --host dev.example.com --port 8080 [--path /console]
          routingflare remove random|dns <index>
          routingflare start
          routingflare stop
          routingflare settings
          routingflare settings set --autostart on
          routingflare settings set --cloudflared /opt/homebrew/bin/cloudflared
          routingflare settings set --dns-tunnel-id <id> --dns-credentials ~/.cloudflared/<id>.json
          routingflare security random 1 allowlist add 203.0.113.10
          routingflare security random 1 auth on --name X-Routingflare-Secret --secret value
          routingflare security dns 1 show
          routingflare update
          routingflare autostart on|off
          routingflare cloudflared /path/to/cloudflared
        """)
    }
}

do {
    try RoutingFlareCLI().run(CommandLine.arguments)
} catch {
    fputs("routingflare: \(error.localizedDescription)\n", stderr)
    exit(1)
}
