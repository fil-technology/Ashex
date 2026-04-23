import AshexCore
import Foundation
import Testing

@Test func inMemorySecretStoreRoundTripsSecret() throws {
    let store = InMemorySecretStore()
    try store.writeSecret(namespace: "provider.credentials", key: "openai_api_key", value: "sk-test-123")

    #expect(try store.readSecret(namespace: "provider.credentials", key: "openai_api_key") == "sk-test-123")
    #expect(try store.containsSecret(namespace: "provider.credentials", key: "openai_api_key") == true)

    try store.deleteSecret(namespace: "provider.credentials", key: "openai_api_key")
    #expect(try store.readSecret(namespace: "provider.credentials", key: "openai_api_key") == nil)
    #expect(try store.containsSecret(namespace: "provider.credentials", key: "openai_api_key") == false)
}

@Test func localJSONSecretStorePersistsSecretsAcrossInstances() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fileURL = root.appendingPathComponent("secrets.json")
    let firstStore = LocalJSONSecretStore(fileURL: fileURL)

    try firstStore.writeSecret(namespace: "connector.credentials", key: "telegram_bot_token", value: "123:abc")

    let secondStore = LocalJSONSecretStore(fileURL: fileURL)
    #expect(try secondStore.readSecret(namespace: "connector.credentials", key: "telegram_bot_token") == "123:abc")

    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func shellCommandPolicyRequiresApprovalForUnknownCommandsWhenConfigured() {
    let policy = ShellCommandPolicy(config: .init(
        allowList: [],
        denyList: [],
        requireApprovalForUnknownCommands: true
    ))

    #expect(policy.assess(command: "ls -la") == .allow)

    switch policy.assess(command: "bundle exec rspec") {
    case .requireApproval(let message):
        #expect(message.contains("requires approval"))
    default:
        Issue.record("Expected unknown command to require approval")
    }
}

@Test func shellCommandPolicyRespectsAllowListBeforeApproval() {
    let policy = ShellCommandPolicy(config: .init(
        allowList: ["swift test"],
        denyList: [],
        requireApprovalForUnknownCommands: true
    ))

    #expect(policy.assess(command: "swift test") == .allow)

    switch policy.assess(command: "git status") {
    case .requireApproval(let message):
        #expect(message.contains("allow list"))
    default:
        Issue.record("Expected command outside allow list to require approval")
    }
}

@Test func shellCommandPolicySupportsExplicitPromptAndDenyRules() {
    let policy = ShellCommandPolicy(config: .init(
        allowList: [],
        denyList: [],
        requireApprovalForUnknownCommands: false,
        rules: [
            .init(prefix: "git push", action: .prompt, reason: "Pushes must be explicitly approved."),
            .init(prefix: "rm ", action: .deny, reason: "Recursive deletion is forbidden.")
        ]
    ))

    switch policy.assess(command: "git push origin main") {
    case .requireApproval(let message):
        #expect(message.contains("approved"))
    default:
        Issue.record("Expected prompt rule to require approval")
    }

    switch policy.assess(command: "rm -rf build") {
    case .deny(let message):
        #expect(message.contains("forbidden"))
    default:
        Issue.record("Expected deny rule to block command")
    }
}

@Test func shellExecutionPolicyCanRequireApprovalForNetworkCommands() {
    let policy = ShellExecutionPolicy(
        sandbox: .default,
        network: .init(mode: .prompt),
        shell: ShellCommandPolicy(config: .default)
    )

    switch policy.assess(command: "curl https://example.com") {
    case .requireApproval(let message):
        #expect(message.contains("network access"))
    default:
        Issue.record("Expected network command to require approval")
    }
}

@Test func shellExecutionPolicyCanDenyNetworkCommands() {
    let policy = ShellExecutionPolicy(
        sandbox: .default,
        network: .init(mode: .deny),
        shell: ShellCommandPolicy(config: .default)
    )

    switch policy.assess(command: "git fetch origin") {
    case .deny(let message):
        #expect(message.contains("network access"))
    default:
        Issue.record("Expected network command to be denied")
    }
}

@Test func connectorApprovalPolicyHonorsTrustedFullAccessMode() async {
    let request = ApprovalRequest(
        runID: UUID(),
        toolName: "shell",
        arguments: ["command": .string("curl https://example.com")],
        summary: "Shell command",
        reason: "curl https://example.com",
        risk: .medium
    )
    let policy = ConnectorApprovalPolicy(policyMode: .trustedFullAccess, connectorName: "telegram")
    let decision = await policy.evaluate(request)

    #expect(policy.mode == .trusted)
    #expect(decision.allowed)
    #expect(decision.reason.contains("trusted_full_access"))
}

