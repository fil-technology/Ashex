import Foundation

public struct ShellExecutionRequest: Sendable {
    public let command: String
    public let workspaceURL: URL
    public let timeout: TimeInterval
}

public struct ShellExecutionResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let timedOut: Bool
}

public protocol ExecutionRuntime: Sendable {
    func execute(
        _ request: ShellExecutionRequest,
        cancellationToken: CancellationToken,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> ShellExecutionResult
}

public final class ProcessExecutionRuntime: ExecutionRuntime {
    public init() {}

    public func execute(
        _ request: ShellExecutionRequest,
        cancellationToken: CancellationToken,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> ShellExecutionResult {
        try await cancellationToken.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", request.command]
        process.currentDirectoryURL = request.workspaceURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutCollector = OutputCollector(handler: onStdout)
        let stderrCollector = OutputCollector(handler: onStderr)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutCollector.append(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrCollector.append(data)
            }
        }

        try process.run()

        let result = try await withThrowingTaskGroup(of: ShellExecutionResult.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { _ in
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        stdoutCollector.flush(handle: stdoutPipe.fileHandleForReading)
                        stderrCollector.flush(handle: stderrPipe.fileHandleForReading)
                        continuation.resume(returning: ShellExecutionResult(
                            stdout: stdoutCollector.output,
                            stderr: stderrCollector.output,
                            exitCode: process.terminationStatus,
                            timedOut: false
                        ))
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(request.timeout))
                process.terminate()
                return ShellExecutionResult(
                    stdout: stdoutCollector.output,
                    stderr: stderrCollector.output,
                    exitCode: process.terminationStatus,
                    timedOut: true
                )
            }

            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(100))
                    do {
                        try await cancellationToken.checkCancellation()
                    } catch {
                        process.terminate()
                        throw error
                    }
                }
            }

            guard let first = try await group.next() else {
                throw AshexError.shell("Failed to retrieve shell result")
            }
            group.cancelAll()
            return first
        }

        return result
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""
    private let handler: @Sendable (String) -> Void

    init(handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        lock.lock()
        storage.append(chunk)
        lock.unlock()
        handler(chunk)
    }

    func flush(handle: FileHandle) {
        let data = handle.readDataToEndOfFile()
        append(data)
    }
}
