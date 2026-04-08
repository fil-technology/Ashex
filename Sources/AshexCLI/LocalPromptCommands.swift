import Foundation

enum LocalPromptCommand: Equatable {
    case showWorkspace
    case showSandbox
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
        case ":workspaces", "/workspaces":
            return .openWorkspaces
        case ":workspace", "/workspace", "workspace", ":cd", "/cd", "cd":
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
            "Open recent workspaces view: /workspaces",
        ]
    }
}
