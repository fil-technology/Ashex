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
    #expect(LocalPromptCommand.parse("/workspace") == .showWorkspaceHelp)
    #expect(LocalPromptCommand.parse("/last") == .showLastRun)
    #expect(LocalPromptCommand.parse("/ls") == .simpleWorkspace(.listDirectory(path: ".")))
    #expect(LocalPromptCommand.parse("/ls Sources") == .simpleWorkspace(.listDirectory(path: "Sources")))
    #expect(LocalPromptCommand.parse("list files") == nil)
    #expect(LocalPromptCommand.parse("/mkdir Reports") == .simpleWorkspace(.createDirectory(path: "Reports")))
    #expect(LocalPromptCommand.parse("create a folder named Reports") == nil)
    #expect(LocalPromptCommand.parse("/sandbox") == .showSandbox)
    #expect(LocalPromptCommand.parse("/toolpacks") == .showToolPacks)
    #expect(LocalPromptCommand.parse("/install-pack swiftpm") == .installToolPack("swiftpm"))
    #expect(LocalPromptCommand.parse("/uninstall-pack python") == .uninstallToolPack("python"))
    #expect(LocalPromptCommand.parse("/workspaces") == .openWorkspaces)
    #expect(LocalPromptCommand.parse(":workspace") == .showWorkspaceHelp)
}