@Test func connectorApprovalPolicyStillBlocksAssistantOnlyMode() async {
    let request = ApprovalRequest(
        runID: UUID(),
        toolName: "shell",
        arguments: ["command": .string("curl https://example.com")],
        summary: "Shell command",
        reason: "curl https://example.com",
        risk: .medium
    )
    let policy = ConnectorApprovalPolicy(policyMode: .assistantOnly, connectorName: "telegram")
    let decision = await policy.evaluate(request)

    #expect(policy.mode == .guarded)
    #expect(!decision.allowed)
    #expect(decision.reason.contains("assistant_only"))
}

@Test func connectorApprovalPolicyWaitsForRemoteInboxDecisionInApprovalRequiredMode() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("ashex.sqlite")
    let persistence = SQLitePersistenceStore(databaseURL: databaseURL)
    try persistence.initialize()

    let inbox = RemoteApprovalInbox(persistence: persistence)
    let runStore = DaemonConversationRunStore()
    let conversation = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "chat-1"
    )
    let runID = UUID()
    let token = CancellationToken()
    _ = await runStore.beginRun(for: conversation, threadID: UUID(), prompt: "run curl", cancellationToken: token)
    await runStore.bind(runID: runID, to: conversation)

    let request = ApprovalRequest(
        runID: runID,
        toolName: "shell",
        arguments: ["command": .string("curl https://example.com")],
        summary: "Shell command",
        reason: "curl https://example.com",
        risk: .medium
    )
    let policy = ConnectorApprovalPolicy(
        policyMode: .approvalRequired,
        connectorName: "telegram",
        remoteApprovalInbox: inbox,
        runStore: runStore
    )

    async let decision = policy.evaluate(request)
    try await Task.sleep(nanoseconds: 50_000_000)
    let pending = await inbox.pendingApproval(for: conversation)
    #expect(pending?.status == .pending)
    #expect(pending?.toolName == "shell")

    _ = await inbox.resolvePendingApproval(for: conversation, allowed: true, reason: "Approved from Telegram")
    let resolvedDecision = await decision

    #expect(resolvedDecision.allowed)
    #expect(resolvedDecision.reason.contains("Approved from Telegram"))
    #expect(await runStore.status(for: conversation)?.awaitingApproval == false)
}

@Test func connectorApprovalPolicyReusesLowRiskFilesystemApprovalForSameRun() async throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("ashex.sqlite")
    let persistence = SQLitePersistenceStore(databaseURL: databaseURL)
    try persistence.initialize()

    let inbox = RemoteApprovalInbox(persistence: persistence)
    let runStore = DaemonConversationRunStore()
    let conversation = ConnectorConversationReference(
        connectorKind: "telegram",
        connectorID: "telegram",
        externalConversationID: "chat-1"
    )
    let runID = UUID()
    let token = CancellationToken()
    _ = await runStore.beginRun(for: conversation, threadID: UUID(), prompt: "create files", cancellationToken: token)
    await runStore.bind(runID: runID, to: conversation)

    let policy = ConnectorApprovalPolicy(
        policyMode: .approvalRequired,
        connectorName: "telegram",
        remoteApprovalInbox: inbox,
        runStore: runStore
    )
    let firstRequest = ApprovalRequest(
        runID: runID,
        toolName: "filesystem",
        arguments: ["operation": .string("create_directory"), "path": .string("landing")],
        summary: "Create directory",
        reason: "landing",
        risk: .low
    )

    async let firstDecision = policy.evaluate(firstRequest)
    try await Task.sleep(nanoseconds: 50_000_000)
    _ = await inbox.resolvePendingApproval(for: conversation, allowed: true, reason: "Approved from Telegram")
    _ = await firstDecision

    let secondRequest = ApprovalRequest(
        runID: runID,
        toolName: "filesystem",
        arguments: ["operation": .string("write_text_file"), "path": .string("landing/index.html")],
        summary: "Write file",
        reason: "landing/index.html",
        risk: .medium
    )
    let secondDecision = await policy.evaluate(secondRequest)

    #expect(secondDecision.allowed)
    #expect(secondDecision.reason.contains("approved earlier in this run"))
    #expect(await inbox.pendingApproval(for: conversation) == nil)
}

