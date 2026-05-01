import AshexCore
import Testing

@Test func subAgentRegistrySkipsDisabledDefinitionsWhenCheckingMissingTools() {
    let definitions = SubAgentRegistry.builtInDefinitions(computerUseEnabled: false)
    let report = SubAgentRegistry.diagnose(
        definitions: definitions,
        availableToolNames: ["browser_fetch", "browser_extract", "browser_eval", "filesystem", "git", "shell", "build", "swiftpm"],
        workspaceLeaseCount: 0
    )

    #expect(report.status == .pass)
    #expect(report.definitions.first(where: { $0.name == "computer-operator" })?.enabled == false)
    #expect(report.missingToolIssues.isEmpty)
}
