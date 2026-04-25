import Foundation
import Testing
@testable import AshexCore

@Test func processExecutionRuntimeWaitsForTimedOutChildBeforeReadingStatus() async throws {
    let runtime = ProcessExecutionRuntime()
    let result = try await runtime.execute(
        ShellExecutionRequest(
            command: "sleep 2",
            workspaceURL: FileManager.default.temporaryDirectory,
            timeout: 0.1
        ),
        cancellationToken: CancellationToken(),
        onStdout: { _ in },
        onStderr: { _ in }
    )

    #expect(result.timedOut)
}

@Test func processExecutionRuntimeTerminatesChildWhenParentTaskIsCancelled() async throws {
    let runtime = ProcessExecutionRuntime()
    let task = Task {
        try await runtime.execute(
            ShellExecutionRequest(
                command: "sleep 10",
                workspaceURL: FileManager.default.temporaryDirectory,
                timeout: 30
            ),
            cancellationToken: CancellationToken(),
            onStdout: { _ in },
            onStderr: { _ in }
        )
    }

    try await Task.sleep(for: .milliseconds(100))
    task.cancel()

    do {
        _ = try await task.value
        Issue.record("Expected cancelled process execution to throw")
    } catch is CancellationError {
    } catch {
        Issue.record("Expected CancellationError, got \(error)")
    }
}
