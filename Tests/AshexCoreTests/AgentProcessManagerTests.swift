import AshexCore
import Foundation
import Testing

@Test func processManagerRegistersProcessesAndPersistsLogsAndWrites() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let manager = AgentProcessManager(storageRoot: root)

    let process = try manager.register(command: ["swift", "test"], workingDirectory: "/tmp/project", id: "proc-1")
    try manager.appendLog(processID: process.id, stream: .stdout, text: "building")
    try manager.write(processID: process.id, text: "yes\n")

    #expect(try manager.list().map(\.id) == ["proc-1"])
    #expect(try manager.log(processID: "proc-1").map(\.text) == ["building"])
    #expect(try manager.writes(processID: "proc-1").map(\.text) == ["yes\n"])
}

@Test func processManagerPollWaitAndKillUseStoredMetadataWithoutSpawning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let driver = AgentProcessDriver(
        poll: { process in
            process.pollCount == 0
                ? .running
                : .exited(exitCode: 0)
        },
        kill: { _ in .killed }
    )
    let manager = AgentProcessManager(storageRoot: root, driver: driver)
    _ = try manager.register(command: ["sleep", "999"], workingDirectory: "/tmp/project", id: "proc-2")

    #expect(try manager.poll(processID: "proc-2").status == .running)

    let waited = try manager.wait(processID: "proc-2", maxPolls: 2)
    #expect(waited.status == .exited)
    #expect(waited.exitCode == 0)

    let killed = try manager.kill(processID: "proc-2")
    #expect(killed.status == .killed)
}
