import Foundation
import TunnelBarCore

// A loopback-only host for exercising the same proxy API used by the app.
@main
struct ProxyIntegrationHost {
    struct Command: Decodable {
        let id: Int
        let routes: [LocalProxyRoute]
        let fallbackTargetPort: Int
        let defaultPolicy: RouteSecurity
    }

    static func main() throws {
        let defaults = MutableProxyAccessPolicy(allowlistEntries: [])
        let policies = MutableRouteSecurityPolicies()
        var proxy: LocalFilteringProxy?
        defer { proxy?.stop() }
        while let line = readLine() {
            let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
            defaults.update(
                allowlistEntries: command.defaultPolicy.allowlistEntries,
                authHeader: ProxyAuthHeader(
                    enabled: command.defaultPolicy.authHeaderEnabled,
                    name: command.defaultPolicy.authHeaderName,
                    secret: command.defaultPolicy.authHeaderSecret
                )
            )
            policies.update(routes: command.routes)
            if proxy == nil {
                let next = LocalFilteringProxy(
                    routes: command.routes,
                    fallbackTargetPort: command.fallbackTargetPort,
                    accessPolicy: defaults,
                    routeSecurityPolicies: policies,
                    logHandler: { message in
                        FileHandle.standardError.write(Data((message + "\n").utf8))
                    }
                )
                let port = try next.start()
                proxy = next
                print("{\"type\":\"ready\",\"id\":\(command.id),\"port\":\(port)}")
            } else {
                print("{\"type\":\"applied\",\"id\":\(command.id)}")
            }
            fflush(stdout)
        }
    }
}
