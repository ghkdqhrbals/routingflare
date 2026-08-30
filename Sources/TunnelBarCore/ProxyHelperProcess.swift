import Darwin
import Foundation

struct ProxyHelperConfiguration: Encodable {
    var version = 1
    var id = 0
    let routes: [LocalProxyRoute]
    let fallbackTargetPort: Int
    let defaultPolicy: RouteSecurity
}

final class ProxyHelperProcess: @unchecked Sendable {
    let id: UUID
    private let process: Process
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let condition = NSCondition()
    private var buffer = Data()
    private var replies: [Int: Reply] = [:]
    private var nextID = 0
    private var exited = false
    private var expectedStop = false
    private var pipesClosed = false
    private var started = false
    private var channelError: String?
    private var failureReported = false
    private let acknowledgementTimeout: TimeInterval
    private let logHandler: @Sendable (String) -> Void
    private let failureHandler: @Sendable (String) -> Void

    private struct Reply: Decodable {
        let type: String
        let id: Int?
        let port: Int?
        let message: String?
    }

    init(id: UUID, logHandler: @escaping @Sendable (String) -> Void, onFailure: @escaping @Sendable (String) -> Void,
         process: Process = Process(), acknowledgementTimeout: TimeInterval = 5) throws {
        self.id = id
        self.process = process
        self.acknowledgementTimeout = acknowledgementTimeout
        self.logHandler = logHandler
        self.failureHandler = onFailure
        process.executableURL = try Self.executableURL()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A dead child must produce a write error, never SIGPIPE in the macOS app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        for descriptor in [input.fileHandleForWriting.fileDescriptor, output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] {
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw LocalFilteringProxyError.helperFailed("Could not configure the proxy control channel.")
            }
        }
    }

    deinit { stop() }

    func start(_ configuration: ProxyHelperConfiguration) throws -> Int {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self, let data = self.readAvailable(handle) else { return }
            self.receive(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self, let data = self.readAvailable(handle) else { return }
            if data.isEmpty { handle.readabilityHandler = nil; return }
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.condition.lock()
            self.exited = true
            let failure = self.takeFailureLocked("Proxy helper exited with status \(process.terminationStatus). Routes are closed.")
            self.condition.broadcast()
            self.condition.unlock()
            self.report(failure)
        }
        try process.run()
        started = true
        let reply = try exchange(configuration, expecting: "ready")
        guard let port = reply.port, (1...65535).contains(port) else { throw LocalFilteringProxyError.listenerNotReady }
        return port
    }

    func apply(_ configuration: ProxyHelperConfiguration) throws {
        _ = try exchange(configuration, expecting: "applied")
    }

    private func exchange(_ configuration: ProxyHelperConfiguration, expecting type: String) throws -> Reply {
        nextID += 1
        var command = configuration
        command.id = nextID
        var data = try JSONEncoder().encode(command)
        guard data.count < 2 * 1024 * 1024 else {
            throw LocalFilteringProxyError.helperFailed("Proxy configuration exceeds the 2 MiB control-message limit.")
        }
        data.append(0x0A)
        let deadline = Date().addingTimeInterval(acknowledgementTimeout)
        try write(data, deadline: deadline)
        condition.lock()
        defer { condition.unlock() }
        while replies[nextID] == nil && !exited && channelError == nil {
            if !condition.wait(until: deadline) { break }
        }
        guard channelError == nil, !exited, let reply = replies.removeValue(forKey: nextID), reply.type == type else {
            throw LocalFilteringProxyError.helperFailed(channelError ?? "Proxy did not acknowledge \(type). Routes are closed.")
        }
        return reply
    }

    private func write(_ data: Data, deadline: Date) throws {
        let descriptor = input.fileHandleForWriting.fileDescriptor
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard deadline.timeIntervalSinceNow > 0 else {
                    throw LocalFilteringProxyError.helperFailed("Proxy configuration timed out. Routes are closed.")
                }
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                guard written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else {
                    throw LocalFilteringProxyError.helperFailed("Proxy control channel could not accept configuration. Routes are closed.")
                }
                var descriptorState = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let milliseconds = Int32(max(1, min(100, deadline.timeIntervalSinceNow * 1000)))
                _ = poll(&descriptorState, 1, milliseconds)
            }
        }
    }

    // A pipe read must return currently available bytes, not wait to fill a buffer.
    private func readAvailable(_ handle: FileHandle) -> Data? {
        condition.lock()
        defer { condition.unlock() }
        guard !pipesClosed else { return nil }
        var data = Data(count: 64 * 1024)
        let count = data.withUnsafeMutableBytes { bytes in
            Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
        }
        if count < 0 {
            return (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? nil : Data()
        }
        data.count = count
        return data
    }

    // Callbacks run outside the reader/termination queues and never while holding their lock.
    private func takeFailureLocked(_ message: String) -> String? {
        guard !expectedStop, !failureReported else { return nil }
        failureReported = true
        return message
    }

    private func report(_ message: String?) {
        guard let message else { return }
        let callback = failureHandler
        DispatchQueue.global().async { callback(message) }
    }

    private func receive(_ data: Data) {
        condition.lock()
        if data.isEmpty {
            output.fileHandleForReading.readabilityHandler = nil
            guard !expectedStop else { condition.unlock(); return }
            channelError = channelError ?? "Proxy control channel closed."
            let failure = takeFailureLocked(channelError!)
            condition.broadcast()
            condition.unlock()
            report(failure)
            return
        }
        guard !expectedStop else { condition.unlock(); return }
        buffer.append(data)
        var logs: [String] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<end]
            if let reply = try? JSONDecoder().decode(Reply.self, from: line) {
                if reply.type == "log", let message = reply.message { logs.append(message) }
                else if reply.type == "error" { channelError = reply.message ?? "Proxy configuration failed." }
                else if let id = reply.id { replies[id] = reply }
            } else { channelError = "Proxy returned an invalid control message." }
            buffer.removeSubrange(...end)
        }
        if buffer.count > 2 * 1024 * 1024 {
            buffer.removeAll()
            channelError = "Proxy returned an oversized control message."
        }
        let failure = channelError.flatMap { takeFailureLocked($0) }
        condition.broadcast()
        condition.unlock()
        logs.forEach(logHandler)
        report(failure)
    }

    func stop() {
        condition.lock()
        if expectedStop { condition.unlock(); return }
        expectedStop = true
        condition.unlock()
        try? input.fileHandleForWriting.close()
        if started && !waitForExit(seconds: 2) {
            if process.isRunning { process.terminate() }
            if !waitForExit(seconds: 1) {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                _ = waitForExit(seconds: 1)
            }
        }
        condition.lock()
        pipesClosed = true
        condition.unlock()
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        try? output.fileHandleForReading.close()
        try? errors.fileHandleForReading.close()
    }

    private func waitForExit(seconds: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while !exited {
            if !condition.wait(until: deadline) { break }
        }
        return exited
    }

    private static func executableURL() throws -> URL {
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("routingflare-proxy"))
        }
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(root.appendingPathComponent(".build/proxy/routingflare-proxy"))
        #endif
        guard let url = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw LocalFilteringProxyError.helperUnavailable
        }
        return url
    }
}
