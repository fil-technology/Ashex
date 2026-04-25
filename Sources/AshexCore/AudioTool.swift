import Foundation

public struct AudioTool: Tool {
    public let name = "audio"
    public let description = "Generate local spoken audio files from text"
    public let contract = ToolContract(
        name: "audio",
        description: "Generate local spoken audio files from text",
        kind: .embedded,
        category: "media",
        operationArgumentKey: "operation",
        operations: [
            .init(
                name: "generate_speech",
                description: "Use macOS speech synthesis to generate an audio file from text",
                mutatesWorkspace: false,
                changedPathArguments: ["output_path"],
                progressSummary: "generated speech audio",
                arguments: [
                    .init(name: "operation", description: "Operation name", type: .string, required: true, enumValues: ["generate_speech"]),
                    .init(name: "text", description: "Text to speak in the generated audio", type: .string, required: true),
                    .init(name: "output_path", description: "Workspace-relative output path. Defaults to generated-audio/<id>.aiff", type: .string, required: false),
                    .init(name: "voice", description: "Optional macOS voice name", type: .string, required: false),
                    .init(name: "timeout_seconds", description: "Optional timeout in seconds", type: .number, required: false),
                ]
            )
        ],
        tags: ["core", "audio", "speech", "tts", "media"]
    )

    private let executionRuntime: any ExecutionRuntime
    private let workspaceGuard: WorkspaceGuard

    public init(executionRuntime: any ExecutionRuntime, workspaceGuard: WorkspaceGuard) {
        self.executionRuntime = executionRuntime
        self.workspaceGuard = workspaceGuard
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        guard arguments["operation"]?.stringValue == "generate_speech" else {
            throw AshexError.invalidToolArguments("audio.operation must be generate_speech")
        }
        guard let text = arguments["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw AshexError.invalidToolArguments("audio.text must be a non-empty string")
        }

        let outputPath = arguments["output_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let outputURL = try workspaceGuard.resolveForMutation(
            path: outputPath?.isEmpty == false ? outputPath! : "generated-audio/\(UUID().uuidString).aiff"
        )
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var parts = [
            "/usr/bin/say",
            "-o",
            shellQuoted(outputURL.path),
            "--data-format=LEF32@22050",
        ]
        if let voice = arguments["voice"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !voice.isEmpty {
            parts.append(contentsOf: ["-v", shellQuoted(voice)])
        }
        parts.append(shellQuoted(text))

        let result = try await executionRuntime.execute(
            .init(
                command: parts.joined(separator: " "),
                workspaceURL: workspaceGuard.rootURL,
                timeout: TimeInterval(arguments["timeout_seconds"]?.intValue ?? 60)
            ),
            cancellationToken: context.cancellation,
            onStdout: { _ in },
            onStderr: { _ in }
        )

        if result.timedOut {
            throw AshexError.shell("Audio generation timed out")
        }
        if result.exitCode != 0 {
            throw AshexError.shell("Audio generation failed with exit code \(result.exitCode): \(result.stderr)")
        }

        return .text("Generated audio file: \(outputURL.path) (\(mimeType(for: outputURL)))")
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "aiff", "aif": return "audio/aiff"
        case "caf": return "audio/x-caf"
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        default: return "audio/aiff"
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
