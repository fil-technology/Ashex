import Foundation

public enum SimpleWorkspaceCommand: Sendable, Equatable {
    case listDirectory(path: String)
    case listFolders(path: String)
    case createDirectory(path: String)

    public static func parse(_ text: String) -> SimpleWorkspaceCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if ["ls", "/ls", ":ls"].contains(lowered) {
            return .listDirectory(path: ".")
        }

        for prefix in ["/ls ", ":ls ", "ls "] {
            if lowered.hasPrefix(prefix) {
                return .listDirectory(path: cleanPath(String(trimmed.dropFirst(prefix.count))))
            }
        }

        for prefix in ["/folders ", ":folders ", "folders "] {
            if lowered.hasPrefix(prefix) {
                return .listFolders(path: cleanPath(String(trimmed.dropFirst(prefix.count))))
            }
        }

        if ["/folders", ":folders", "folders"].contains(lowered) {
            return .listFolders(path: ".")
        }

        for prefix in ["/mkdir ", ":mkdir ", "mkdir "] {
            if lowered.hasPrefix(prefix) {
                let path = cleanPath(String(trimmed.dropFirst(prefix.count)))
                return path.isEmpty ? nil : .createDirectory(path: path)
            }
        }

        return nil
    }

    private static func cleanPath(_ raw: String) -> String {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch cleaned.lowercased() {
        case "here", "current directory", "the current directory", "current workspace", "the current workspace":
            return "."
        default:
            return cleaned
        }
    }
}

public enum SimpleWorkspaceCommandExecutor {
    public static func execute(
        _ command: SimpleWorkspaceCommand,
        workspaceRoot: URL,
        sandbox: SandboxPolicyConfig,
        mutationDeniedReason: String? = nil
    ) throws -> String {
        switch command {
        case .listDirectory(let path):
            return try listDirectory(path: path, directoriesOnly: false, workspaceRoot: workspaceRoot, sandbox: sandbox)
        case .listFolders(let path):
            return try listDirectory(path: path, directoriesOnly: true, workspaceRoot: workspaceRoot, sandbox: sandbox)
        case .createDirectory(let path):
            return try createDirectory(
                path: path,
                workspaceRoot: workspaceRoot,
                sandbox: sandbox,
                mutationDeniedReason: mutationDeniedReason
            )
        }
    }

    public static func workspaceStatus(workspaceRoot: URL) -> String {
        """
        Current workspace:
        \(workspaceRoot.path)

        Filesystem tools are sandboxed to this root.
        """
    }

    public static func workspaceHelp(workspaceRoot: URL, startupCommand: String? = nil) -> String {
        var lines = [
            "Current workspace:",
            workspaceRoot.path,
            "",
            "Use `/pwd` to show this path.",
            "Use `/ls [path]` to list files.",
            "Use `/mkdir path` to create a folder when mutation is allowed.",
        ]
        if let startupCommand {
            lines.append("")
            lines.append("To use a different daemon workspace, restart it with:")
            lines.append(startupCommand)
        }
        return lines.joined(separator: "\n")
    }

    private static func listDirectory(path: String, directoriesOnly: Bool, workspaceRoot: URL, sandbox: SandboxPolicyConfig) throws -> String {
        let displayPath = path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "." : path
        let guardrail = WorkspaceGuard(rootURL: workspaceRoot, sandbox: sandbox)
        let url = try guardrail.resolve(path: displayPath)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        let entries = names.compactMap { name -> String? in
            let childURL = url.appendingPathComponent(name)
            let isDirectory = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if directoriesOnly, !isDirectory {
                return nil
            }
            return "\(isDirectory ? "dir" : "file") \(name)"
        }
        let renderedEntries = entries.isEmpty
            ? "(empty)"
            : entries.joined(separator: "\n")
        return """
        Workspace: \(workspaceRoot.path)
        Path: \(displayPath)

        \(renderedEntries)
        """
    }

    private static func createDirectory(
        path rawPath: String,
        workspaceRoot: URL,
        sandbox: SandboxPolicyConfig,
        mutationDeniedReason: String?
    ) throws -> String {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return "Tell me the folder path to create, for example `/mkdir notes`."
        }
        if let mutationDeniedReason {
            return mutationDeniedReason
        }

        let guardrail = WorkspaceGuard(rootURL: workspaceRoot, sandbox: sandbox)
        let url = try guardrail.resolveForMutation(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return """
        Created folder:
        \(path)

        Workspace:
        \(workspaceRoot.path)
        """
    }
}
