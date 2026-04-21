@testable import AshexCLI
import AshexCore
import Foundation
import Testing

@Test func parsesDaemonCommands() {
    #expect(DaemonCLICommand.parse(arguments: ["ashex", "daemon", "run"]) == .daemonRun([]))
    #expect(DaemonCLICommand.parse(arguments: ["ashex", "daemon", "start", "--workspace", "/tmp/demo"]) == .daemonStart(["--workspace", "/tmp/demo"]))
    #expect(DaemonCLICommand.parse(arguments: ["ashex", "daemon", "stop"]) == .daemonStop([]))
    #expect(DaemonCLICommand.parse(arguments: ["ashex", "daemon", "status"]) == .daemonStatus([]))
}

@Test func parsesTelegramTestCommand() {
    #expect(DaemonCLICommand.parse(arguments: ["ashex", "telegram", "test"]) == .telegramTest([]))
}

@Test func parsesCronCommands() {
    #expect(DaemonCLICommand.parse(arguments: ["ashex", "cron", "list"]) == .cronList([]))
    #expect(DaemonCLICommand.parse(arguments: ["ashex", "cron", "add", "--id", "daily"]) == .cronAdd(["--id", "daily"]))
    #expect(DaemonCLICommand.parse(arguments: ["ashex", "cron", "remove", "--id", "daily"]) == .cronRemove(["--id", "daily"]))
}

@Test func cliDetectsHelpBeforeTreatingItAsPrompt() {
    #expect(AshexCLI.isHelpRequested(arguments: ["ashex", "--help"]))
    #expect(AshexCLI.isHelpRequested(arguments: ["ashex", "-h"]))
    #expect(AshexCLI.helpText.contains("Usage:"))
}

@Test func defaultWorkspaceIsOutsideCurrentDirectory() {
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    let defaultWorkspace = CLIConfiguration.defaultWorkspaceRoot().standardizedFileURL

    #expect(defaultWorkspace.path != currentDirectory.path)
    #expect(defaultWorkspace.lastPathComponent == "DefaultWorkspace")
    #expect(defaultWorkspace.deletingLastPathComponent().lastPathComponent == "Ashex")
}

@Test func cliConfigurationUsesDFlashProviderDefaults() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    let configuration = try CLIConfiguration(arguments: ["ashex", "--workspace", workspace.path, "--provider", "dflash"])
    #expect(configuration.provider == "dflash")
    #expect(configuration.model == "Qwen/Qwen3.5-4B")
}

@Test func cliConfigurationCanForceOnboarding() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    let configuration = try CLIConfiguration(arguments: ["ashex", "--workspace", workspace.path, "onboard", "ignored prompt"])

    #expect(configuration.forceOnboarding)
    #expect(configuration.prompt == nil)
}

@Test func cliConfigurationSupportsOnboardingFlagAlias() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    let configuration = try CLIConfiguration(arguments: ["ashex", "--workspace", workspace.path, "--onboarding"])

    #expect(configuration.forceOnboarding)
    #expect(configuration.prompt == nil)
}

@Test func cliConfigurationUsesEshBridgeForEnabledOptimizedOllama() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    let config = AshexUserConfig(
        optimization: .init(
            enabled: true,
            backend: .esh,
            mode: .automatic,
            intent: .agentRun,
            esh: .init(
                executablePath: "/bin/echo",
                homePath: workspace.appendingPathComponent(".esh").path,
                repoRootPath: workspace.path
            )
        )
    )
    try UserConfigStore.write(config, to: workspace.appendingPathComponent(UserConfigStore.fileName))

    let configuration = try CLIConfiguration(arguments: ["ashex", "--workspace", workspace.path, "--provider", "ollama", "--model", "qwen2.5-coder:7b"])
    let adapter = try configuration.makeModelAdapter()

    #expect(adapter.name.hasPrefix("esh-bridge:ollama:qwen2.5-coder:7b"))
}
