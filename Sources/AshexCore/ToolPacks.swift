import Foundation

public struct ToolPackManifest: Codable, Sendable {
    public let id: String
    public let version: Int
    public let displayName: String
    public let description: String
    public let tools: [InstallableToolManifest]

    public init(id: String, version: Int = 1, displayName: String, description: String, tools: [InstallableToolManifest]) {
        self.id = id
        self.version = version
        self.displayName = displayName
        self.description = description
        self.tools = tools
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case version
        case displayName
        case description
        case tools
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decode(String.self, forKey: .description)
        tools = try container.decode([InstallableToolManifest].self, forKey: .tools)
    }
}

public struct InstallableToolManifest: Codable, Sendable {
    public let name: String
    public let description: String
    public let category: String
    public let operationArgumentKey: String?
    public let defaultOperationName: String?
    public let tags: [String]
    public let operations: [InstallableToolOperationManifest]

    public init(
        name: String,
        description: String,
        category: String,
        operationArgumentKey: String? = "operation",
        defaultOperationName: String? = nil,
        tags: [String] = [],
        operations: [InstallableToolOperationManifest]
    ) {
        self.name = name
        self.description = description
        self.category = category
        self.operationArgumentKey = operationArgumentKey
        self.defaultOperationName = defaultOperationName
        self.tags = tags
        self.operations = operations
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case category
        case operationArgumentKey
        case defaultOperationName
        case tags
        case operations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? "custom"
        operationArgumentKey = try container.decodeIfPresent(String.self, forKey: .operationArgumentKey) ?? "operation"
        defaultOperationName = try container.decodeIfPresent(String.self, forKey: .defaultOperationName)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        operations = try container.decode([InstallableToolOperationManifest].self, forKey: .operations)
    }

    public var contract: ToolContract {
        ToolContract(
            name: name,
            description: description,
            kind: .installable,
            category: category,
            operationArgumentKey: operationArgumentKey,
            defaultOperationName: defaultOperationName,
            operations: operations.map(\.contract),
            tags: tags
        )
    }
}

public struct InstallableToolOperationManifest: Codable, Sendable {
    public let name: String
    public let description: String
    public let commandTemplate: String
    public let timeoutSeconds: Int
    public let mutatesWorkspace: Bool
    public let requiresNetwork: Bool
    public let validationArtifacts: [String]
    public let inspectedPathArguments: [String]
    public let changedPathArguments: [String]
    public let progressSummary: String?
    public let approval: ToolApprovalContract?
    public let arguments: [ToolArgumentContract]

    public init(
        name: String,
        description: String,
        commandTemplate: String,
        timeoutSeconds: Int = 60,
        mutatesWorkspace: Bool,
        requiresNetwork: Bool = false,
        validationArtifacts: [String] = [],
        inspectedPathArguments: [String] = [],
        changedPathArguments: [String] = [],
        progressSummary: String? = nil,
        approval: ToolApprovalContract? = nil,
        arguments: [ToolArgumentContract] = []
    ) {
        self.name = name
        self.description = description
        self.commandTemplate = commandTemplate
        self.timeoutSeconds = timeoutSeconds
        self.mutatesWorkspace = mutatesWorkspace
        self.requiresNetwork = requiresNetwork
        self.validationArtifacts = validationArtifacts
        self.inspectedPathArguments = inspectedPathArguments
        self.changedPathArguments = changedPathArguments
        self.progressSummary = progressSummary
        self.approval = approval
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case commandTemplate
        case timeoutSeconds
        case mutatesWorkspace
        case requiresNetwork
        case validationArtifacts
        case inspectedPathArguments
        case changedPathArguments
        case progressSummary
        case approval
        case arguments
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        commandTemplate = try container.decode(String.self, forKey: .commandTemplate)
        timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
        mutatesWorkspace = try container.decodeIfPresent(Bool.self, forKey: .mutatesWorkspace) ?? false
        requiresNetwork = try container.decodeIfPresent(Bool.self, forKey: .requiresNetwork) ?? false
        validationArtifacts = try container.decodeIfPresent([String].self, forKey: .validationArtifacts) ?? []
        inspectedPathArguments = try container.decodeIfPresent([String].self, forKey: .inspectedPathArguments) ?? []
        changedPathArguments = try container.decodeIfPresent([String].self, forKey: .changedPathArguments) ?? []
        progressSummary = try container.decodeIfPresent(String.self, forKey: .progressSummary)
        approval = try container.decodeIfPresent(ToolApprovalContract.self, forKey: .approval)
        arguments = try container.decodeIfPresent([ToolArgumentContract].self, forKey: .arguments) ?? []
    }

