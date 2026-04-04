import Foundation

public struct FileSystemTool: Tool {
    public let name = "filesystem"
    public let description = "Read/write text files and list or create directories within the workspace"

    private let workspaceGuard: WorkspaceGuard

    public init(workspaceGuard: WorkspaceGuard) {
        self.workspaceGuard = workspaceGuard
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        try await context.cancellation.checkCancellation()

        guard let operation = arguments["operation"]?.stringValue else {
            throw AshexError.invalidToolArguments("filesystem.operation is required")
        }

        switch operation {
        case "read_text_file":
            let path = try requiredString("path", in: arguments)
            let url = try workspaceGuard.resolve(path: path)
            do {
                return .text(try String(contentsOf: url, encoding: .utf8))
            } catch {
                throw AshexError.fileSystem("Failed to read file \(path): \(error.localizedDescription)")
            }

        case "write_text_file":
            let path = try requiredString("path", in: arguments)
            let content = try requiredString("content", in: arguments)
            let createDirectories = arguments["create_directories"] == .bool(true)
            let url = try workspaceGuard.resolve(path: path)
            do {
                if createDirectories {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                }
                try content.write(to: url, atomically: true, encoding: .utf8)
                return .text("Wrote \(content.count) characters to \(path)")
            } catch {
                throw AshexError.fileSystem("Failed to write file \(path): \(error.localizedDescription)")
            }

        case "list_directory":
            let path = arguments["path"]?.stringValue ?? "."
            let url = try workspaceGuard.resolve(path: path)
            do {
                let entries = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
                let payload: JSONValue = .object([
                    "path": .string(path),
                    "entries": .array(entries.map(JSONValue.string)),
                ])
                return .structured(payload)
            } catch {
                throw AshexError.fileSystem("Failed to list directory \(path): \(error.localizedDescription)")
            }

        case "create_directory":
            let path = try requiredString("path", in: arguments)
            let url = try workspaceGuard.resolve(path: path)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return .text("Created directory \(path)")
            } catch {
                throw AshexError.fileSystem("Failed to create directory \(path): \(error.localizedDescription)")
            }

        default:
            throw AshexError.invalidToolArguments("Unsupported filesystem operation: \(operation)")
        }
    }

    private func requiredString(_ key: String, in arguments: JSONObject) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw AshexError.invalidToolArguments("filesystem.\(key) must be a non-empty string")
        }
        return value
    }
}
