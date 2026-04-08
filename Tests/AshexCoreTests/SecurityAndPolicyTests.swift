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