@Test func workspaceGuardBlocksMutationsInReadOnlyMode() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let guardrail = WorkspaceGuard(rootURL: root, sandbox: .init(mode: .readOnly, protectedPaths: []))

    #expect(throws: AshexError.self) {
        _ = try guardrail.resolveForMutation(path: "notes.txt")
    }
}

@Test func workspaceGuardProtectsSensitiveWorkspacePaths() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let guardrail = WorkspaceGuard(rootURL: root, sandbox: .init(mode: .workspaceWrite, protectedPaths: [".git", ".ashex", "ashex.config.json"]))

    #expect(throws: AshexError.self) {
        _ = try guardrail.resolveForMutation(path: ".git/config")
    }

    #expect(throws: AshexError.self) {
        _ = try guardrail.resolveForMutation(path: "ashex.config.json")
    }

    let allowed = try guardrail.resolveForMutation(path: "Sources/App.swift")
    #expect(allowed.lastPathComponent == "App.swift")
}

@Test func mergedUserConfigUsesProjectOverridesOverGlobalDefaults() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let workspaceConfigURL = root.appendingPathComponent(UserConfigStore.fileName)
    let globalConfigURL = root.appendingPathComponent("global-config.json")

    try UserConfigStore.write(
        .init(
            version: 1,
            sandbox: .init(mode: .readOnly, protectedPaths: [".git"]),
            network: .init(mode: .deny),
            shell: .init(
                allowList: ["git status"],
                denyList: ["rm "],
                requireApprovalForUnknownCommands: false,
                rules: [.init(prefix: "git push", action: .prompt, reason: "Confirm pushes")]
            )
        ),
        to: globalConfigURL
    )

    try UserConfigStore.write(
        .init(
            version: 1,
            sandbox: .init(mode: .workspaceWrite, protectedPaths: [".git", ".ashex"]),
            network: .init(mode: .prompt),
            shell: .init(
                allowList: [],
                denyList: ["sudo "],
                requireApprovalForUnknownCommands: true,
                rules: [.init(prefix: "swift test", action: .allow)]
            )
        ),
        to: workspaceConfigURL
    )

    let loaded = try UserConfigStore.loadMerged(for: root, globalFileURL: globalConfigURL)
    #expect(loaded.effectiveConfig.sandbox.mode == .workspaceWrite)
    #expect(loaded.effectiveConfig.network.mode == .prompt)
    #expect(loaded.effectiveConfig.sandbox.protectedPaths == [".git", ".ashex"])
    #expect(loaded.effectiveConfig.shell.requireApprovalForUnknownCommands)
    #expect(loaded.effectiveConfig.shell.rules.map(\.prefix) == ["swift test"])
    #expect(loaded.globalFileURL == globalConfigURL)
}

