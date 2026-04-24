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

    @Test func parsesCapabilitiesFromJSONOutput() throws {
        let capabilities = try EshBridgeOutputParser.parseCapabilities(from: """
        {
          "schemaVersion": "esh.capabilities.v1",
          "tool": "esh",
          "toolVersion": "0.2.0",
          "commands": [
            {
              "name": "infer",
              "inputSchema": "esh.infer.request.v1",
              "outputSchema": "esh.infer.response.v1",
              "transport": "json"
            }
          ],
          "backends": [
            {
              "backend": "mlx",
              "supportsDirectInference": true,
              "supportsCacheBuild": true,
              "supportsCacheLoad": true
            },
            {
              "backend": "gguf",
              "supportsDirectInference": true,
              "supportsCacheBuild": false,
              "supportsCacheLoad": false
            }
          ],
          "installedModels": [
            {
              "id": "qwen2.5-coder-mlx",
              "displayName": "Qwen 2.5 Coder MLX",
              "backend": "mlx",
              "source": "mlx-community/Qwen2.5-Coder",
              "variant": null,
              "runtimeVersion": "mlx-v1",
              "supportsDirectInference": true,
              "supportsCacheBuild": true,
              "supportsCacheLoad": true
            }
          ]
        }
        """)

        #expect(capabilities.commands.count == 1)
        #expect(capabilities.resolveModelCapability(for: "mlx-community/Qwen2.5-Coder")?.supportsCacheLoad == true)
        #expect(capabilities.resolveBackendCapability(for: "gguf")?.supportsCacheBuild == false)
    }

    @Test func parsesInferResponseFromJSONOutput() throws {
        let response = try EshBridgeOutputParser.parseInferResponse(from: """
        {
          "schemaVersion": "esh.infer.response.v1",
          "modelID": "qwen2.5-coder-mlx",
          "backend": "mlx",
          "integration": {
            "mode": "direct",
            "cacheArtifactID": null,
            "cacheMode": "auto"
          },
          "outputText": "{\\"type\\":\\"final_answer\\",\\"final_answer\\":\\"done\\",\\"tool_name\\":null,\\"arguments\\":{}}"
        }
        """)

        #expect(response.backend == "mlx")
        #expect(response.integration.mode == "direct")
        #expect(response.outputText.contains(#""final_answer":"done""#))
    }

    @Test func parsesInferResponseWithGeneratedAudioFile() throws {
        let response = try EshBridgeOutputParser.parseInferResponse(from: """
        {
          "schemaVersion": "esh.infer.response.v1",
          "modelID": "audio-model",
          "backend": "mlx",
          "integration": {
            "mode": "direct",
            "cacheArtifactID": null,
            "cacheMode": "auto"
          },
          "outputFiles": [
            {
              "kind": "audio",
              "localPath": "/tmp/ashex-reply.wav",
              "mimeType": "audio/wav"
            }
          ]
        }
        """)

        #expect(response.outputText.isEmpty)
        #expect(response.generatedFiles.first?.kind == "audio")
        #expect(response.generatedFiles.first?.localPath == "/tmp/ashex-reply.wav")
        #expect(response.renderedReply.contains("/tmp/ashex-reply.wav"))
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

    @Test func directReplyPassesAudioAttachmentsToEshInfer() async throws {
        let homeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let audioURL = homeURL.appendingPathComponent("voice.ogg")
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try Data([0x4F, 0x67, 0x67]).write(to: audioURL)

        let runner = RecordingInferRunner(reply: "heard the audio")
        let adapter = EshBackedModelAdapter(
            configuration: .init(
                executablePath: "/opt/homebrew/bin/esh",
                homePath: homeURL.path,
                repoRootPath: FileManager.default.temporaryDirectory.path,
                model: "audio-model",
                providerID: "esh",
                optimization: .init(enabled: true, backend: .esh, mode: .automatic, intent: .chat)
            ),
            fallback: RecordingFallbackAdapter(),
            runner: runner,
            createDirectory: { url in try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) },
            removeItem: { _ in }
        )

        let thread = ThreadRecord(id: UUID(), createdAt: Date())
        let history = [
            MessageRecord(
                id: UUID(),
                threadID: thread.id,
                runID: nil,
                role: .user,
                content: "Transcribe this",
                createdAt: Date()
            )
        ]

        let envelope = try await adapter.directReplyEnvelope(
            history: history,
            systemPrompt: "Answer naturally.",
            attachments: [
                .init(
                    kind: .audio,
                    localPath: audioURL.path,
                    originalFilename: "voice.ogg",
                    mimeType: "audio/ogg",
                    caption: "What is in this audio?",
                    durationSeconds: 3,
                    fileSizeBytes: 3
                )
            ]
        )

        #expect(envelope.text == "heard the audio")
        let request = try await #require(runner.lastInferRequest())
        #expect(request.messages.last?.attachments?.first?.kind == "audio")
        #expect(request.messages.last?.attachments?.first?.localPath == audioURL.path)
        #expect(request.messages.last?.attachments?.first?.mimeType == "audio/ogg")
        #expect(request.messages.last?.attachments?.first?.originalFilename == "voice.ogg")
    }

    @Test func directReplyFallbackPreservesAttachmentsWhenEshFails() async throws {
        let fallback = RecordingFallbackAdapter()
        let adapter = EshBackedModelAdapter(
            configuration: .init(
                executablePath: "/opt/homebrew/bin/esh",
                homePath: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path,
                repoRootPath: FileManager.default.temporaryDirectory.path,
                model: "audio-model",
                providerID: "esh",
                optimization: .init(enabled: true, backend: .esh, mode: .automatic, intent: .chat)
            ),
            fallback: fallback,
            runner: FailingRunner(),
            createDirectory: { _ in },
            removeItem: { _ in }
        )
        let thread = ThreadRecord(id: UUID(), createdAt: Date())
        let attachment = InputAttachment(kind: .audio, localPath: "/tmp/audio.ogg", mimeType: "audio/ogg")

        _ = try await adapter.directReplyEnvelope(
            history: [
                .init(id: UUID(), threadID: thread.id, runID: nil, role: .user, content: "Listen", createdAt: Date())
            ],
            systemPrompt: "Answer naturally.",
            attachments: [attachment]
        )

        #expect(await fallback.lastAttachments() == [attachment])
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

private actor RecordingInferRunner: EshCommandRunning {
    private let reply: String
    private var request: EshInferRequest?

    init(reply: String) {
        self.reply = reply
    }

    func run(command: String, workspaceURL: URL, timeout: TimeInterval) async throws -> ShellExecutionResult {
        if command.contains(" capabilities") {
            return ShellExecutionResult(stdout: """
            {
              "schemaVersion": "esh.capabilities.v1",
              "tool": "esh",
              "toolVersion": "0.2.0",
              "commands": [
                {
                  "name": "infer",
                  "inputSchema": "esh.infer.request.v1",
                  "outputSchema": "esh.infer.response.v1",
                  "transport": "json"
                }
              ],
              "backends": [],
              "installedModels": [
                {
                  "id": "audio-model",
                  "displayName": "Audio Model",
                  "backend": "mlx",
                  "source": "audio-model",
                  "variant": null,
                  "runtimeVersion": null,
                  "supportsDirectInference": true,
                  "supportsCacheBuild": false,
                  "supportsCacheLoad": false
                }
              ]
            }
            """, stderr: "", exitCode: 0, timedOut: false)
        }

        if let inputPath = command.inputPathArgument {
            let data = try Data(contentsOf: URL(fileURLWithPath: inputPath))
            request = try JSONDecoder().decode(EshInferRequest.self, from: data)
        }

        return ShellExecutionResult(stdout: """
        {
          "schemaVersion": "esh.infer.response.v1",
          "modelID": "audio-model",
          "backend": "mlx",
          "integration": {
            "mode": "direct",
            "cacheArtifactID": null,
            "cacheMode": "auto"
          },
          "outputText": "\(reply)"
        }
        """, stderr: "", exitCode: 0, timedOut: false)
    }

    func lastInferRequest() -> EshInferRequest? {
        request
    }
}

private actor RecordingFallbackAdapter: DirectChatModelAdapter {
    let name = "recording-fallback"
    let providerID = "fallback"
    let modelID = "fallback"
    private var attachments: [InputAttachment] = []

    func nextAction(for context: ModelContext) async throws -> ModelAction {
        .finalAnswer("fallback")
    }

    func directReply(history: [MessageRecord], systemPrompt: String) async throws -> String {
        "fallback"
    }

    func directReplyEnvelope(history: [MessageRecord], systemPrompt: String, attachments: [InputAttachment]) async throws -> DirectChatReplyEnvelope {
        self.attachments = attachments
        return .init(text: "fallback")
    }

    func lastAttachments() -> [InputAttachment] {
        attachments
    }
}

private extension String {
    var inputPathArgument: String? {
        guard let range = range(of: "--input ") else { return nil }
        var remainder = self[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard remainder.first == "'" else { return nil }
        remainder.removeFirst()
        guard let end = remainder.firstIndex(of: "'") else { return nil }
        return String(remainder[..<end])
    }
}
