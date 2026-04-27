import AshexCore
import Foundation
import Testing

@Test func browserExecutableDiscoveryPrefersConfiguredExecutable() {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? "#!/bin/sh\nexit 0\n".write(to: temporary, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)

    let resolved = BrowserExecutableDiscovery.resolveExecutable(
        configuredPath: temporary.path,
        defaultName: "obscura",
        environment: ["PATH": "/usr/bin:/bin"]
    )

    #expect(resolved == temporary.path)
}

@Test func browserExecutableDiscoveryFallsBackToPATHLookup() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bin = root.appendingPathComponent("obscura")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try? "#!/bin/sh\nexit 0\n".write(to: bin, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)

    let resolved = BrowserExecutableDiscovery.resolveExecutable(
        configuredPath: nil,
        defaultName: "obscura",
        environment: ["PATH": root.path]
    )

    #expect(resolved == bin.path)
}
