@testable import AshexCLI
import Testing

@Test func parsesWorkspaceSwitchCommands() {
    #expect(LocalPromptCommand.parse("/workspace /tmp/project") == .switchWorkspace("/tmp/project"))
    #expect(LocalPromptCommand.parse(":workspace /tmp/project") == .switchWorkspace("/tmp/project"))
    #expect(LocalPromptCommand.parse("workspace /tmp/project") == .switchWorkspace("/tmp/project"))
    #expect(LocalPromptCommand.parse("cd /tmp/project") == .switchWorkspace("/tmp/project"))
    #expect(LocalPromptCommand.parse("/cd /tmp/project") == .switchWorkspace("/tmp/project"))
}

@Test func parsesWorkspaceHelperCommands() {
    #expect(LocalPromptCommand.parse("/pwd") == .showWorkspace)
    #expect(LocalPromptCommand.parse("pwd") == .showWorkspace)
    #expect(LocalPromptCommand.parse("/sandbox") == .showSandbox)
    #expect(LocalPromptCommand.parse("/workspaces") == .openWorkspaces)
    #expect(LocalPromptCommand.parse(":workspace") == .showHelp)
    #expect(LocalPromptCommand.parse("/workspace") == .showHelp)
}
