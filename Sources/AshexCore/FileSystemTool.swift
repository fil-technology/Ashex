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
                let previousContent = try? String(contentsOf: url, encoding: .utf8)
                if createDirectories {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                }
                try content.write(to: url, atomically: true, encoding: .utf8)
                let payload: JSONValue = .object([
                    "operation": .string("write_text_file"),
                    "path": .string(path),
                    "status": .string("written"),
                    "bytes_written": .number(Double(content.count)),
                    "previous_exists": .bool(previousContent != nil),
                    "diff": .array(Self.diffPreview(old: previousContent ?? "", new: content).map(JSONValue.string)),
                ])
                return .structured(payload)
            } catch {
                throw AshexError.fileSystem("Failed to write file \(path): \(error.localizedDescription)")
            }

        case "list_directory":
            let path = arguments["path"]?.stringValue ?? "."
            let url = try workspaceGuard.resolve(path: path)
            do {
                let entryNames = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
                let children: [JSONValue] = entryNames.map { entry in
                    let childURL = url.appendingPathComponent(entry)
                    let isDirectory = (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    return .object([
                        "name": .string(entry),
                        "kind": .string(isDirectory ? "directory" : "file"),
                    ])
                }
                let payload: JSONValue = .object([
                    "path": .string(path),
                    "entries": .array(entryNames.map(JSONValue.string)),
                    "children": .array(children),
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

    private static func diffPreview(old: String, new: String) -> [String] {
        if old == new {
            return ["<no content changes>"]
        }

        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }

        var oldSuffix = oldLines.count
        var newSuffix = newLines.count
        while oldSuffix > prefix, newSuffix > prefix, oldLines[oldSuffix - 1] == newLines[newSuffix - 1] {
            oldSuffix -= 1
            newSuffix -= 1
        }

        let removed = Array(oldLines[prefix..<oldSuffix])
        let added = Array(newLines[prefix..<newSuffix])

        var diff = ["@@ -\(prefix + 1),\(removed.count) +\(prefix + 1),\(added.count) @@"]
        diff.append(contentsOf: removed.map { "- \($0)" })
        diff.append(contentsOf: added.map { "+ \($0)" })
        return diff
    }
}
