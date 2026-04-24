import Foundation

public struct EshBridgeConfiguration: Sendable, Equatable {
    public let executablePath: String
    public let homePath: String
    public let repoRootPath: String
    public let model: String
    public let providerID: String
    public let optimization: OptimizationConfig
    public let requestTimeoutSeconds: Int

    public init(
        executablePath: String,
        homePath: String,
        repoRootPath: String,
        model: String,
        providerID: String,
        optimization: OptimizationConfig,
        requestTimeoutSeconds: Int = 180
    ) {
        self.executablePath = executablePath
        self.homePath = homePath
        self.repoRootPath = repoRootPath
        self.model = model
        self.providerID = providerID
        self.optimization = optimization
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }
}

public struct EshBackedModelAdapter: ModelAdapter {
    public let name: String
    public var providerID: String { configuration.providerID }
    public var modelID: String { configuration.model }

    private let configuration: EshBridgeConfiguration
    private let fallback: any ModelAdapter
    private let runner: any EshCommandRunning
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID
    private let createDirectory: @Sendable (URL) throws -> Void
    private let removeItem: @Sendable (URL) throws -> Void

    public init(
        configuration: EshBridgeConfiguration,
        fallback: any ModelAdapter
    ) {
        self.init(
            configuration: configuration,
            fallback: fallback,
            runner: nil,
            now: Date.init,
            makeUUID: UUID.init,
            createDirectory: { url in
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            },
            removeItem: { url in
                try FileManager.default.removeItem(at: url)
            }
        )
    }

    init(
        configuration: EshBridgeConfiguration,
        fallback: any ModelAdapter,
        runner: (any EshCommandRunning)? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init,
        createDirectory: @escaping @Sendable (URL) throws -> Void,
        removeItem: @escaping @Sendable (URL) throws -> Void
    ) {
        self.configuration = configuration
        self.fallback = fallback
        self.runner = runner ?? DefaultEshCommandRunner()
        self.now = now
        self.makeUUID = makeUUID
        self.createDirectory = createDirectory
        self.removeItem = removeItem
        self.name = "esh-bridge:\(configuration.providerID):\(configuration.model)"
    }

    public func nextAction(for context: ModelContext) async throws -> ModelAction {
        let assembly = PromptBuilder.build(for: context, provider: providerID, model: modelID)
        let prompt = context.messages.last(where: { $0.role == .user })?.content ?? assembly.userPrompt

        do {
            let reply = try await runEsh(
                systemPrompt: assembly.systemPrompt,
                history: Array(context.messages.dropLast()),
                message: assembly.userPrompt,
                taskKind: TaskPlanner.classify(prompt: prompt),
                taskPrompt: prompt
            )
            return try ToolInvocationParser.parseAction(from: reply)
        } catch {
            return try await fallback.nextAction(for: context)
        }
    }
}

extension EshBackedModelAdapter: DirectChatModelAdapter {
    public func directReply(history: [MessageRecord], systemPrompt: String) async throws -> String {
        try await directReplyEnvelope(history: history, systemPrompt: systemPrompt, attachments: []).text
    }

    public func directReplyEnvelope(history: [MessageRecord], systemPrompt: String, attachments _: [InputAttachment]) async throws -> DirectChatReplyEnvelope {
        let latestUserMessage = history.last(where: { $0.role == .user })?.content ?? "Continue the conversation."
        let priorHistory = dropTrailingUserMessageIfPresent(from: history)

        do {
            let reply = try await runEsh(
                systemPrompt: systemPrompt,
                history: priorHistory,
                message: latestUserMessage,
                taskKind: .analysis,
                taskPrompt: latestUserMessage
            )
            if let parsed = EshBridgeReplyParser.parseReply(from: reply) {
                return .init(text: parsed, reasoningSummary: ReasoningSummaryExtractor.summary(fromExposedThinkingIn: reply))
            }
            throw AshexError.model("esh direct chat reply was empty")
        } catch {
            guard let fallback = fallback as? any DirectChatModelAdapter else {
                throw error
            }
            return try await fallback.directReplyEnvelope(history: history, systemPrompt: systemPrompt, attachments: [])
        }
    }
}

