@testable import AshexCLI
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
