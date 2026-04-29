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
    #expect(LocalPromptCommand.parse("/options") == .showGenerationOptions)
    #expect(LocalPromptCommand.parse("/temperature 0.8") == .setGenerationOption(.temperature(0.8)))
    #expect(LocalPromptCommand.parse("/top-p 0.9") == .setGenerationOption(.topP(0.9)))
    #expect(LocalPromptCommand.parse("/top-k 40") == .setGenerationOption(.topK(40)))
    #expect(LocalPromptCommand.parse("/min-p 0.05") == .setGenerationOption(.minP(0.05)))
    #expect(LocalPromptCommand.parse("/repetition-penalty 1.1") == .setGenerationOption(.repetitionPenalty(1.1)))
    #expect(LocalPromptCommand.parse("/seed 42") == .setGenerationOption(.seed(42)))
    #expect(LocalPromptCommand.parse("/options {\"mirostat\":1}") == .setGenerationOption(.rawOptions("{\"mirostat\":1}")))
    #expect(LocalPromptCommand.parse(":workspace") == .showWorkspaceHelp)
}
