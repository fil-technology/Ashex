@testable import AshexCore
import Foundation
import Testing

@Suite(.serialized)
struct EshBridgeModelAdapterTests {
    @Test func parsesArtifactMetadataFromBuildOutput() throws {
        let metadata = try EshBridgeOutputParser.parseMetadataBlock(from: """
        artifact: 6C61A9AE-0102-43F4-BEE2-95F6D2A91114
        requested_mode: auto
        mode: turbo
        intent: agentrun
        policy: broader multi-step code task prefers turbo reuse
        """)

        #expect(metadata["artifact"] == "6C61A9AE-0102-43F4-BEE2-95F6D2A91114")
        #expect(metadata["mode"] == "turbo")
        #expect(metadata["intent"] == "agentrun")
    }

    @Test func stripsMetadataTrailerFromLoadOutput() {
        let reply = EshBridgeOutputParser.stripMetadataTrailer(from: """
        {"type":"final_answer","final_answer":"done","tool_name":null,"arguments":null}

        artifact: 6C61A9AE-0102-43F4-BEE2-95F6D2A91114
        context_task: Implement a focused local daemon fix
        policy: broader multi-step code task prefers turbo reuse
        reply_chars: 76
        ttft_ms: 812
        tok_s: 54.3
        """)

        #expect(reply == #"{"type":"final_answer","final_answer":"done","tool_name":null,"arguments":null}"#)
    }

    @Test func fallsBackWhenBridgeExecutionFails() async throws {
        let adapter = EshBackedModelAdapter(
            configuration: .init(
                executablePath: "/opt/homebrew/bin/esh",
                homePath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
                repoRootPath: FileManager.default.temporaryDirectory.path,
                model: "qwen2.5-coder:7b",
                providerID: "ollama",
                optimization: .init(enabled: true, backend: .esh, mode: .automatic, intent: .agentRun)
            ),
            fallback: MockModelAdapter(),
            runner: FailingRunner(),
            createDirectory: { _ in },
            removeItem: { _ in }
        )

        let action = try await adapter.nextAction(for: sampleContext(prompt: "list files"))
        let expected = ModelAction.toolCall(.init(toolName: "filesystem", arguments: [
            "operation": .string("list_directory"),
            "path": .string("."),
        ]))
        #expect(action == expected)
    }
}

private struct FailingRunner: EshCommandRunning {
    func run(command: String, workspaceURL: URL, timeout: TimeInterval) async throws -> ShellExecutionResult {
        ShellExecutionResult(stdout: "", stderr: "esh unavailable", exitCode: 1, timedOut: false)
    }
}

private func sampleContext(prompt: String) -> ModelContext {
    let thread = ThreadRecord(id: UUID(), createdAt: Date())
    let run = RunRecord(id: UUID(), threadID: thread.id, state: .running, createdAt: Date(), updatedAt: Date())
    return ModelContext(
        thread: thread,
        run: run,
        messages: [
            .init(id: UUID(), threadID: thread.id, runID: run.id, role: .user, content: prompt, createdAt: Date()),
        ],
        availableTools: [
            .init(name: "filesystem", description: "Read/write text files and list or create directories within the workspace"),
            .init(name: "shell", description: "Execute shell commands inside the workspace with streaming stdout/stderr"),
        ]
    )
}
