import Foundation

struct ValidationAction: Sendable, Equatable {
    let summary: String
    let call: ToolCallRequest
}

enum ValidationStrategy {
    static func plan(
        request: String,
        taskKind: TaskKind,
        changedFiles: [String],
        workspaceSnapshot: WorkspaceSnapshotRecord?,
        availableToolNames: Set<String>
    ) -> [ValidationAction] {
        let normalizedChangedFiles = changedFiles.filter { !$0.hasPrefix("<") }
        var actions: [ValidationAction] = []

        if availableToolNames.contains("git"),
           workspaceSnapshot?.gitBranch != nil || workspaceSnapshot?.gitStatusSummary != nil || taskKind == .git {
            actions.append(.init(
                summary: "Inspect the current git diff for the changed work.",
                call: .init(toolName: "git", arguments: ["operation": .string("diff_unstaged")])
            ))
            actions.append(.init(
                summary: "Confirm repository status after the changes.",
                call: .init(toolName: "git", arguments: ["operation": .string("status")])
            ))
        }

        if availableToolNames.contains("filesystem") {
            for path in normalizedChangedFiles.prefix(2) {
                actions.append(.init(
                    summary: "Read back \(path) to confirm the applied changes.",
                    call: .init(toolName: "filesystem", arguments: [
                        "operation": .string("read_text_file"),
                        "path": .string(path),
                    ])
                ))
            }
        }

        if availableToolNames.contains("shell"),
           let shellAction = shellValidationAction(
                request: request,
                taskKind: taskKind,
                changedFiles: normalizedChangedFiles,
                workspaceSnapshot: workspaceSnapshot
           ) {
            actions.append(shellAction)
        }

        var seen: Set<String> = []
        return actions.filter {
            seen.insert("\($0.call.toolName):\(JSONValue.object($0.call.arguments).prettyPrinted)").inserted
        }
    }

    private static func shellValidationAction(
        request: String,
        taskKind: TaskKind,
        changedFiles: [String],
        workspaceSnapshot: WorkspaceSnapshotRecord?
    ) -> ValidationAction? {
        let lowered = request.lowercased()
        let topLevelEntries = workspaceSnapshot?.topLevelEntries ?? []
        let hasPackageSwift = topLevelEntries.contains("Package.swift")
        let hasTests = topLevelEntries.contains(where: { $0.hasPrefix("Tests") })
        let touchedSwift = changedFiles.contains { $0.hasSuffix(".swift") || $0 == "Package.swift" }
        let wantsTests = lowered.contains("test") || lowered.contains("bug") || lowered.contains("fix") || taskKind == .bugFix
        let wantsBuild = lowered.contains("build") || lowered.contains("compile") || touchedSwift || taskKind == .feature || taskKind == .refactor

        if hasPackageSwift && (wantsTests || (hasTests && touchedSwift)) {
            return .init(
                summary: "Run `swift test` to validate the changed Swift package code.",
                call: .init(toolName: "shell", arguments: [
                    "command": .string("swift test"),
                    "timeout_seconds": .number(120),
                ])
            )
        }

        if hasPackageSwift && wantsBuild {
            return .init(
                summary: "Run `swift build` to validate the changed Swift package code.",
                call: .init(toolName: "shell", arguments: [
                    "command": .string("swift build"),
                    "timeout_seconds": .number(120),
                ])
            )
        }

        return nil
    }
}
