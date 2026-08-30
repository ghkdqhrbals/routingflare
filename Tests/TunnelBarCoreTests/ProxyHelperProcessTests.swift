import Darwin
import XCTest
@testable import TunnelBarCore

final class ProxyHelperProcessTests: XCTestCase {
    private var configuration: ProxyHelperConfiguration {
        ProxyHelperConfiguration(routes: [], fallbackTargetPort: 8080, defaultPolicy: RouteSecurity())
    }

    func testFrozenHelperCannotBlockWritingLargeConfiguration() throws {
        let process = Process()
        let helper = try ProxyHelperProcess(id: UUID(), logHandler: { _ in }, onFailure: { _ in },
                                            process: process, acknowledgementTimeout: 0.25)
        _ = try helper.start(configuration)
        defer { _ = kill(process.processIdentifier, SIGCONT); helper.stop() }
        XCTAssertEqual(kill(process.processIdentifier, SIGSTOP), 0)
        let large = ProxyHelperConfiguration(routes: [], fallbackTargetPort: 8080,
                                            defaultPolicy: RouteSecurity(allowlistEntries: Array(repeating: "203.0.113.10", count: 40_000)))
        let started = Date()
        XCTAssertThrowsError(try helper.apply(large))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testUnexpectedExitIsReportedOnceAndWritesFailWithoutSIGPIPE() throws {
        let failure = expectation(description: "Unexpected helper exit")
        failure.assertForOverFulfill = true
        let process = Process()
        let helper = try ProxyHelperProcess(id: UUID(), logHandler: { _ in }, onFailure: { _ in failure.fulfill() }, process: process)
        _ = try helper.start(configuration)
        defer { helper.stop() }
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        wait(for: [failure], timeout: 3)
        XCTAssertThrowsError(try helper.apply(configuration))
    }

    func testInvalidPortDoesNotLeaveProxyRunning() throws {
        let proxy = LocalFilteringProxy(targetPort: 65536, accessPolicy: MutableProxyAccessPolicy(allowlistEntries: []), logHandler: { _ in })
        XCTAssertThrowsError(try proxy.start())
        XCTAssertNil(proxy.port)
        proxy.stop()
    }

    func testRepeatedStartStopDoesNotReportUnexpectedFailure() throws {
        let failure = expectation(description: "Intentional stops must not report failure")
        failure.isInverted = true
        for _ in 0..<16 {
            let helper = try ProxyHelperProcess(id: UUID(), logHandler: { _ in }, onFailure: { _ in failure.fulfill() })
            _ = try helper.start(configuration)
            helper.stop()
            helper.stop()
        }
        wait(for: [failure], timeout: 0.1)
    }
}
