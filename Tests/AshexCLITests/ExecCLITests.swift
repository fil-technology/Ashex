@testable import AshexCLI
import AshexCore
import Foundation
import Testing

@Test func execOptionsUseSafeDefaults() throws {
    let options = try ExecRunOptions(arguments: ["ashex", "exec", "summarize this repo"])

    #expect(options.prompt == "summarize this repo")
    #expect(options.sandbox == nil)
    #expect(options.approval == nil)
    #expect(options.maxSteps == nil)
    #expect(options.json == false)
    #expect(options.dryRun == false)
}

@Test func execOptionsParseAliasesAndModels() throws {
    let fullAuto = try ExecRunOptions(arguments: [
        "ashex", "exec", "-C", "/tmp/project", "--full-auto", "--planner", "thinker", "--executor", "coder", "--vision", "vision", "--max-steps", "7", "fix tests",
    ])

    #expect(fullAuto.cwd == "/tmp/project")
    #expect(fullAuto.sandbox == .workspaceWrite)
    #expect(fullAuto.approval == .onRequest)
    #expect(fullAuto.planner == "thinker")
    #expect(fullAuto.executor == "coder")
    #expect(fullAuto.vision == "vision")
    #expect(fullAuto.maxSteps == 7)

    let yolo = try ExecRunOptions(arguments: ["ashex", "exec", "--yolo", "do it"])
    #expect(yolo.sandbox == .dangerFullAccess)
    #expect(yolo.approval == .never)
    #expect(yolo.yolo)
}

@Test func execTranscriptWritesJSONLines() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let writer = try ExecTranscriptWriter(storageRoot: root)

    try writer.write(type: "run_started", payload: ["cwd": .string("/tmp/demo")])
    try writer.write(type: "run_finished", payload: ["state": .string("completed")])

    let text = try String(contentsOf: writer.fileURL, encoding: .utf8)
    let lines = text.split(separator: "\n")

    #expect(lines.count == 2)
    #expect(lines[0].contains(#""type":"run_started""#))
    #expect(lines[1].contains(#""state":"completed""#))
    #expect(writer.fileURL.path.contains("/runs/"))
}

@Test func execConfigReadsProjectDefaults() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let configURL = root.appendingPathComponent("ashex.config.json")
    try """
    {
      "exec": {
        "default_sandbox": "workspace_write",
        "default_approval": "on_request",
        "max_steps": 5,
        "models": {
          "planner": "planner-model",
          "executor": "executor-model"
        }
      }
    }
    """.write(to: configURL, atomically: true, encoding: .utf8)

    let cli = try CLIConfiguration(arguments: ["ashex", "--workspace", root.path, "--provider", "mock"])
    let options = try ExecRunOptions(arguments: ["ashex", "exec", "inspect"])
    let config = ExecRunConfig(options: options, configuration: cli)

    #expect(config.sandbox == .workspaceWrite)
    #expect(config.approval == .onRequest)
    #expect(config.maxSteps == 5)
    #expect(config.plannerModel == "planner-model")
    #expect(config.executorModel == "executor-model")
}