extension EshBackedModelAdapter: TaskPlanningModelAdapter {
    public func taskPlan(for prompt: String, taskKind: TaskKind) async throws -> TaskPlan? {
        let systemPrompt = """
        You are planning a software task for an agent.
        Break the request into a short, concrete ordered task list.
        Return 2 to 6 steps only when the work is genuinely multi-step.
        Use phases from: exploration, planning, mutation, validation.
        Keep each title concise and action-oriented.
        Return only a JSON object with a `steps` array of `{title, phase}` items.
        """
        let message = "Task kind: \(taskKind.rawValue)\n\nUser request:\n\(prompt)"

        do {
            let reply = try await runEsh(
                systemPrompt: systemPrompt,
                history: [],
                message: message,
                taskKind: taskKind,
                taskPrompt: prompt
            )
            return try EshBridgeReplyParser.parseTaskPlan(from: reply, fallbackTaskKind: taskKind)
        } catch {
            guard let fallback = fallback as? any TaskPlanningModelAdapter else {
                throw error
            }
            return try await fallback.taskPlan(for: prompt, taskKind: taskKind)
        }
    }
}

private extension EshBackedModelAdapter {
    func runEsh(
        systemPrompt: String,
        history: [MessageRecord],
        message: String,
        taskKind: TaskKind,
        taskPrompt: String
    ) async throws -> String {
        do {
            return try await runExternalEsh(
                systemPrompt: systemPrompt,
                history: history,
                message: message,
                taskKind: taskKind,
                taskPrompt: taskPrompt
            )
        } catch {
            return try await runLegacyEsh(
                systemPrompt: systemPrompt,
                history: history,
                message: message,
                taskKind: taskKind,
                taskPrompt: taskPrompt
            )
        }
    }