    public var contract: ToolOperationContract {
        ToolOperationContract(
            name: name,
            description: description,
            mutatesWorkspace: mutatesWorkspace,
            requiresNetwork: requiresNetwork,
            validationArtifacts: validationArtifacts,
            inspectedPathArguments: inspectedPathArguments,
            changedPathArguments: changedPathArguments,
            progressSummary: progressSummary,
            approval: approval,
            arguments: arguments
        )
    }
}

public enum ToolPackSettings {
    public static let namespace = "toolpacks"
    public static let bundledPackKey = "bundled_enabled_ids"
    public static let defaultBundledPackIDs = ["swiftpm", "ios_xcode", "python"]
}

public enum ToolPackManager {
    public static func enabledBundledPackIDs(persistence: PersistenceStore) throws -> [String] {
        if let stored = try persistence.fetchSetting(namespace: ToolPackSettings.namespace, key: ToolPackSettings.bundledPackKey)?.value.arrayValue {
            let ids = stored.compactMap(\.stringValue)
            return ids.isEmpty ? ToolPackSettings.defaultBundledPackIDs : ids
        }
        return ToolPackSettings.defaultBundledPackIDs
    }

    public static func saveEnabledBundledPackIDs(_ ids: [String], persistence: PersistenceStore, now: Date) throws {
        let normalized = Array(Set(ids)).sorted()
        try persistence.upsertSetting(
            namespace: ToolPackSettings.namespace,
            key: ToolPackSettings.bundledPackKey,
            value: .array(normalized.map(JSONValue.string)),
            now: now
        )
    }

    public static func availableBundledPacks() throws -> [ToolPackManifest] {
        let decoder = JSONDecoder()
        return try bundledManifestURLs()
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let data = try Data(contentsOf: url)
                return try? decoder.decode(ToolPackManifest.self, from: data)
            }
    }

    public static func discoveredCustomPacks(workspaceRoot: URL) throws -> [ToolPackManifest] {
        let decoder = JSONDecoder()
        let searchRoots = [
            workspaceRoot.appendingPathComponent("toolpacks", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ashex/toolpacks", isDirectory: true),
        ]

        let urls = searchRoots.flatMap { root in
            let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            return (contents ?? []).filter { $0.pathExtension == "json" }
        }

        return try urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                let data = try Data(contentsOf: url)
                return try decoder.decode(ToolPackManifest.self, from: data)
            }
    }

    public static func loadInstalledTools(
        workspaceRoot: URL,
        persistence: PersistenceStore,
        executionRuntime: any ExecutionRuntime,
        executionPolicy: ShellExecutionPolicy
    ) throws -> [any Tool] {
        let enabledBundledPackIDs = Set(try enabledBundledPackIDs(persistence: persistence))
        let bundledTools = try availableBundledPacks()
            .filter { enabledBundledPackIDs.contains($0.id) }
            .flatMap { manifest in
                manifest.tools.map { ManifestBackedTool(packID: manifest.id, manifest: $0, executionRuntime: executionRuntime, workspaceURL: workspaceRoot, executionPolicy: executionPolicy) }
            }

        let customTools = try discoveredCustomPacks(workspaceRoot: workspaceRoot)
            .flatMap { manifest in
                manifest.tools.map { ManifestBackedTool(packID: manifest.id, manifest: $0, executionRuntime: executionRuntime, workspaceURL: workspaceRoot, executionPolicy: executionPolicy) }
            }

        return bundledTools + customTools
    }

    private static func bundledManifestURLs() -> [URL] {
        let bundledNames = ToolPackSettings.defaultBundledPackIDs
        let sourceResourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/ToolPacks", isDirectory: true)

        return bundledNames.compactMap { name in
            if let bundledURL = Bundle.module.url(forResource: name, withExtension: "json") {
                return bundledURL
            }

            let sourceURL = sourceResourceRoot.appendingPathComponent("\(name).json")
            return FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil
        }
    }
}

public struct ManifestBackedTool: Tool {
    public let name: String
    public let description: String
    public let contract: ToolContract

    private let manifest: InstallableToolManifest
    private let packID: String
    private let executionRuntime: any ExecutionRuntime
    private let workspaceURL: URL
    private let executionPolicy: ShellExecutionPolicy

