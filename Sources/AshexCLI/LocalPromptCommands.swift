import AshexCore
import Foundation

enum LocalPromptCommand: Equatable {
    case showWorkspace
    case showWorkspaceHelp
    case showLastRun
    case showSandbox
    case showToolPacks
    case installToolPack(String)
    case uninstallToolPack(String)
    case switchWorkspace(String)
    case showGenerationOptions
    case setGenerationOption(GenerationOptionCommand)
    case simpleWorkspace(SimpleWorkspaceCommand)
    case openWorkspaces
    case showHelp

    static func parse(_ prompt: String) -> LocalPromptCommand? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch trimmed {
        case "pwd", ":pwd", "/pwd":
            return .showWorkspace
        case "workspace", ":workspace", "/workspace":
            return .showWorkspaceHelp
        case "last", ":last", "/last":
            return .showLastRun
        case "sandbox", ":sandbox", "/sandbox":
            return .showSandbox
        case "toolpacks", ":toolpacks", "/toolpacks":
            return .showToolPacks
        case ":workspaces", "/workspaces":
            return .openWorkspaces
        case ":options", "/options", "options":
            return .showGenerationOptions
        case ":cd", "/cd", "cd", ":mkdir", "/mkdir", "mkdir", ":install-pack", "/install-pack", ":uninstall-pack", "/uninstall-pack":
            return .showHelp
        default:
            break
        }

        if let generationCommand = GenerationOptionCommand.parse(trimmed) {
            return .setGenerationOption(generationCommand)
        }

        if let simpleWorkspaceCommand = SimpleWorkspaceCommand.parse(trimmed) {
            return .simpleWorkspace(simpleWorkspaceCommand)
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
            "Show workspace command help: /workspace",
            "Inspect the latest run: /last",
            "List files: /ls [path]",
            "Create a folder: /mkdir path",
            "Show sandbox policy: /sandbox",
            "List installable tool packs: /toolpacks",
            "Enable a bundled pack: /install-pack swiftpm",
            "Disable a bundled pack: /uninstall-pack swiftpm",
            "Open recent workspaces view: /workspaces",
            "Show model options: /options",
            "Set model options: /temperature 0.7, /top-p 0.9, /top-k 40, /min-p 0.05, /repetition-penalty 1.1, /seed 42",
            "Merge raw provider options: /options {\"mirostat\":1}",
        ]
    }
}

enum GenerationOptionCommand: Equatable {
    case temperature(Double?)
    case topP(Double?)
    case topK(Int?)
    case minP(Double?)
    case repetitionPenalty(Double?)
    case seed(Int?)
    case rawOptions(String)

    static func parse(_ prompt: String) -> GenerationOptionCommand? {
        let commands: [(String, (String) -> GenerationOptionCommand?)] = [
            ("temperature", { .temperature(parseOptionalDouble($0)) }),
            ("top-p", { .topP(parseOptionalDouble($0)) }),
            ("top_k", { .topK(parseOptionalInt($0)) }),
            ("top-k", { .topK(parseOptionalInt($0)) }),
            ("min-p", { .minP(parseOptionalDouble($0)) }),
            ("repetition-penalty", { .repetitionPenalty(parseOptionalDouble($0)) }),
            ("seed", { .seed(parseOptionalInt($0)) }),
            ("options", { value in value.isEmpty ? nil : .rawOptions(value) }),
        ]

        for (name, makeCommand) in commands {
            for prefix in ["/\(name) ", ":\(name) ", "\(name) "] {
                guard prompt.hasPrefix(prefix) else { continue }
                let value = String(prompt.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                return makeCommand(value)
            }
        }
        return nil
    }

    private static func parseOptionalDouble(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "default", trimmed.lowercased() != "reset", trimmed.lowercased() != "null" else {
            return nil
        }
        return Double(trimmed)
    }

    private static func parseOptionalInt(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "default", trimmed.lowercased() != "reset", trimmed.lowercased() != "null" else {
            return nil
        }
        return Int(trimmed)
    }
}
