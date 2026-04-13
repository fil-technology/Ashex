@testable import AshexCLI
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

@Test func cliConfigurationUsesDFlashProviderDefaults() throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    let configuration = try CLIConfiguration(arguments: ["ashex", "--workspace", workspace.path, "--provider", "dflash"])
    #expect(configuration.provider == "dflash")
    #expect(configuration.model == "Qwen/Qwen3.5-4B")
}
