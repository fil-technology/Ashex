@testable import AshexCLI
import Foundation
import Testing

@Test func browserCLIHelpMentionsFetchAndDoctor() {
    #expect(BrowserCLI.helpText.contains("ashex browser fetch <url>"))
    #expect(BrowserCLI.helpText.contains("ashex browser doctor"))
    #expect(BrowserCLI.helpText.contains("ashex browser test-local"))
}

@Test func configCLIHelpMentionsConfigSet() {
    #expect(ConfigCLI.helpText.contains("ashex config set"))
    #expect(ConfigCLI.helpText.contains("ashex config paths"))
    #expect(ConfigCLI.helpText.contains("--global"))
}

@Test func toolsCLIHelpMentionsListAndDoctor() {
    #expect(ToolsCLI.helpText.contains("ashex tools list"))
    #expect(ToolsCLI.helpText.contains("ashex tools doctor"))
}

@Test func graphifyCLIHelpMentionsStatusAndQuery() {
    #expect(GraphifyCLI.helpText.contains("ashex graphify build"))
    #expect(GraphifyCLI.helpText.contains("ashex graphify status"))
    #expect(GraphifyCLI.helpText.contains("ashex graphify query"))
    #expect(GraphifyCLI.helpText.contains("ashex graphify clean --yes"))
    #expect(AshexCLI.helpText.contains("ashex graphify"))
}

@Test func subagentsCLIHelpMentionsListAndDoctor() {
    #expect(SubagentsCLI.helpText.contains("ashex subagents list"))
    #expect(SubagentsCLI.helpText.contains("ashex subagents doctor"))
}

@Test func computerNamespaceAliasesComputerUseDoctor() {
    #expect(ComputerUseCLICommand.parse(arguments: ["ashex", "computer", "doctor"]) == .doctor([]))
    #expect(ComputerUseCLICommand.parse(arguments: ["ashex", "computer-use", "doctor"]) == .doctor([]))
}

@Test func validateCLIClaimsValidateNamespace() throws {
    #expect(ValidateCLI.helpText.contains("ashex validate agent-capabilities"))
    #expect(throws: Error.self) {
        try ValidateCLI.handle(arguments: ["ashex", "validate", "agent-capabilities"])
    }
}
