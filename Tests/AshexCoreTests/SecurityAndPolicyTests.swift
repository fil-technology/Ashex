import AshexCore
import Foundation
import Testing

@Test func inMemorySecretStoreRoundTripsSecret() throws {
    let store = InMemorySecretStore()
    try store.writeSecret(namespace: "provider.credentials", key: "openai_api_key", value: "sk-test-123")

    #expect(try store.readSecret(namespace: "provider.credentials", key: "openai_api_key") == "sk-test-123")

    try store.deleteSecret(namespace: "provider.credentials", key: "openai_api_key")
    #expect(try store.readSecret(namespace: "provider.credentials", key: "openai_api_key") == nil)
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
