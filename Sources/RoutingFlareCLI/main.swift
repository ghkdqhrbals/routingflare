import Foundation
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
        case "start", "stop", "open", "settings":
            sendAppCommand(first)
            if first == "start" || first == "open" || first == "settings" {
                launchAppIfNeeded()
            }
            print("Sent \(first) to routingflare.")
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

    private func printList() {
        let settings = store.load()

        print("Random DNS")
        printRoutes(settings.quickRoutes, from: { route in
            "random dns\(route.normalizedTargetPath == "/" ? "" : route.normalizedTargetPath) to 127.0.0.1:\(route.targetPort)"
        })

        print("\nDNS")
        printRoutes(settings.dnsRoutes, from: { route in
            "\(route.hostname)\(route.normalizedTargetPath == "/" ? "" : route.normalizedTargetPath) -> 127.0.0.1:\(route.targetPort)"
        })

        print("\nOptions")
        print("  autoStart: \(settings.autoStart ? "on" : "off")")
        print("  cloudflared: \(settings.cloudflaredPath.isEmpty ? "auto-detect" : settings.cloudflaredPath)")
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
          routingflare open
          routingflare settings
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
