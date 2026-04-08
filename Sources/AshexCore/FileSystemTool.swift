import Foundation

public struct FileSystemTool: Tool {
    public let name = "filesystem"
    public let description = "Inspect, search, edit, move, copy, and delete files or directories within the workspace"

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
            let url = try workspaceGuard.resolveForMutation(path: path)
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

        case "replace_in_file":
            let path = try requiredString("path", in: arguments)
            let oldText = try requiredString("old_text", in: arguments)
            let newText = arguments["new_text"]?.stringValue ?? ""
            let replaceAll = arguments["replace_all"] == .bool(true)
            let url = try workspaceGuard.resolveForMutation(path: path)
            do {
                let original = try String(contentsOf: url, encoding: .utf8)
                let updated: String
                if replaceAll {
                    updated = original.replacingOccurrences(of: oldText, with: newText)
                } else {
                    guard let range = original.range(of: oldText) else {
                        throw AshexError.fileSystem("Could not find requested text in \(path)")
                    }
                    updated = original.replacingCharacters(in: range, with: newText)
                }

                guard updated != original else {
                    return .structured(.object([
                        "operation": .string("replace_in_file"),
                        "path": .string(path),
                        "status": .string("unchanged"),
                        "diff": .array([.string("<no content changes>")]),
                    ]))
                }

                try updated.write(to: url, atomically: true, encoding: .utf8)
                return .structured(.object([
                    "operation": .string("replace_in_file"),
                    "path": .string(path),
                    "status": .string("updated"),
                    "replace_all": .bool(replaceAll),
                    "diff": .array(Self.diffPreview(old: original, new: updated).map(JSONValue.string)),
                ]))
            } catch {
                throw AshexError.fileSystem("Failed to replace text in \(path): \(error.localizedDescription)")
            }

        case "apply_patch":
            let path = try requiredString("path", in: arguments)
            let edits = try requiredPatchEdits(in: arguments)
            let url = try workspaceGuard.resolveForMutation(path: path)
            do {
                let original = try String(contentsOf: url, encoding: .utf8)
                var updated = original
                var appliedEdits: [JSONValue] = []

                for edit in edits {
                    let replacementCount = updated.components(separatedBy: edit.oldText).count - 1
                    guard replacementCount > 0 else {
                        throw AshexError.fileSystem("Could not find requested patch text in \(path)")
                    }

                    if edit.replaceAll {
                        updated = updated.replacingOccurrences(of: edit.oldText, with: edit.newText)
                    } else {
                        guard let range = updated.range(of: edit.oldText) else {
                            throw AshexError.fileSystem("Could not find requested patch text in \(path)")
                        }
                        updated = updated.replacingCharacters(in: range, with: edit.newText)
                    }

                    appliedEdits.append(.object([
                        "old_text": .string(edit.oldText),
                        "new_text": .string(edit.newText),
                        "replace_all": .bool(edit.replaceAll),
                    ]))
                }

                guard updated != original else {
                    return .structured(.object([
                        "operation": .string("apply_patch"),
                        "path": .string(path),
                        "status": .string("unchanged"),
                        "applied_edits": .array(appliedEdits),
                        "diff": .array([.string("<no content changes>")]),
                    ]))
                }

                try updated.write(to: url, atomically: true, encoding: .utf8)
                return .structured(.object([
                    "operation": .string("apply_patch"),
                    "path": .string(path),
                    "status": .string("patched"),
                    "edit_count": .number(Double(edits.count)),
                    "applied_edits": .array(appliedEdits),
                    "diff": .array(Self.diffPreview(old: original, new: updated).map(JSONValue.string)),
                ]))
            } catch {
                throw AshexError.fileSystem("Failed to apply patch in \(path): \(error.localizedDescription)")
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
            let url = try workspaceGuard.resolveForMutation(path: path)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return .text("Created directory \(path)")
            } catch {
                throw AshexError.fileSystem("Failed to create directory \(path): \(error.localizedDescription)")
            }

        case "delete_path":
            let path = try requiredString("path", in: arguments)
            let url = try workspaceGuard.resolveForMutation(path: path)
            do {
                try FileManager.default.removeItem(at: url)
                return .structured(.object([
                    "operation": .string("delete_path"),
                    "path": .string(path),
                    "status": .string("deleted"),
                ]))
            } catch {
                throw AshexError.fileSystem("Failed to delete \(path): \(error.localizedDescription)")
            }

        case "move_path":
            let sourcePath = try requiredString("source_path", in: arguments)
            let destinationPath = try requiredString("destination_path", in: arguments)
            let sourceURL = try workspaceGuard.resolveForMutation(path: sourcePath)
            let destinationURL = try workspaceGuard.resolveForMutation(path: destinationPath)
            do {
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                return .structured(.object([
                    "operation": .string("move_path"),
                    "source_path": .string(sourcePath),
                    "destination_path": .string(destinationPath),
                    "status": .string("moved"),
                ]))
            } catch {
                throw AshexError.fileSystem("Failed to move \(sourcePath) to \(destinationPath): \(error.localizedDescription)")
            }

