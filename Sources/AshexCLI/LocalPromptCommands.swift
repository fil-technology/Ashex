import Foundation

enum LocalPromptCommand: Equatable {
    case showWorkspace
    case showSandbox
    case showToolPacks
    case installToolPack(String)
    case uninstallToolPack(String)
    case switchWorkspace(String)
    case openWorkspaces
    case showHelp

    static func parse(_ prompt: String) -> LocalPromptCommand? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed {
        case "pwd", ":pwd", "/pwd":
            return .showWorkspace
        case "sandbox", ":sandbox", "/sandbox":
            return .showSandbox
        case "toolpacks", ":toolpacks", "/toolpacks":
            return .showToolPacks
        case ":workspaces", "/workspaces":
            return .openWorkspaces
        case ":workspace", "/workspace", "workspace", ":cd", "/cd", "cd", ":install-pack", "/install-pack", ":uninstall-pack", "/uninstall-pack":
            return .showHelp
        default:
            break
        }

        for prefix in [":workspace ", "/workspace ", "workspace ", ":cd ", "/cd ", "cd "] {
            if trimmed.hasPrefix(prefix) {
                let path = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? .showHelp : .switchWorkspace(path)
            }
        }

        for prefix in [":install-pack ", "/install-pack "] {
            if trimmed.hasPrefix(prefix) {
                let packID = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return packID.isEmpty ? .showHelp : .installToolPack(packID)
            }
        }

        for prefix in [":uninstall-pack ", "/uninstall-pack "] {
            if trimmed.hasPrefix(prefix) {
                let packID = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return packID.isEmpty ? .showHelp : .uninstallToolPack(packID)
            }
        }

        if trimmed.hasPrefix(":") || trimmed.hasPrefix("/") {
            return .showHelp
        }

        return nil
    }

    static var helpLines: [String] {
        [
            "[local] Workspace commands",
            "Use /workspace /full/path/to/project",
            "Aliases: :workspace /path, workspace /path, cd /path, /cd /path",
            "Show current workspace: /pwd",
            "Show sandbox policy: /sandbox",
            "List installable tool packs: /toolpacks",
            "Enable a bundled pack: /install-pack swiftpm",
            "Disable a bundled pack: /uninstall-pack swiftpm",
            "Open recent workspaces view: /workspaces",
        ]
    }
}
