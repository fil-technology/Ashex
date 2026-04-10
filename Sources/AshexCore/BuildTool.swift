import Foundation

public struct BuildTool: Tool {
    public let name = "build"
    public let description = "Run typed SwiftPM and xcodebuild actions in the workspace with structured results"
    public let contract = ToolContract(
        name: "build",
        description: "Run typed SwiftPM and xcodebuild actions in the workspace with structured results",
        kind: .embedded,
        category: "build",
        operationArgumentKey: "operation",
        operations: [
            .init(name: "swift_build", description: "Run swift build", mutatesWorkspace: false, validationArtifacts: ["<build>"], progressSummary: "validated with swift build"),
            .init(name: "swift_test", description: "Run swift test", mutatesWorkspace: false, validationArtifacts: ["<build>"], progressSummary: "validated with swift test"),
            .init(name: "xcodebuild_list", description: "List Xcode schemes and targets", mutatesWorkspace: false, inspectedPathArguments: ["workspace", "project"], progressSummary: "inspected xcode targets", arguments: [.init(name: "workspace", description: "xcworkspace path", type: .string, required: false), .init(name: "project", description: "xcodeproj path", type: .string, required: false)]),
            .init(name: "xcodebuild_build", description: "Build an Xcode scheme", mutatesWorkspace: false, validationArtifacts: ["<build>"], progressSummary: "validated with xcodebuild build", arguments: [.init(name: "workspace", description: "xcworkspace path", type: .string, required: false), .init(name: "project", description: "xcodeproj path", type: .string, required: false), .init(name: "scheme", description: "Scheme name", type: .string, required: false), .init(name: "configuration", description: "Build configuration", type: .string, required: false), .init(name: "destination", description: "Build destination", type: .string, required: false), .init(name: "sdk", description: "SDK name", type: .string, required: false), .init(name: "derived_data_path", description: "DerivedData output path", type: .string, required: false)]),
            .init(name: "xcodebuild_test", description: "Test an Xcode scheme", mutatesWorkspace: false, validationArtifacts: ["<build>"], progressSummary: "validated with xcodebuild test", arguments: [.init(name: "workspace", description: "xcworkspace path", type: .string, required: false), .init(name: "project", description: "xcodeproj path", type: .string, required: false), .init(name: "scheme", description: "Scheme name", type: .string, required: false), .init(name: "configuration", description: "Build configuration", type: .string, required: false), .init(name: "destination", description: "Test destination", type: .string, required: false), .init(name: "sdk", description: "SDK name", type: .string, required: false), .init(name: "derived_data_path", description: "DerivedData output path", type: .string, required: false)]),
        ],
        tags: ["core", "build", "swift", "xcode"]
    )

    private let executionRuntime: any ExecutionRuntime
    private let workspaceURL: URL

    public init(executionRuntime: any ExecutionRuntime, workspaceURL: URL) {
        self.executionRuntime = executionRuntime
        self.workspaceURL = workspaceURL
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        guard let operation = arguments["operation"]?.stringValue, !operation.isEmpty else {
            throw AshexError.invalidToolArguments("build.operation must be a non-empty string")
        }

        let timeoutSeconds = TimeInterval(arguments["timeout_seconds"]?.intValue ?? defaultTimeoutSeconds(for: operation))
        let command = try command(for: operation, arguments: arguments)

        let result = try await executionRuntime.execute(
            .init(command: command, workspaceURL: workspaceURL, timeout: timeoutSeconds),
            cancellationToken: context.cancellation,
            onStdout: { chunk in
                context.emit(RuntimeEvent(payload: .toolOutput(
                    runID: context.runID,
                    toolCallID: .init(),
                    stream: .stdout,
                    chunk: chunk
                )))
            },
            onStderr: { chunk in
                context.emit(RuntimeEvent(payload: .toolOutput(
                    runID: context.runID,
                    toolCallID: .init(),
                    stream: .stderr,
                    chunk: chunk
                )))
            }
        )

        let payload: JSONValue = .object([
            "operation": .string(operation),
            "command": .string(command),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr),
            "exit_code": .number(Double(result.exitCode)),
            "timed_out": .bool(result.timedOut),
        ])

        if result.timedOut {
            throw AshexError.shell("Build command timed out after \(Int(timeoutSeconds))s")
        }

        if result.exitCode != 0 {
            throw AshexError.shell("Build command failed with exit code \(result.exitCode)\n\(payload.prettyPrinted)")
        }

        return .structured(payload)
    }

    private func command(for operation: String, arguments: JSONObject) throws -> String {
        switch operation {
        case "swift_build":
            return "swift build"
        case "swift_test":
            return "swift test"
        case "xcodebuild_list":
            return "xcodebuild\(targetSelection(arguments: arguments, includeScheme: false)) -list"
        case "xcodebuild_build":
            return "xcodebuild\(targetSelection(arguments: arguments, includeScheme: true))\(buildOptions(arguments: arguments)) build"
        case "xcodebuild_test":
            return "xcodebuild\(targetSelection(arguments: arguments, includeScheme: true))\(buildOptions(arguments: arguments)) test"
        default:
            throw AshexError.invalidToolArguments("Unsupported build operation: \(operation)")
        }
    }

    private func targetSelection(arguments: JSONObject, includeScheme: Bool) -> String {
        var parts: [String] = []

        if let workspace = arguments["workspace"]?.stringValue, !workspace.isEmpty {
            parts.append("-workspace \(shellQuoted(resolvePath(workspace)))")
        }
        if let project = arguments["project"]?.stringValue, !project.isEmpty {
            parts.append("-project \(shellQuoted(resolvePath(project)))")
        }
        if includeScheme, let scheme = arguments["scheme"]?.stringValue, !scheme.isEmpty {
            parts.append("-scheme \(shellQuoted(scheme))")
        }

        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    private func buildOptions(arguments: JSONObject) -> String {
        var parts: [String] = []
        if let configuration = arguments["configuration"]?.stringValue, !configuration.isEmpty {
            parts.append("-configuration \(shellQuoted(configuration))")
        }
        if let destination = arguments["destination"]?.stringValue, !destination.isEmpty {
            parts.append("-destination \(shellQuoted(destination))")
        }
        if let sdk = arguments["sdk"]?.stringValue, !sdk.isEmpty {
            parts.append("-sdk \(shellQuoted(sdk))")
        }
        if let derivedDataPath = arguments["derived_data_path"]?.stringValue, !derivedDataPath.isEmpty {
            parts.append("-derivedDataPath \(shellQuoted(resolvePath(derivedDataPath)))")
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    private func resolvePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if url.path.hasPrefix("/") {
            return url.standardizedFileURL.path
        }
        return workspaceURL.appendingPathComponent(path).standardizedFileURL.path
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func defaultTimeoutSeconds(for operation: String) -> Int {
        switch operation {
        case "swift_test", "xcodebuild_test":
            return 120
        case "xcodebuild_build":
            return 180
        default:
            return 60
        }
    }
}
