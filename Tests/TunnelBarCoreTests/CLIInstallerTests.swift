import XCTest
@testable import TunnelBarCore

final class CLIInstallerTests: XCTestCase {
    private var temporaryHomeURL: URL!
    private var bundledCLIURL: URL!

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("routingflare-cli-installer-\(UUID().uuidString)", isDirectory: true)
        temporaryHomeURL = root.appendingPathComponent("home", isDirectory: true)
        let bundleDirectory = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryHomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

        bundledCLIURL = bundleDirectory.appendingPathComponent("routingflare")
        try "#!/bin/sh\nexit 0\n".write(to: bundledCLIURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledCLIURL.path)
    }

    override func tearDownWithError() throws {
        if let temporaryHomeURL {
            let root = temporaryHomeURL.deletingLastPathComponent()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testInstallCreatesSymlinkAndAddsPathToZshrc() throws {
        let result = try makeInstaller().install(bundledCLIURL: bundledCLIURL)

        XCTAssertTrue(result.installedOrUpdatedLink)
        XCTAssertTrue(result.addedPathToZshrc)
        XCTAssertEqual(try symlinkDestination(), bundledCLIURL.path)

        let zshrc = try zshrcContent()
        XCTAssertTrue(zshrc.contains(#"export PATH="$HOME/.local/bin:$PATH""#))
    }

    func testInstallIsIdempotentWhenSymlinkAndPathAlreadyExist() throws {
        _ = try makeInstaller().install(bundledCLIURL: bundledCLIURL)

        let result = try makeInstaller().install(bundledCLIURL: bundledCLIURL)

        XCTAssertFalse(result.installedOrUpdatedLink)
        XCTAssertFalse(result.addedPathToZshrc)
        XCTAssertEqual(try symlinkDestination(), bundledCLIURL.path)
        XCTAssertEqual(try zshrcContent().components(separatedBy: ".local/bin").count - 1, 1)
    }

    func testInstallReplacesExistingWrongSymlink() throws {
        let binDirectoryURL = temporaryHomeURL.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectoryURL, withIntermediateDirectories: true)
        let wrongTarget = temporaryHomeURL.appendingPathComponent("old-routingflare")
        try FileManager.default.createSymbolicLink(
            at: binDirectoryURL.appendingPathComponent("routingflare"),
            withDestinationURL: wrongTarget
        )

        let result = try makeInstaller().install(bundledCLIURL: bundledCLIURL)

        XCTAssertTrue(result.installedOrUpdatedLink)
        XCTAssertEqual(try symlinkDestination(), bundledCLIURL.path)
    }

    func testInstallFailsWhenBundledCLIIsMissing() {
        let missingURL = temporaryHomeURL.appendingPathComponent("missing")

        XCTAssertThrowsError(try makeInstaller().install(bundledCLIURL: missingURL)) { error in
            XCTAssertEqual(error as? CLIInstallerError, .missingBundledCLI(missingURL.path))
        }
    }

    private func makeInstaller() -> CLIInstaller {
        CLIInstaller(homeURL: temporaryHomeURL)
    }

    private func symlinkDestination() throws -> String {
        try FileManager.default.destinationOfSymbolicLink(
            atPath: temporaryHomeURL.appendingPathComponent(".local/bin/routingflare").path
        )
    }

    private func zshrcContent() throws -> String {
        try String(contentsOf: temporaryHomeURL.appendingPathComponent(".zshrc"), encoding: .utf8)
    }
}