    func runExternalEsh(
        systemPrompt: String,
        history: [MessageRecord],
        message: String,
        taskKind: TaskKind,
        taskPrompt: String
    ) async throws -> String {
        let requestID = makeUUID()
        let requestURL = try writeInferRequest(
            id: requestID,
            systemPrompt: systemPrompt,
            history: history,
            message: message,
            taskKind: taskKind,
            taskPrompt: taskPrompt
        )
        var artifactID: String?
        defer {
            try? cleanupRequest(requestURL: requestURL, artifactID: artifactID)
        }

        let capabilities = try? await fetchCapabilities()
        let resolution = resolveOptimization(taskKind: taskKind, prompt: taskPrompt)
        let modelCapability = capabilities?.resolveModelCapability(for: configuration.model)
        if shouldBuildCacheArtifact(
            capability: modelCapability,
            resolution: resolution
        ) {
            let buildCommand = EshCommandBuilder.buildCommand(
                executablePath: configuration.executablePath,
                homePath: configuration.homePath,
                sessionID: requestID.uuidString,
                mode: resolution.mode,
                intent: resolvedIntent(taskKind: taskKind, prompt: taskPrompt),
                model: configuration.model,
                task: taskPrompt
            )
            let buildResult = try await runner.run(
                command: buildCommand,
                workspaceURL: URL(fileURLWithPath: configuration.repoRootPath, isDirectory: true),
                timeout: TimeInterval(configuration.requestTimeoutSeconds)
            )
            guard buildResult.exitCode == 0, !buildResult.timedOut else {
                throw AshexError.model("esh cache build failed: \(buildResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            let buildMetadata = try EshBridgeOutputParser.parseMetadataBlock(from: buildResult.stdout)
            guard let artifact = buildMetadata["artifact"], !artifact.isEmpty else {
                throw AshexError.model("esh cache build did not return an artifact identifier")
            }
            artifactID = artifact

            let requestWithArtifactURL = try writeInferRequest(
                id: requestID,
                systemPrompt: systemPrompt,
                history: history,
                message: message,
                taskKind: taskKind,
                taskPrompt: taskPrompt,
                cacheArtifactID: artifact
            )
            return try await runInfer(requestURL: requestWithArtifactURL)
        }

        return try await runInfer(requestURL: requestURL)
    }

    func runLegacyEsh(
        systemPrompt: String,
        history: [MessageRecord],
        message: String,
        taskKind: TaskKind,
        taskPrompt: String
    ) async throws -> String {
        let sessionID = makeUUID()
        let now = now()
        let sessionURL = try writeSession(
            id: sessionID,
            systemPrompt: systemPrompt,
            history: history,
            timestamp: now,
            taskKind: taskKind,
            taskPrompt: taskPrompt
        )

        var artifactID: String?
        defer {
            try? cleanup(sessionURL: sessionURL, artifactID: artifactID)
        }

        let resolution = resolveOptimization(taskKind: taskKind, prompt: taskPrompt)
        let buildCommand = EshCommandBuilder.buildCommand(
            executablePath: configuration.executablePath,
            homePath: configuration.homePath,
            sessionID: sessionID.uuidString,
            mode: resolution.mode,
            intent: resolvedIntent(taskKind: taskKind, prompt: taskPrompt),
            model: configuration.model,
            task: taskPrompt
        )
        let buildResult = try await runner.run(
            command: buildCommand,
            workspaceURL: URL(fileURLWithPath: configuration.repoRootPath, isDirectory: true),
            timeout: TimeInterval(configuration.requestTimeoutSeconds)
        )
        guard buildResult.exitCode == 0, !buildResult.timedOut else {
            throw AshexError.model("esh cache build failed: \(buildResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let buildMetadata = try EshBridgeOutputParser.parseMetadataBlock(from: buildResult.stdout)
        guard let artifact = buildMetadata["artifact"], !artifact.isEmpty else {
            throw AshexError.model("esh cache build did not return an artifact identifier")
        }
        artifactID = artifact

        let loadCommand = EshCommandBuilder.loadCommand(
            executablePath: configuration.executablePath,
            homePath: configuration.homePath,
            artifactID: artifact,
            model: configuration.model,
            message: message
        )
        let loadResult = try await runner.run(
            command: loadCommand,
            workspaceURL: URL(fileURLWithPath: configuration.repoRootPath, isDirectory: true),
            timeout: TimeInterval(configuration.requestTimeoutSeconds)
        )
        guard loadResult.exitCode == 0, !loadResult.timedOut else {
            throw AshexError.model("esh cache load failed: \(loadResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let reply = EshBridgeOutputParser.stripMetadataTrailer(from: loadResult.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            throw AshexError.model("esh cache load did not return a reply")
        }
        return reply
    }

    func fetchCapabilities() async throws -> EshCapabilitiesResponse {
        let command = EshCommandBuilder.capabilitiesCommand(
            executablePath: configuration.executablePath,
            homePath: configuration.homePath
        )
        let result = try await runner.run(
            command: command,
            workspaceURL: URL(fileURLWithPath: configuration.repoRootPath, isDirectory: true),
            timeout: TimeInterval(configuration.requestTimeoutSeconds)
        )
        guard result.exitCode == 0, !result.timedOut else {
            throw AshexError.model("esh capabilities failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return try EshBridgeOutputParser.parseCapabilities(from: result.stdout)
    }

    func runInfer(requestURL: URL) async throws -> String {
        let inferCommand = EshCommandBuilder.inferCommand(
            executablePath: configuration.executablePath,
            homePath: configuration.homePath,
            inputPath: requestURL.path
        )
        let inferResult = try await runner.run(
            command: inferCommand,
            workspaceURL: URL(fileURLWithPath: configuration.repoRootPath, isDirectory: true),
            timeout: TimeInterval(configuration.requestTimeoutSeconds)
        )
        guard inferResult.exitCode == 0, !inferResult.timedOut else {
            throw AshexError.model("esh infer failed: \(inferResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let response = try EshBridgeOutputParser.parseInferResponse(from: inferResult.stdout)
        let reply = response.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty else {
            throw AshexError.model("esh infer did not return a reply")
        }
        return reply
    }

    func shouldBuildCacheArtifact(
        capability: EshInstalledModelCapability?,
        resolution: ContextOptimizationResolution
    ) -> Bool {
        guard resolution.mode != .raw else { return false }
        if let capability {
            return capability.supportsCacheBuild && capability.supportsCacheLoad
        }
        return false
    }

    func resolveOptimization(taskKind: TaskKind, prompt: String) -> ContextOptimizationResolution {
        let doctor = EshOptimizationInspector().doctor(
            provider: configuration.providerID,
            model: configuration.model,
            taskKind: taskKind,
            prompt: prompt,
            config: configuration.optimization
        )
        return ContextOptimizationAdvisor().resolve(
            taskKind: taskKind,
            prompt: prompt,
            provider: configuration.providerID,
            model: configuration.model,
            config: configuration.optimization,
            calibrationAvailable: doctor.calibrationAvailable
        )
    }

    func resolvedIntent(taskKind: TaskKind, prompt: String) -> ContextOptimizationIntent {
        let configured = configuration.optimization.intent
        if configured != .agentRun {
            return configured
        }

        switch taskKind {
        case .bugFix, .feature, .refactor:
            return .code
        case .analysis where TaskPlanner.shouldAttemptModelPlanning(for: prompt):
            return .agentRun
        case .analysis, .general, .docs, .git, .shell:
            return .chat
        }
    }

    func writeSession(
        id: UUID,
        systemPrompt: String,
        history: [MessageRecord],
        timestamp: Date,
        taskKind: TaskKind,
        taskPrompt: String
    ) throws -> URL {
        let sessionsDirectory = URL(fileURLWithPath: configuration.homePath, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        try createDirectory(sessionsDirectory)

        let sessionURL = sessionsDirectory.appendingPathComponent("\(id.uuidString).json")
        let session = EshSessionRecord(
            id: id,
            name: "Ashex \(taskKind.rawValue)",
            modelID: configuration.model,
            backend: nil,
            cacheMode: resolveOptimization(taskKind: taskKind, prompt: taskPrompt).mode.rawValue,
            intent: resolvedIntent(taskKind: taskKind, prompt: taskPrompt).rawValue,
            autosaveEnabled: false,
            messages: buildMessages(systemPrompt: systemPrompt, history: history, timestamp: timestamp),
            createdAt: timestamp,
            updatedAt: timestamp
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: sessionURL, options: .atomic)
        return sessionURL
    }

    func buildMessages(systemPrompt: String, history: [MessageRecord], timestamp: Date) -> [EshSessionRecord.Message] {
        let systemMessage = EshSessionRecord.Message(
            id: makeUUID(),
            role: "system",
            text: systemPrompt,
            createdAt: timestamp
        )

        let mappedHistory = history.suffix(12).map { record in
            EshSessionRecord.Message(
                id: record.id,
                role: record.role.rawValue,
                text: record.content,
                createdAt: record.createdAt
            )
        }
        return [systemMessage] + mappedHistory
    }

    func writeInferRequest(
        id: UUID,
        systemPrompt: String,
        history: [MessageRecord],
        message: String,
        taskKind: TaskKind,
        taskPrompt: String,
        cacheArtifactID: String? = nil
    ) throws -> URL {
        let requestsDirectory = URL(fileURLWithPath: configuration.homePath, isDirectory: true)
            .appendingPathComponent("external", isDirectory: true)
        try createDirectory(requestsDirectory)

        let requestURL = requestsDirectory.appendingPathComponent("\(id.uuidString).json")
        let artifactUUID = cacheArtifactID.flatMap(UUID.init(uuidString:))
        let request = EshInferRequest(
            model: configuration.model,
            cacheArtifactID: artifactUUID,
            sessionName: "Ashex \(taskKind.rawValue)",
            cacheMode: resolveOptimization(taskKind: taskKind, prompt: taskPrompt).mode.rawValue,
            intent: resolvedIntent(taskKind: taskKind, prompt: taskPrompt).rawValue,
            messages: buildInferMessages(systemPrompt: systemPrompt, history: history, message: message),
            generation: .init()
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(request).write(to: requestURL, options: .atomic)
        return requestURL
    }

    func buildInferMessages(systemPrompt: String, history: [MessageRecord], message: String) -> [EshInferMessage] {
        let systemMessage = EshInferMessage(role: "system", text: systemPrompt)
        let mappedHistory = history.suffix(12).map { record in
            EshInferMessage(role: record.role.rawValue, text: record.content)
        }
        let userMessage = EshInferMessage(role: "user", text: message)
        return [systemMessage] + mappedHistory + [userMessage]
    }

    func cleanup(sessionURL: URL, artifactID: String?) throws {
        try? removeItem(sessionURL)

        guard let artifactID, !artifactID.isEmpty else { return }

        let homeURL = URL(fileURLWithPath: configuration.homePath, isDirectory: true)
        let manifestURL = homeURL
            .appendingPathComponent("caches", isDirectory: true)
            .appendingPathComponent("manifests", isDirectory: true)
            .appendingPathComponent("\(artifactID).json")
        let payloadURL = homeURL
            .appendingPathComponent("caches", isDirectory: true)
            .appendingPathComponent("payloads", isDirectory: true)
            .appendingPathComponent("\(artifactID).bin")

        try? removeItem(manifestURL)
        try? removeItem(payloadURL)
    }

    func cleanupRequest(requestURL: URL, artifactID: String?) throws {
        try? removeItem(requestURL)
        try? cleanupArtifact(artifactID: artifactID)
    }

    func cleanupArtifact(artifactID: String?) throws {
        guard let artifactID, !artifactID.isEmpty else { return }

        let homeURL = URL(fileURLWithPath: configuration.homePath, isDirectory: true)
        let manifestURL = homeURL
            .appendingPathComponent("caches", isDirectory: true)
            .appendingPathComponent("manifests", isDirectory: true)
            .appendingPathComponent("\(artifactID).json")
        let payloadURL = homeURL
            .appendingPathComponent("caches", isDirectory: true)
            .appendingPathComponent("payloads", isDirectory: true)
            .appendingPathComponent("\(artifactID).bin")

        try? removeItem(manifestURL)
        try? removeItem(payloadURL)
    }

    func dropTrailingUserMessageIfPresent(from history: [MessageRecord]) -> [MessageRecord] {
        guard history.last?.role == .user else { return history }
        return Array(history.dropLast())
    }
}

private struct EshSessionRecord: Codable {
    struct Message: Codable {
        let id: UUID
        let role: String
        let text: String
        let createdAt: Date
    }

    let id: UUID
    let name: String
    let modelID: String?
    let backend: String?
    let cacheMode: String?
    let intent: String?
    let autosaveEnabled: Bool?
    let messages: [Message]
    let createdAt: Date
    let updatedAt: Date
}

protocol EshCommandRunning: Sendable {
    func run(command: String, workspaceURL: URL, timeout: TimeInterval) async throws -> ShellExecutionResult
}

private struct DefaultEshCommandRunner: EshCommandRunning {
    private let runtime = ProcessExecutionRuntime()

    func run(command: String, workspaceURL: URL, timeout: TimeInterval) async throws -> ShellExecutionResult {
        try await runtime.execute(
            .init(command: command, workspaceURL: workspaceURL, timeout: timeout),
            cancellationToken: CancellationToken(),
            onStdout: { _ in },
            onStderr: { _ in }
        )
    }
}

enum EshBridgeOutputParser {
    static func parseMetadataBlock(from stdout: String) throws -> [String: String] {
        let pairs = stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> (String, String)? in
                guard let separator = line.firstIndex(of: ":") else { return nil }
                let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return nil }
                return (key, value)
            }
        guard !pairs.isEmpty else {
            throw AshexError.model("esh did not return a metadata block")
        }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    static func stripMetadataTrailer(from stdout: String) -> String {
        var lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        while let last = lines.last, isMetadataLine(last) {
            lines.removeLast()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    static func parseCapabilities(from stdout: String) throws -> EshCapabilitiesResponse {
        try JSONDecoder().decode(EshCapabilitiesResponse.self, from: Data(stdout.utf8))
    }

    static func parseInferResponse(from stdout: String) throws -> EshInferResponse {
        try JSONDecoder().decode(EshInferResponse.self, from: Data(stdout.utf8))
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: ":") else { return false }
        let key = trimmed[..<separator].lowercased()
        return key == "artifact"
            || key == "requested_mode"
            || key == "mode"
            || key == "intent"
            || key == "policy"
            || key == "size"
            || key == "snapshot"
            || key == "reply_chars"
            || key == "ttft_ms"
            || key == "tok_s"
            || key.hasPrefix("context_")
    }
}

private enum EshBridgeReplyParser {
    static func parseReply(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let candidate = extractJSONObjectString(from: trimmed),
           let payload = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any] {
            if let reply = payload["reply"] as? String {
                let normalized = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, !looksLikeInternalReasoning(normalized) else { return nil }
                return normalized
            }
            return nil
        }

        guard !looksLikeInternalReasoning(trimmed) else { return nil }
        return trimmed
    }

    private static func looksLikeInternalReasoning(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = [
            "the user is asking",
            "i need to analyze",
            "i need to",
            "i should provide",
            "i should",
            "let me think",
            "i can infer",
            "based on the context",
            "or simulate the analysis",
            "common github repo structures",
            "the name gives a strong hint",
        ]
        let matches = markers.reduce(into: 0) { partial, marker in
            if lowered.contains(marker) {
                partial += 1
            }
        }
        return matches >= 2
    }

    static func parseTaskPlan(from content: String, fallbackTaskKind: TaskKind) throws -> TaskPlan? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = extractJSONObjectString(from: trimmed) ?? trimmed
        let envelope = try JSONDecoder().decode(EshTaskPlanEnvelope.self, from: Data(candidate.utf8))
        let plan = TaskPlan(
            steps: envelope.steps.map { PlannedStep(title: $0.title, phase: $0.phase) },
            taskKind: fallbackTaskKind
        )
        return TaskPlanner.normalize(plan: plan, fallbackTaskKind: fallbackTaskKind)
    }

    private static func extractJSONObjectString(from content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return trimmed
        }

        if let fencedRange = trimmed.range(of: "```") {
            let afterFence = trimmed[fencedRange.upperBound...]
            let withoutLanguage = afterFence.hasPrefix("json")
                ? afterFence.dropFirst(4)
                : afterFence
            if let closingFence = withoutLanguage.range(of: "```") {
                let inner = withoutLanguage[..<closingFence.lowerBound]
                let candidate = inner.trimmingCharacters(in: .whitespacesAndNewlines)
                if candidate.hasPrefix("{"), candidate.hasSuffix("}") {
                    return candidate
                }
            }
        }

        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        let candidate = String(trimmed[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.hasPrefix("{") && candidate.hasSuffix("}") ? candidate : nil
    }
}

private struct EshTaskPlanEnvelope: Codable {
    struct Step: Codable {
        let title: String
        let phase: PlannedStepPhase
    }

    let steps: [Step]
}

struct EshCapabilitiesResponse: Codable {
    let schemaVersion: String
    let tool: String
    let toolVersion: String?
    let commands: [EshCommandDescriptor]
    let backends: [EshBackendCapability]
    let installedModels: [EshInstalledModelCapability]

    func resolveModelCapability(for identifier: String) -> EshInstalledModelCapability? {
        let lowered = identifier.lowercased()
        return installedModels.first {
            $0.id.lowercased() == lowered ||
            $0.displayName.lowercased() == lowered ||
            $0.source.lowercased() == lowered
        }
    }

    func resolveBackendCapability(for backend: String) -> EshBackendCapability? {
        backends.first { $0.backend.lowercased() == backend.lowercased() }
    }
}

struct EshCommandDescriptor: Codable {
    let name: String
    let inputSchema: String
    let outputSchema: String
    let transport: String
}

struct EshBackendCapability: Codable {
    let backend: String
    let supportsDirectInference: Bool
    let supportsCacheBuild: Bool
    let supportsCacheLoad: Bool
}

struct EshInstalledModelCapability: Codable {
    let id: String
    let displayName: String
    let backend: String
    let source: String
    let variant: String?
    let runtimeVersion: String?
    let supportsDirectInference: Bool
    let supportsCacheBuild: Bool
    let supportsCacheLoad: Bool
}

struct EshInferRequest: Codable {
    let schemaVersion: String
    let model: String
    let cacheArtifactID: UUID?
    let sessionName: String
    let cacheMode: String
    let intent: String
    let messages: [EshInferMessage]
    let generation: EshGenerationConfig

    init(
        schemaVersion: String = "esh.infer.request.v1",
        model: String,
        cacheArtifactID: UUID?,
        sessionName: String,
        cacheMode: String,
        intent: String,
        messages: [EshInferMessage],
        generation: EshGenerationConfig
    ) {
        self.schemaVersion = schemaVersion
        self.model = model
        self.cacheArtifactID = cacheArtifactID
        self.sessionName = sessionName
        self.cacheMode = cacheMode
        self.intent = intent
        self.messages = messages
        self.generation = generation
    }
}

struct EshInferMessage: Codable {
    let role: String
    let text: String
}

struct EshGenerationConfig: Codable {
    let maxTokens: Int
    let temperature: Double

    init(maxTokens: Int = 512, temperature: Double = 0.7) {
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

struct EshInferResponse: Codable {
    let schemaVersion: String
    let modelID: String
    let backend: String
    let integration: EshInferIntegration
    let outputText: String
}

struct EshInferIntegration: Codable {
    let mode: String
    let cacheArtifactID: UUID?
    let cacheMode: String?
}

private enum EshCommandBuilder {
    static func capabilitiesCommand(
        executablePath: String,
        homePath: String
    ) -> String {
        [
            "env",
            "ESH_HOME=\(quote(homePath))",
            quote(executablePath),
            "capabilities",
        ].joined(separator: " ")
    }

    static func inferCommand(
        executablePath: String,
        homePath: String,
        inputPath: String
    ) -> String {
        [
            "env",
            "ESH_HOME=\(quote(homePath))",
            quote(executablePath),
            "infer",
            "--input",
            quote(inputPath),
        ].joined(separator: " ")
    }

    static func buildCommand(
        executablePath: String,
        homePath: String,
        sessionID: String,
        mode: ContextOptimizationMode,
        intent: ContextOptimizationIntent,
        model: String,
        task: String
    ) -> String {
        var parts = [
            "env",
            "ESH_HOME=\(quote(homePath))",
            quote(executablePath),
            "cache",
            "build",
            "--session",
            quote(sessionID),
            "--mode",
            quote(mode.rawValue),
            "--intent",
            quote(intent.rawValue),
            "--model",
            quote(model),
        ]
        if !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(contentsOf: ["--task", quote(task)])
        }
        return parts.joined(separator: " ")
    }

    static func loadCommand(
        executablePath: String,
        homePath: String,
        artifactID: String,
        model: String,
        message: String
    ) -> String {
        [
            "env",
            "ESH_HOME=\(quote(homePath))",
            quote(executablePath),
            "cache",
            "load",
            "--artifact",
            quote(artifactID),
            "--model",
            quote(model),
            "--message",
            quote(message),
        ].joined(separator: " ")
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