    public init(
        packID: String,
        manifest: InstallableToolManifest,
        executionRuntime: any ExecutionRuntime,
        workspaceURL: URL,
        executionPolicy: ShellExecutionPolicy
    ) {
        self.packID = packID
        self.manifest = manifest
        self.executionRuntime = executionRuntime
        self.workspaceURL = workspaceURL
        self.executionPolicy = executionPolicy
        self.name = manifest.name
        self.description = manifest.description
        self.contract = manifest.contract
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        let operation = try resolvedOperation(from: arguments)
        try validate(arguments: arguments, for: operation)
        let command = try render(template: operation.commandTemplate, arguments: arguments)
        let timeoutSeconds = TimeInterval(arguments["timeout_seconds"]?.intValue ?? operation.timeoutSeconds)

        let result = try await executionRuntime.execute(
            .init(command: command, workspaceURL: workspaceURL, timeout: timeoutSeconds, executionPolicy: executionPolicy),
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
            "pack_id": .string(packID),
            "tool_name": .string(name),
            "operation": .string(operation.name),
            "command": .string(command),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr),
            "exit_code": .number(Double(result.exitCode)),
            "timed_out": .bool(result.timedOut),
        ])

        if result.timedOut {
            throw AshexError.shell("Installable tool '\(name)' operation '\(operation.name)' timed out after \(Int(timeoutSeconds))s")
        }

        if result.exitCode != 0 {
            throw AshexError.shell("Installable tool '\(name)' operation '\(operation.name)' failed with exit code \(result.exitCode)\n\(payload.prettyPrinted)")
        }

        return .structured(payload)
    }

    private func resolvedOperation(from arguments: JSONObject) throws -> InstallableToolOperationManifest {
        if let key = manifest.operationArgumentKey,
           let operationName = arguments[key]?.stringValue,
           let operation = manifest.operations.first(where: { $0.name == operationName }) {
            return operation
        }

        if let defaultOperationName = manifest.defaultOperationName,
           let operation = manifest.operations.first(where: { $0.name == defaultOperationName }) {
            return operation
        }

        if manifest.operations.count == 1, let operation = manifest.operations.first {
            return operation
        }

        throw AshexError.invalidToolArguments("tool '\(name)' requires a valid operation")
    }

    private func validate(arguments: JSONObject, for operation: InstallableToolOperationManifest) throws {
        for argument in operation.arguments where argument.required {
            guard let value = arguments[argument.name], !value.isNullLike else {
                throw AshexError.invalidToolArguments("\(name).\(argument.name) is required for operation '\(operation.name)'")
            }
        }
    }

    private func render(template: String, arguments: JSONObject) throws -> String {
        var rendered = template

        let optionalPattern = #"\[\[(.*?)\]\]"#
        let regex = try NSRegularExpression(pattern: optionalPattern)
        while let match = regex.firstMatch(in: rendered, range: NSRange(rendered.startIndex..., in: rendered)),
              let outerRange = Range(match.range(at: 0), in: rendered),
              let innerRange = Range(match.range(at: 1), in: rendered) {
            let inner = String(rendered[innerRange])
            let placeholders = placeholderKeys(in: inner)
            let include = placeholders.allSatisfy { key in
                guard let value = arguments[key] else { return false }
                return !value.isNullLike
            }

            if include {
                let resolved = try replacePlaceholders(in: inner, arguments: arguments)
                rendered.replaceSubrange(outerRange, with: resolved)
            } else {
                rendered.removeSubrange(outerRange)
            }
        }

        rendered = try replacePlaceholders(in: rendered, arguments: arguments)
        return rendered
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replacePlaceholders(in text: String, arguments: JSONObject) throws -> String {
        var rendered = text
        for key in placeholderKeys(in: text) {
            guard let value = arguments[key], !value.isNullLike else {
                throw AshexError.invalidToolArguments("Missing argument '\(key)' while rendering tool command")
            }
            rendered = rendered.replacingOccurrences(of: "{{\(key)}}", with: renderValue(value, key: key))
        }
        return rendered
    }

    private func placeholderKeys(in text: String) -> [String] {
        let regex = try? NSRegularExpression(pattern: #"\{\{([a-zA-Z0-9_]+)\}\}"#)
        let matches = regex?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        return matches.compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    private func renderValue(_ value: JSONValue, key: String) -> String {
        switch value {
        case .string(let string):
            if key.hasSuffix("_path") || key == "path" || key == "workspace" || key == "project" || key == "venv_path" || key == "test_path" || key == "package_path" {
                return shellQuoted(resolvePath(string))
            }
            return shellQuoted(string)
        case .number(let number):
            if number.rounded() == number {
                return String(Int(number))
            }
            return String(number)
        case .bool(let bool):
            return bool ? "true" : "false"
        case .array(let values):
            return values.map { renderValue($0, key: key) }.joined(separator: " ")
        case .object:
            return shellQuoted(value.prettyPrinted)
        case .null:
            return ""
        }
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
}

public struct ToolPackScaffoldTool: Tool {
    public let name = "toolpack"
    public let description = "Scaffold installable tool-pack manifests that humans or models can extend later"
    public let contract = ToolContract(
        name: "toolpack",
        description: "Scaffold installable tool-pack manifests that humans or models can extend later",
        kind: .embedded,
        category: "tooling",
        operationArgumentKey: "operation",
        operations: [
            .init(
                name: "scaffold_pack",
                description: "Create a new installable tool-pack manifest skeleton",
                mutatesWorkspace: true,
                changedPathArguments: ["path"],
                progressSummary: "scaffolded tool pack",
                approval: .init(risk: .medium, summary: "Create tool-pack manifest", reasonTemplate: "{{path}}"),
                arguments: [
                    .init(name: "pack_id", description: "Stable pack identifier", type: .string, required: true),
                    .init(name: "name", description: "Human-readable pack name", type: .string, required: true),
                    .init(name: "description", description: "Pack description", type: .string, required: true),
                    .init(name: "tool_name", description: "Name of the first tool in the pack", type: .string, required: true),
                    .init(name: "tool_description", description: "Description of the first tool", type: .string, required: true),
                    .init(name: "category", description: "Tool category", type: .string, required: false),
                    .init(name: "path", description: "Optional output manifest path", type: .string, required: false),
                ]
            )
        ],
        tags: ["core", "tooling", "toolpacks"]
    )

    private let workspaceGuard: WorkspaceGuard

    public init(workspaceGuard: WorkspaceGuard) {
        self.workspaceGuard = workspaceGuard
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        guard arguments["operation"]?.stringValue == "scaffold_pack" else {
            throw AshexError.invalidToolArguments("toolpack.operation must be scaffold_pack")
        }

        let packID = try requiredString("pack_id", in: arguments)
        let displayName = try requiredString("name", in: arguments)
        let description = try requiredString("description", in: arguments)
        let toolName = try requiredString("tool_name", in: arguments)
        let toolDescription = try requiredString("tool_description", in: arguments)
        let category = arguments["category"]?.stringValue ?? "custom"
        let relativePath = arguments["path"]?.stringValue ?? "toolpacks/\(packID).json"
        let manifestURL = try workspaceGuard.resolveForMutation(path: relativePath)

        let manifest = ToolPackManifest(
            id: packID,
            displayName: displayName,
            description: description,
            tools: [
                InstallableToolManifest(
                    name: toolName,
                    description: toolDescription,
                    category: category,
                    tags: ["custom", category],
                    operations: [
                        InstallableToolOperationManifest(
                            name: "example_operation",
                            description: "Replace this with a real operation",
                            commandTemplate: "echo 'replace me'",
                            timeoutSeconds: 30,
                            mutatesWorkspace: false,
                            arguments: [
                                ToolArgumentContract(name: "operation", description: "Operation name", type: .string, required: true, enumValues: ["example_operation"])
                            ]
                        )
                    ]
                )
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)

        return .structured(.object([
            "operation": .string("scaffold_pack"),
            "path": .string(relativePath),
            "pack_id": .string(packID),
            "tool_name": .string(toolName),
            "status": .string("created"),
        ]))
    }

    private func requiredString(_ key: String, in arguments: JSONObject) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw AshexError.invalidToolArguments("toolpack.\(key) must be a non-empty string")
        }
        return value
    }
}

public enum RuntimeToolFactory {
    public static func makeTools(
        workspaceURL: URL,
        persistence: PersistenceStore,
        sandbox: SandboxPolicyConfig,
        shellExecutionPolicy: ShellExecutionPolicy
    ) throws -> [any Tool] {
        let executionRuntime = ProcessExecutionRuntime()
        let workspaceGuard = WorkspaceGuard(rootURL: workspaceURL, sandbox: sandbox)

        var tools: [any Tool] = [
            FileSystemTool(workspaceGuard: workspaceGuard),
            GitTool(executionRuntime: executionRuntime, workspaceURL: workspaceURL),
            BuildTool(executionRuntime: executionRuntime, workspaceURL: workspaceURL),
            ShellTool(executionRuntime: executionRuntime, workspaceURL: workspaceURL, executionPolicy: shellExecutionPolicy),
            ToolPackScaffoldTool(workspaceGuard: workspaceGuard),
        ]

        tools.append(contentsOf: try ToolPackManager.loadInstalledTools(
            workspaceRoot: workspaceURL,
            persistence: persistence,
            executionRuntime: executionRuntime,
            executionPolicy: shellExecutionPolicy
        ))

        return tools
    }
}

private extension JSONValue {
    var isNullLike: Bool {
        switch self {
        case .null:
            return true
        case .string(let value):
            return value.isEmpty
        case .array(let values):
            return values.isEmpty
        case .object(let object):
            return object.isEmpty
        default:
            return false
        }
    }
}