        case "copy_path":
            let sourcePath = try requiredString("source_path", in: arguments)
            let destinationPath = try requiredString("destination_path", in: arguments)
            let sourceURL = try workspaceGuard.resolve(path: sourcePath)
            let destinationURL = try workspaceGuard.resolveForMutation(path: destinationPath)
            do {
                try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                return .structured(.object([
                    "operation": .string("copy_path"),
                    "source_path": .string(sourcePath),
                    "destination_path": .string(destinationPath),
                    "status": .string("copied"),
                ]))
            } catch {
                throw AshexError.fileSystem("Failed to copy \(sourcePath) to \(destinationPath): \(error.localizedDescription)")
            }

        case "file_info":
            let path = arguments["path"]?.stringValue ?? "."
            let url = try workspaceGuard.resolve(path: path)
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                return .structured(.object([
                    "operation": .string("file_info"),
                    "path": .string(path),
                    "exists": .bool(FileManager.default.fileExists(atPath: url.path)),
                    "is_directory": .bool(values.isDirectory == true),
                    "size_bytes": .number(Double(values.fileSize ?? 0)),
                    "modified_at": .string(values.contentModificationDate?.ISO8601Format() ?? ""),
                ]))
            } catch {
                throw AshexError.fileSystem("Failed to inspect \(path): \(error.localizedDescription)")
            }

        case "find_files":
            let path = arguments["path"]?.stringValue ?? "."
            let query = try requiredString("query", in: arguments)
            let maxResults = arguments["max_results"]?.intValue ?? 100
            let rootURL = try workspaceGuard.resolve(path: path)
            do {
                let matches = try findFiles(rootURL: rootURL, basePath: path, query: query, maxResults: maxResults)
                return .structured(.object([
                    "operation": .string("find_files"),
                    "path": .string(path),
                    "query": .string(query),
                    "matches": .array(matches.map(JSONValue.string)),
                ]))
            } catch {
                throw AshexError.fileSystem("Failed to search files in \(path): \(error.localizedDescription)")
            }

        case "search_text":
            let path = arguments["path"]?.stringValue ?? "."
            let query = try requiredString("query", in: arguments)
            let maxResults = arguments["max_results"]?.intValue ?? 50
            let rootURL = try workspaceGuard.resolve(path: path)
            do {
                let matches = try searchText(rootURL: rootURL, basePath: path, query: query, maxResults: maxResults)
                return .structured(.object([
                    "operation": .string("search_text"),
                    "path": .string(path),
                    "query": .string(query),
                    "matches": .array(matches.map { match in
                        .object([
                            "path": .string(match.path),
                            "line": .number(Double(match.line)),
                            "text": .string(match.text),
                        ])
                    }),
                ]))
            } catch {
                throw AshexError.fileSystem("Failed to search text in \(path): \(error.localizedDescription)")
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

    private func requiredPatchEdits(in arguments: JSONObject) throws -> [PatchEdit] {
        if let edits = arguments["edits"]?.arrayValue {
            let parsed = try edits.map(parsePatchEdit(_:))
            guard !parsed.isEmpty else {
                throw AshexError.invalidToolArguments("filesystem.edits must contain at least one patch edit")
            }
            return parsed
        }

        if let oldText = arguments["old_text"]?.stringValue {
            return [
                PatchEdit(
                    oldText: oldText,
                    newText: arguments["new_text"]?.stringValue ?? "",
                    replaceAll: arguments["replace_all"]?.boolValue == true
                )
            ]
        }

        throw AshexError.invalidToolArguments("filesystem.apply_patch requires edits or old_text/new_text")
    }

    private func parsePatchEdit(_ value: JSONValue) throws -> PatchEdit {
        guard let object = value.objectValue else {
            throw AshexError.invalidToolArguments("filesystem.edits entries must be objects")
        }
        guard let oldText = object["old_text"]?.stringValue, !oldText.isEmpty else {
            throw AshexError.invalidToolArguments("filesystem.edits.old_text must be a non-empty string")
        }
        return PatchEdit(
            oldText: oldText,
            newText: object["new_text"]?.stringValue ?? "",
            replaceAll: object["replace_all"]?.boolValue == true
        )
    }

    private func findFiles(rootURL: URL, basePath: String, query: String, maxResults: Int) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var matches: [String] = []
        let lowered = query.lowercased()
        for case let fileURL as URL in enumerator {
            let relative = fileURL.path.replacingOccurrences(of: workspaceGuard.rootURL.path + "/", with: "")
            if relative.lowercased().contains(lowered) {
                matches.append(relative)
            }
            if matches.count >= maxResults { break }
        }
        return matches
    }

    private func searchText(rootURL: URL, basePath: String, query: String, maxResults: Int) throws -> [(path: String, line: Int, text: String)] {
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var matches: [(String, Int, String)] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let relative = fileURL.path.replacingOccurrences(of: workspaceGuard.rootURL.path + "/", with: "")
            for (index, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if line.localizedCaseInsensitiveContains(query) {
                    matches.append((relative, index + 1, String(line)))
                    if matches.count >= maxResults { return matches }
                }
            }
        }
        return matches
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

private struct PatchEdit {
    let oldText: String
    let newText: String
    let replaceAll: Bool
}
