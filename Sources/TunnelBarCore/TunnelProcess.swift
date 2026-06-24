import Foundation

public final class TunnelProcess {
    private var process: Process?
    private var outputPipe: Pipe?

    public init() {}

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    public func start(
        command: TunnelCommand,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        stop()

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = pipe
        process.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            onOutput(text)
        }

        process.terminationHandler = { process in
            pipe.fileHandleForReading.readabilityHandler = nil
            onExit(process.terminationStatus)
        }

        self.process = process
        self.outputPipe = pipe
        try process.run()
    }

    public func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
        outputPipe = nil
    }
}
