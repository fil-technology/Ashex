import AshexCore
import Foundation
import Testing

@Test func subagentWorkspaceManagerCreatesSharedReadOnlyLease() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let storage = root.appendingPathComponent(".ashex")
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

    let manager = SubagentWorkspaceManager(storageRoot: storage, workspaceRoot: workspace)
    let runID = UUID()
    let lease = try manager.createLease(runID: runID, title: "Inspect Runtime")

    #expect(lease.mode == .sharedReadOnly)
    #expect(lease.runID == runID)
    #expect(lease.workspacePath == workspace.standardizedFileURL.path)
    let leases = try manager.listLeases()
    #expect(leases.count == 1)
    #expect(leases.first?.id == lease.id)
}

@Test func subagentWorkspaceManagerCopiesWorkspaceWithoutHeavyState() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let storage = root.appendingPathComponent(".ashex")
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "hello".write(to: workspace.appendingPathComponent("Sources/main.swift"), atomically: true, encoding: .utf8)
    try "ignored".write(to: workspace.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)

    let manager = SubagentWorkspaceManager(storageRoot: storage, workspaceRoot: workspace)
    let lease = try manager.createLease(runID: UUID(), title: "Writable lane", mode: .copiedWritable)
    let copiedRoot = URL(fileURLWithPath: lease.workspacePath, isDirectory: true)

    #expect(lease.mode == .copiedWritable)
    #expect(FileManager.default.fileExists(atPath: copiedRoot.appendingPathComponent("Sources/main.swift").path))
    #expect(!FileManager.default.fileExists(atPath: copiedRoot.appendingPathComponent(".git/config").path))
}
