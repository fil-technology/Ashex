import Foundation

public struct ValidationAction: Sendable, Equatable {
    public let summary: String
    public let call: ToolCallRequest

    public init(summary: String, call: ToolCallRequest) {
        self.summary = summary
        self.call = call
    }
}

public enum ValidationStrategy {
    private struct WorkspaceMarkers {
        let topLevelEntries: Set<String>
        let projectMarkers: Set<String>
        let hasPackageSwift: Bool
        let hasTests: Bool
        let hasPackageJSON: Bool
        let hasPnpmLock: Bool
        let hasYarnLock: Bool
        let hasCargoToml: Bool
        let hasGoMod: Bool
        let xcodeWorkspace: String?
        let xcodeProject: String?

        init(snapshot: WorkspaceSnapshotRecord?) {
            let entries = Set((snapshot?.topLevelEntries ?? []).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) })
            let markers = Set(snapshot?.projectMarkers ?? [])
            self.topLevelEntries = entries
            self.projectMarkers = markers
            self.hasPackageSwift = entries.contains("Package.swift")
            self.hasTests = entries.contains(where: { $0.hasPrefix("Tests") })
            self.hasPackageJSON = entries.contains("package.json")
            self.hasPnpmLock = entries.contains("pnpm-lock.yaml")
            self.hasYarnLock = entries.contains("yarn.lock")
            self.hasCargoToml = entries.contains("Cargo.toml")
            self.hasGoMod = entries.contains("go.mod")
            self.xcodeWorkspace = markers.first(where: { $0.hasSuffix(".xcworkspace") })
            self.xcodeProject = markers.first(where: { $0.hasSuffix(".xcodeproj") })
        }
    }

    public static func plan(
        request: String,
        taskKind: TaskKind,
        changedFiles: [String],
        workspaceSnapshot: WorkspaceSnapshotRecord?,
        availableToolNames: Set<String>
    ) -> [ValidationAction] {
        let normalizedChangedFiles = changedFiles.filter { !$0.hasPrefix("<") }
        let markers = WorkspaceMarkers(snapshot: workspaceSnapshot)
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
            for path in normalizedChangedFiles.prefix(3) {
                actions.append(.init(
                    summary: "Read back \(path) to confirm the applied changes.",
                    call: .init(toolName: "filesystem", arguments: [
                        "operation": .string("read_text_file"),
                        "path": .string(path),
                    ])
                ))
            }
        }

        if availableToolNames.contains("build") {
            actions.append(contentsOf: buildValidationActions(
                request: request,
                taskKind: taskKind,
                changedFiles: normalizedChangedFiles,
                markers: markers
            ))
        }

        if availableToolNames.contains("shell") {
            actions.append(contentsOf: shellValidationActions(
                request: request,
                taskKind: taskKind,
                changedFiles: normalizedChangedFiles,
                markers: markers,
                skippingSwiftAndXcode: availableToolNames.contains("build")
            ))
        }

        var seen: Set<String> = []
        return actions.filter {
            seen.insert("\($0.call.toolName):\(JSONValue.object($0.call.arguments).prettyPrinted)").inserted
        }
    }

    private static func buildValidationActions(
        request: String,
        taskKind: TaskKind,
        changedFiles: [String],
        markers: WorkspaceMarkers
    ) -> [ValidationAction] {
        let lowered = request.lowercased()
        let touchedSwift = changedFiles.contains { $0.hasSuffix(".swift") || $0 == "Package.swift" }
        let wantsTests = lowered.contains("test") || lowered.contains("bug") || lowered.contains("fix") || taskKind == .bugFix
        let wantsBuild = lowered.contains("build") || lowered.contains("compile") || touchedSwift || taskKind == .feature || taskKind == .refactor
        var actions: [ValidationAction] = []

        if markers.hasPackageSwift && wantsBuild {
            actions.append(.init(
                summary: "Run `swift build` to validate the changed Swift package code.",
                call: .init(toolName: "build", arguments: [
                    "operation": .string("swift_build"),
                    "timeout_seconds": .number(120),
                ])
            ))
        }

        if markers.hasPackageSwift && (wantsTests || (markers.hasTests && touchedSwift)) {
            actions.append(.init(
                summary: "Run `swift test` to validate the changed Swift package code.",
                call: .init(toolName: "build", arguments: [
                    "operation": .string("swift_test"),
                    "timeout_seconds": .number(120),
                ])
            ))
        }

        if let workspace = markers.xcodeWorkspace ?? markers.xcodeProject, wantsBuild {
            var buildArguments: JSONObject = [
                "operation": .string("xcodebuild_build"),
                "timeout_seconds": .number(180),
            ]
            if workspace.hasSuffix(".xcworkspace") {
                buildArguments["workspace"] = .string(workspace)
            } else {
                buildArguments["project"] = .string(workspace)
            }
            actions.append(.init(
                summary: "Run `xcodebuild build` to validate the Xcode project or workspace.",
                call: .init(toolName: "build", arguments: buildArguments)
            ))

            if wantsTests || taskKind == .bugFix {
                var testArguments = buildArguments
                testArguments["operation"] = .string("xcodebuild_test")
                actions.append(.init(
                    summary: "Run `xcodebuild test` to validate the Xcode project or workspace.",
                    call: .init(toolName: "build", arguments: testArguments)
                ))
            }
        }

        return actions
    }

    private static func shellValidationActions(
        request: String,
        taskKind: TaskKind,
        changedFiles: [String],
        markers: WorkspaceMarkers,
        skippingSwiftAndXcode: Bool
    ) -> [ValidationAction] {
        let lowered = request.lowercased()
        let touchedJS = changedFiles.contains { path in
            [".js", ".jsx", ".ts", ".tsx", ".json"].contains(where: path.hasSuffix)
        }
        let touchedRust = changedFiles.contains { $0.hasSuffix(".rs") || $0 == "Cargo.toml" }
        let touchedGo = changedFiles.contains { $0.hasSuffix(".go") || $0 == "go.mod" }
        let wantsTests = lowered.contains("test") || lowered.contains("bug") || lowered.contains("fix") || taskKind == .bugFix
        var actions: [ValidationAction] = []

        if !skippingSwiftAndXcode {
            let touchedSwift = changedFiles.contains { $0.hasSuffix(".swift") || $0 == "Package.swift" }
            let wantsBuild = lowered.contains("build") || lowered.contains("compile") || touchedSwift || taskKind == .feature || taskKind == .refactor

            if markers.hasPackageSwift && wantsBuild {
                actions.append(.init(
                    summary: "Run `swift build` to validate the changed Swift package code.",
                    call: .init(toolName: "shell", arguments: [
                        "command": .string("swift build"),
                        "timeout_seconds": .number(120),
                    ])
                ))
            }

            if markers.hasPackageSwift && (wantsTests || (markers.hasTests && touchedSwift)) {
                actions.append(.init(
                    summary: "Run `swift test` to validate the changed Swift package code.",
                    call: .init(toolName: "shell", arguments: [
                        "command": .string("swift test"),
                        "timeout_seconds": .number(120),
                    ])
                ))
            }
        }

        if markers.hasPackageJSON && (taskKind == .feature || taskKind == .bugFix || taskKind == .refactor || touchedJS) {
            let packageManager: String
            if markers.hasPnpmLock {
                packageManager = "pnpm"
            } else if markers.hasYarnLock {
                packageManager = "yarn"
            } else {
                packageManager = "npm"
            }
            actions.append(.init(
                summary: "Run `\(packageManager) run build` to validate the web/package changes.",
                call: .init(toolName: "shell", arguments: [
                    "command": .string("\(packageManager) run build"),
                    "timeout_seconds": .number(120),
                ])
            ))
            if wantsTests || taskKind == .bugFix {
                let testCommand = packageManager == "npm" ? "npm test" : "\(packageManager) test"
                actions.append(.init(
                    summary: "Run `\(testCommand)` to validate the web/package test suite.",
                    call: .init(toolName: "shell", arguments: [
                        "command": .string(testCommand),
                        "timeout_seconds": .number(120),
                    ])
                ))
            }
        }

        if markers.hasCargoToml && (taskKind == .bugFix || taskKind == .feature || taskKind == .refactor || touchedRust) {
            actions.append(.init(
                summary: "Run `cargo check` to validate the Rust workspace.",
                call: .init(toolName: "shell", arguments: [
                    "command": .string("cargo check"),
                    "timeout_seconds": .number(120),
                ])
            ))
            if wantsTests || taskKind == .bugFix {
                actions.append(.init(
                    summary: "Run `cargo test` to validate the Rust tests.",
                    call: .init(toolName: "shell", arguments: [
                        "command": .string("cargo test"),
                        "timeout_seconds": .number(120),
                    ])
                ))
            }
        }

        if markers.hasGoMod && (taskKind == .bugFix || taskKind == .feature || taskKind == .refactor || touchedGo) {
            actions.append(.init(
                summary: "Run `go test ./...` to validate the Go workspace.",
                call: .init(toolName: "shell", arguments: [
                    "command": .string("go test ./..."),
                    "timeout_seconds": .number(120),
                ])
            ))
        }

        return actions
    }
}