@Test func mergedUserConfigLoadsOptimizationConfig() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configURL = root.appendingPathComponent(UserConfigStore.fileName)

    try """
    {
      "optimization": {
        "enabled": true,
        "backend": "esh",
        "mode": "auto",
        "intent": "agentrun",
        "esh": {
          "executablePath": "/opt/homebrew/bin/esh",
          "homePath": "/tmp/.esh"
        }
      }
    }
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let config = try UserConfigStore.load(from: configURL)
    #expect(config.optimization.enabled)
    #expect(config.optimization.backend == .esh)
    #expect(config.optimization.mode == .automatic)
    #expect(config.optimization.esh.homePath == "/tmp/.esh")
}

@Test func sessionInspectorLoadsDurableRunSnapshot() throws {
    let databaseURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("ashex.sqlite")
    let store = SQLitePersistenceStore(databaseURL: databaseURL)
    try store.initialize()

    let now = Date(timeIntervalSince1970: 123)
    let thread = try store.createThread(now: now)
    let run = try store.createRun(threadID: thread.id, state: .running, now: now)
    _ = try store.createRunSteps(runID: run.id, steps: ["Inspect", "Edit"], now: now)
    _ = try store.recordWorkspaceSnapshot(
        runID: run.id,
        workspaceRootPath: "/tmp/project",
        topLevelEntries: ["Package.swift", "Sources"],
        instructionFiles: ["README.md"],
        projectMarkers: ["Package.swift"],
        sourceRoots: ["Sources"],
        testRoots: [],
        gitBranch: "main",
        gitStatusSummary: "clean",
        now: now
    )
    _ = try store.upsertWorkingMemory(
        runID: run.id,
        currentTask: "Fix app",
        currentPhase: "exploration",
        explorationTargets: ["Sources/App.swift"],
        pendingExplorationTargets: [],
        rejectedExplorationTargets: ["README.md"],
        inspectedPaths: ["Sources/App.swift"],
        changedPaths: [],
        recentFindings: ["entry point found"],
        completedStepSummaries: [],
        unresolvedItems: [],
        validationSuggestions: ["swift test"],
        plannedChangeSet: ["Sources/App.swift"],
        patchObjectives: ["Keep the fix narrow."],
        carryForwardNotes: ["Inspect the app entry point first."],
        summary: "Investigating app entry point",
        now: now
    )
    _ = try store.recordContextCompaction(
        runID: run.id,
        droppedMessageCount: 4,
        retainedMessageCount: 6,
        estimatedTokenCount: 300,
        estimatedContextWindow: 8000,
        estimatedSavedTokenCount: 180,
        summary: "Compacted earlier reads",
        now: now
    )
    try store.appendEvent(RuntimeEvent(timestamp: now, payload: .status(runID: run.id, message: "Inspecting workspace")), runID: run.id)
    try store.appendEvent(RuntimeEvent(timestamp: now, payload: .status(runID: run.id, message: "Planning edits")), runID: run.id)

    let inspector = SessionInspector(persistence: store)
    let snapshot = try #require(try inspector.loadRunSnapshot(runID: run.id, recentEventLimit: 1))
    #expect(snapshot.run.id == run.id)
    #expect(snapshot.steps.count == 2)
    #expect(snapshot.compactions.count == 1)
    #expect(snapshot.workspaceSnapshot?.workspaceRootPath == "/tmp/project")
    #expect(snapshot.workingMemory?.currentTask == "Fix app")
    #expect(snapshot.events.count == 1)
}

@Test func sessionInspectorAggregatesSavedTokensAcrossRunScopes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try store.initialize()
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 1_710_000_000)
    let today = now.addingTimeInterval(-3_600)
    let yesterday = now.addingTimeInterval(-90_000)

    let sessionThread = try store.createThread(now: yesterday)
    let otherThread = try store.createThread(now: yesterday)
    let sessionRunA = try store.createRun(threadID: sessionThread.id, state: .completed, now: yesterday)
    let sessionRunB = try store.createRun(threadID: sessionThread.id, state: .completed, now: today)
    let otherRun = try store.createRun(threadID: otherThread.id, state: .completed, now: today)
    try store.transitionRun(runID: sessionRunA.id, to: .completed, reason: nil, now: yesterday)
    try store.transitionRun(runID: sessionRunB.id, to: .completed, reason: nil, now: today)
    try store.transitionRun(runID: otherRun.id, to: .completed, reason: nil, now: today)

    _ = try store.recordContextCompaction(
        runID: sessionRunA.id,
        droppedMessageCount: 2,
        retainedMessageCount: 4,
        estimatedTokenCount: 200,
        estimatedContextWindow: 8000,
        estimatedSavedTokenCount: 150,
        summary: "Older session compaction",
        now: yesterday
    )
    _ = try store.recordContextCompaction(
        runID: sessionRunB.id,
        droppedMessageCount: 3,
        retainedMessageCount: 5,
        estimatedTokenCount: 220,
        estimatedContextWindow: 8000,
        estimatedSavedTokenCount: 250,
        summary: "Current session compaction",
        now: today
    )
    _ = try store.recordContextCompaction(
        runID: otherRun.id,
        droppedMessageCount: 1,
        retainedMessageCount: 6,
        estimatedTokenCount: 120,
        estimatedContextWindow: 8000,
        estimatedSavedTokenCount: 90,
        summary: "Other thread compaction",
        now: today
    )

    let inspector = SessionInspector(persistence: store)
    let savings = try #require(try inspector.loadTokenSavings(runID: sessionRunB.id, now: now, calendar: calendar))
    #expect(savings.currentRun.savedTokenCount == 250)
    #expect(savings.today.savedTokenCount == 340)
    #expect(savings.session.savedTokenCount == 400)
    #expect(savings.total.savedTokenCount == 490)
}

@Test func sessionInspectorAggregatesUsedTokensAcrossRunScopes() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try store.initialize()

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    let now = Date(timeIntervalSince1970: 1_710_000_000)
    let today = now.addingTimeInterval(-3_600)
    let yesterday = now.addingTimeInterval(-90_000)

    let sessionThread = try store.createThread(now: yesterday)
    let otherThread = try store.createThread(now: yesterday)
    let sessionRunA = try store.createRun(threadID: sessionThread.id, state: .completed, now: yesterday)
    let sessionRunB = try store.createRun(threadID: sessionThread.id, state: .completed, now: today)
    let otherRun = try store.createRun(threadID: otherThread.id, state: .completed, now: today)
    try store.transitionRun(runID: sessionRunA.id, to: .completed, reason: nil, now: yesterday)
    try store.transitionRun(runID: sessionRunB.id, to: .completed, reason: nil, now: today)
    try store.transitionRun(runID: otherRun.id, to: .completed, reason: nil, now: today)

    try store.appendEvent(.init(payload: .contextPrepared(
        runID: sessionRunA.id,
        retainedMessages: 4,
        droppedMessages: 0,
        clippedMessages: 0,
        estimatedTokens: 180,
        estimatedContextWindow: 8_000
    )), runID: sessionRunA.id)
    try store.appendEvent(.init(payload: .contextPrepared(
        runID: sessionRunA.id,
        retainedMessages: 5,
        droppedMessages: 0,
        clippedMessages: 0,
        estimatedTokens: 220,
        estimatedContextWindow: 8_000
    )), runID: sessionRunA.id)
    try store.appendEvent(.init(payload: .contextPrepared(
        runID: sessionRunB.id,
        retainedMessages: 6,
        droppedMessages: 1,
        clippedMessages: 0,
        estimatedTokens: 340,
        estimatedContextWindow: 8_000
    )), runID: sessionRunB.id)
    try store.appendEvent(.init(payload: .contextPrepared(
        runID: otherRun.id,
        retainedMessages: 3,
        droppedMessages: 0,
        clippedMessages: 0,
        estimatedTokens: 90,
        estimatedContextWindow: 8_000
    )), runID: otherRun.id)

    let inspector = SessionInspector(persistence: store)
    let usage = try #require(try inspector.loadTokenUsage(runID: sessionRunB.id, now: now, calendar: calendar))
    #expect(usage.currentRun.usedTokenCount == 340)
    #expect(usage.today.usedTokenCount == 430)
    #expect(usage.session.usedTokenCount == 560)
    #expect(usage.total.usedTokenCount == 650)
}

@Test func tokenSavingsEstimatorSwitchesBetweenSavingsAndUsageModes() {
    #expect(TokenSavingsEstimator.costPresentationMode(provider: "ollama") == .savings)
    #expect(TokenSavingsEstimator.costPresentationMode(provider: "openai") == .usage)
    #expect(TokenSavingsEstimator.estimatedSavedMoneyUSD(for: 1_000_000, provider: "ollama", model: "gemma3:latest") > 0)
    #expect(TokenSavingsEstimator.estimatedUsageMoneyUSD(for: 1_000_000, provider: "openai", model: "gpt-5.4-mini") > 0)
}

@Test func localModelGuardrailKeepsSmallFunctionGemmaModelRunnable() {
    let assessment = LocalModelGuardrails.assessOllamaModel(
        model: "functiongemma:latest",
        installedModels: [
            .init(name: "functiongemma:latest", sizeBytes: 300_000_000)
        ],
        resources: HostResources(
            physicalMemoryBytes: 8_000_000_000,
            usableLocalModelMemoryBytes: 2_000_000_000,
            estimatedMemoryBandwidthGBps: 100,
            chipDescription: "Apple M-series",
            isUnifiedMemory: true
        )
    )

    #expect(assessment.severity == .ok)
    #expect((assessment.estimatedWorkingSetBytes ?? 0) < 1_000_000_000)
}

@Test func optimizationAdvisorPrefersTriattentionForFocusedLocalCodeTaskWithCalibration() {
    let resolution = ContextOptimizationAdvisor().resolve(
        taskKind: .feature,
        prompt: "Add a focused local code fix in the daemon runtime.",
        provider: "ollama",
        model: "qwen2.5-coder:7b",
        config: OptimizationConfig(enabled: true, backend: .esh, mode: .automatic, intent: .agentRun),
        calibrationAvailable: true
    )

    #expect(resolution.mode == .triattention)
}

@Test func optimizationAdvisorFallsBackToTurboWithoutCalibration() {
    let resolution = ContextOptimizationAdvisor().resolve(
        taskKind: .feature,
        prompt: "Add a focused local code fix in the daemon runtime.",
        provider: "ollama",
        model: "qwen2.5-coder:7b",
        config: OptimizationConfig(enabled: true, backend: .esh, mode: .automatic, intent: .agentRun),
        calibrationAvailable: false
    )

    #expect(resolution.mode == .turbo)
}

@Test func optimizationAdvisorKeepsRemoteProvidersInRawMode() {
    let resolution = ContextOptimizationAdvisor().resolve(
        taskKind: .feature,
        prompt: "Implement a remote provider feature and validate it.",
        provider: "openai",
        model: "gpt-5.4-mini",
        config: OptimizationConfig(enabled: true, backend: .esh, mode: .automatic, intent: .agentRun),
        calibrationAvailable: true
    )

    #expect(resolution.mode == .raw)
}

@Test func eshOptimizationInspectorComputesTriattentionCalibrationPath() {
    let inspector = EshOptimizationInspector(
        environment: ["PATH": "/opt/homebrew/bin:/usr/bin"],
        fileExists: { path in
            path == "/opt/homebrew/bin/esh" || path.hasSuffix("/compression/qwen2.5-coder_7b/triattention/triattention_calib.safetensors")
        }
    )
    let config = OptimizationConfig(
        enabled: true,
        backend: .esh,
        mode: .automatic,
        intent: .agentRun,
        esh: .init(homePath: "/tmp/.esh")
    )

    let report = inspector.doctor(
        provider: "ollama",
        model: "qwen2.5-coder:7b",
        taskKind: .feature,
        prompt: "Implement a focused code change.",
        config: config
    )

    #expect(report.executablePath == "/opt/homebrew/bin/esh")
    #expect(report.calibrationAvailable)
    #expect(report.calibrationPath == "/tmp/.esh/compression/qwen2.5-coder_7b/triattention/triattention_calib.safetensors")
    #expect(report.recommendedMode == .triattention)
}

@Test func cronScheduleComputesNextRunInRequestedTimezone() throws {
    let schedule = CronSchedule(expression: "0 9 * * 1-5", timeZoneIdentifier: "Asia/Jerusalem")
    let formatter = ISO8601DateFormatter()
    let base = try #require(formatter.date(from: "2026-04-14T05:30:00Z"))
    let next = try schedule.nextRunDate(after: base)
    let calendar = Calendar(identifier: .gregorian)
    let components = calendar.dateComponents(in: try #require(schedule.timeZone), from: next)

    #expect(components.hour == 9)
    #expect(components.minute == 0)
    #expect((components.weekday ?? 0) != 7)
}

@Test func cronJobStoreRoundTripsPersistedJobs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = SQLitePersistenceStore(databaseURL: root.appendingPathComponent("ashex.sqlite"))
    try store.initialize()
    let jobStore = CronJobStore(persistence: store)
    let createdAt = Date(timeIntervalSince1970: 1_710_000_000)
    let nextRunAt = createdAt.addingTimeInterval(3_600)
    let job = CronJobRecord(
        id: "daily-summary",
        prompt: "Summarize inbox",
        schedule: .init(expression: "0 9 * * *", timeZoneIdentifier: "Asia/Jerusalem"),
        createdAt: createdAt,
        nextRunAt: nextRunAt
    )

    try jobStore.save(job, now: createdAt)
    let loaded = try #require(try jobStore.job(id: "daily-summary"))
    #expect(loaded == job)
}

@Test func recentWorkspaceStoreRecordsMostRecentWorkspaceFirst() throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("recent-workspaces.json")

    try RecentWorkspaceStore.record(
        workspaceURL: URL(fileURLWithPath: "/tmp/project-a"),
        now: Date(timeIntervalSince1970: 10),
        at: fileURL
    )
    try RecentWorkspaceStore.record(
        workspaceURL: URL(fileURLWithPath: "/tmp/project-b"),
        now: Date(timeIntervalSince1970: 20),
        at: fileURL
    )
    try RecentWorkspaceStore.record(
        workspaceURL: URL(fileURLWithPath: "/tmp/project-a"),
        now: Date(timeIntervalSince1970: 30),
        at: fileURL
    )

    let records = try RecentWorkspaceStore.load(from: fileURL)
    #expect(records.count == 2)
    #expect(records.first?.path == "/tmp/project-a")
    #expect(records.last?.path == "/tmp/project-b")
}
