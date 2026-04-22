import Foundation

public struct AshexUserConfig: Codable, Sendable {
    public var version: Int
    public var debug: DebugConfig
    public var sandbox: SandboxPolicyConfig
    public var network: NetworkPolicyConfig
    public var shell: ShellCommandPolicyConfig
    public var daemon: DaemonConfig
    public var telegram: TelegramConfig
    public var ollama: OllamaConfig
    public var dflash: DFlashConfig
    public var optimization: OptimizationConfig
    public var logging: LoggingConfig

    public init(
        version: Int = 1,
        debug: DebugConfig = .default,
        sandbox: SandboxPolicyConfig = .default,
        network: NetworkPolicyConfig = .default,
        shell: ShellCommandPolicyConfig = .default,
        daemon: DaemonConfig = .default,
        telegram: TelegramConfig = .default,
        ollama: OllamaConfig = .default,
        dflash: DFlashConfig = .default,
        optimization: OptimizationConfig = .default,
        logging: LoggingConfig = .default
    ) {
        self.version = version
        self.debug = debug
        self.sandbox = sandbox
        self.network = network
        self.shell = shell
        self.daemon = daemon
        self.telegram = telegram
        self.ollama = ollama
        self.dflash = dflash
        self.optimization = optimization
        self.logging = logging
    }

    public static let `default` = AshexUserConfig()

    private enum CodingKeys: String, CodingKey {
        case version
        case debug
        case sandbox
        case network
        case shell
        case daemon
        case telegram
        case ollama
        case dflash
        case optimization
        case logging
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        debug = try container.decodeIfPresent(DebugConfig.self, forKey: .debug) ?? .default
        sandbox = try container.decodeIfPresent(SandboxPolicyConfig.self, forKey: .sandbox) ?? .default
        network = try container.decodeIfPresent(NetworkPolicyConfig.self, forKey: .network) ?? .default
        shell = try container.decodeIfPresent(ShellCommandPolicyConfig.self, forKey: .shell) ?? .default
        daemon = try container.decodeIfPresent(DaemonConfig.self, forKey: .daemon) ?? .default
        telegram = try container.decodeIfPresent(TelegramConfig.self, forKey: .telegram) ?? .default
        ollama = try container.decodeIfPresent(OllamaConfig.self, forKey: .ollama) ?? .default
        dflash = try container.decodeIfPresent(DFlashConfig.self, forKey: .dflash) ?? .default
        optimization = try container.decodeIfPresent(OptimizationConfig.self, forKey: .optimization) ?? .default
        logging = try container.decodeIfPresent(LoggingConfig.self, forKey: .logging) ?? .default
    }
}

public struct DebugConfig: Codable, Sendable {
    public var reasoningSummaries: Bool

    public init(reasoningSummaries: Bool = false) {
        self.reasoningSummaries = reasoningSummaries
    }

    public static let `default` = DebugConfig()

    private enum CodingKeys: String, CodingKey {
        case reasoningSummaries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reasoningSummaries = try container.decodeIfPresent(Bool.self, forKey: .reasoningSummaries) ?? false
    }
}

public struct OllamaConfig: Codable, Sendable {
    public var requestTimeoutSeconds: Int
    public var contextWindowTokens: Int

    public init(requestTimeoutSeconds: Int = 180, contextWindowTokens: Int = 4096) {
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.contextWindowTokens = contextWindowTokens
    }

    public static let `default` = OllamaConfig()

    private enum CodingKeys: String, CodingKey {
        case requestTimeoutSeconds
        case contextWindowTokens
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestTimeoutSeconds = max(15, try container.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? Self.default.requestTimeoutSeconds)
        contextWindowTokens = max(512, try container.decodeIfPresent(Int.self, forKey: .contextWindowTokens) ?? Self.default.contextWindowTokens)
    }
}

public struct DFlashConfig: Codable, Sendable {
    public var enabled: Bool
    public var baseURL: String
    public var model: String?
    public var draftModel: String?
    public var requestTimeoutSeconds: Int

    public init(
        enabled: Bool = false,
        baseURL: String = "http://127.0.0.1:8000",
        model: String? = nil,
        draftModel: String? = nil,
        requestTimeoutSeconds: Int = 120
    ) {
        self.enabled = enabled
        self.baseURL = baseURL
        self.model = model
        self.draftModel = draftModel
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    public static let `default` = DFlashConfig()

    private enum CodingKeys: String, CodingKey {
        case enabled
        case baseURL
        case model
        case draftModel
        case requestTimeoutSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? Self.default.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model)
        draftModel = try container.decodeIfPresent(String.self, forKey: .draftModel)
        requestTimeoutSeconds = max(5, try container.decodeIfPresent(Int.self, forKey: .requestTimeoutSeconds) ?? Self.default.requestTimeoutSeconds)
    }
}

public struct DaemonConfig: Codable, Sendable {
    public var enabled: Bool
    public var foregroundPollIntervalSeconds: Int

    public init(enabled: Bool, foregroundPollIntervalSeconds: Int = 2) {
        self.enabled = enabled
        self.foregroundPollIntervalSeconds = foregroundPollIntervalSeconds
    }

    public static let `default` = DaemonConfig(enabled: false, foregroundPollIntervalSeconds: 2)

    private enum CodingKeys: String, CodingKey {
        case enabled
        case foregroundPollIntervalSeconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        foregroundPollIntervalSeconds = max(1, try container.decodeIfPresent(Int.self, forKey: .foregroundPollIntervalSeconds) ?? 2)
    }
}

public enum ConnectorExecutionPolicyMode: String, Codable, Sendable, CaseIterable {
    case assistantOnly = "assistant_only"
    case approvalRequired = "approval_required"
    case trustedFullAccess = "trusted_full_access"
}

public enum LoggingLevel: String, Codable, Sendable, CaseIterable {
    case debug
    case info
    case warning
    case error
}

public struct LoggingConfig: Codable, Sendable {
    public var level: LoggingLevel

    public init(level: LoggingLevel = .info) {
        self.level = level
    }

    public static let `default` = LoggingConfig(level: .info)

    private enum CodingKeys: String, CodingKey {
        case level
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        level = try container.decodeIfPresent(LoggingLevel.self, forKey: .level) ?? .info
    }
}

public struct TelegramConfig: Codable, Sendable {
    public var enabled: Bool
    public var botToken: String?
    public var pollingTimeoutSeconds: Int
    public var accessMode: TelegramAccessMode
    public var allowedChatIDs: [String]
    public var allowedUserIDs: [String]
    public var responseMode: TelegramResponseMode
    public var executionPolicy: ConnectorExecutionPolicyMode

    public init(
        enabled: Bool = false,
        botToken: String? = nil,
        pollingTimeoutSeconds: Int = 20,
        accessMode: TelegramAccessMode = .open,
        allowedChatIDs: [String] = [],
        allowedUserIDs: [String] = [],
        responseMode: TelegramResponseMode = .finalMessage,
        executionPolicy: ConnectorExecutionPolicyMode = .assistantOnly
    ) {
        self.enabled = enabled
        self.botToken = botToken
        self.pollingTimeoutSeconds = pollingTimeoutSeconds
        self.accessMode = accessMode
        self.allowedChatIDs = allowedChatIDs
        self.allowedUserIDs = allowedUserIDs
        self.responseMode = responseMode
        self.executionPolicy = executionPolicy
    }

    public static let `default` = TelegramConfig()

    private enum CodingKeys: String, CodingKey {
        case enabled
        case botToken
        case pollingTimeoutSeconds
        case accessMode
        case allowedChatIDs
        case allowedUserIDs
        case responseMode
        case executionPolicy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        botToken = try container.decodeIfPresent(String.self, forKey: .botToken)
        pollingTimeoutSeconds = max(1, try container.decodeIfPresent(Int.self, forKey: .pollingTimeoutSeconds) ?? 20)
        accessMode = try container.decodeIfPresent(TelegramAccessMode.self, forKey: .accessMode) ?? .open
        allowedChatIDs = try container.decodeIfPresent([String].self, forKey: .allowedChatIDs) ?? []
        allowedUserIDs = try container.decodeIfPresent([String].self, forKey: .allowedUserIDs) ?? []
        responseMode = try container.decodeIfPresent(TelegramResponseMode.self, forKey: .responseMode) ?? .finalMessage
        executionPolicy = try container.decodeIfPresent(ConnectorExecutionPolicyMode.self, forKey: .executionPolicy) ?? .assistantOnly
    }
}

public enum TelegramAccessMode: String, Codable, Sendable, CaseIterable {
    case open
    case allowlist = "allowlist_only"
}

public enum TelegramResponseMode: String, Codable, Sendable, CaseIterable {
    case finalMessage = "final_message"
}

public enum WorkspaceSandboxMode: String, Codable, Sendable, CaseIterable {
    case readOnly = "read_only"
    case workspaceWrite = "workspace_write"
    case dangerFullAccess = "danger_full_access"
}

public struct SandboxPolicyConfig: Codable, Sendable {
    public var mode: WorkspaceSandboxMode
    public var protectedPaths: [String]

    public init(
        mode: WorkspaceSandboxMode,
        protectedPaths: [String]
    ) {
        self.mode = mode
        self.protectedPaths = protectedPaths
    }

    public static let `default` = SandboxPolicyConfig(
        mode: .workspaceWrite,
        protectedPaths: [
            ".git",
            ".ashex",
            ".codex",
            "ashex.config.json"
        ]
    )

    private enum CodingKeys: String, CodingKey {
        case mode
        case protectedPaths
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(WorkspaceSandboxMode.self, forKey: .mode) ?? .workspaceWrite
        protectedPaths = try container.decodeIfPresent([String].self, forKey: .protectedPaths) ?? Self.default.protectedPaths
    }
}

public enum NetworkAccessMode: String, Codable, Sendable, CaseIterable {
    case allow
    case prompt
    case deny
}

public struct NetworkCommandRuleConfig: Codable, Sendable {
    public var prefix: String
    public var action: ShellCommandRuleAction
    public var reason: String?

    public init(prefix: String, action: ShellCommandRuleAction, reason: String? = nil) {
        self.prefix = prefix
        self.action = action
        self.reason = reason
    }
}

public struct NetworkPolicyConfig: Codable, Sendable {
    public var mode: NetworkAccessMode
    public var rules: [NetworkCommandRuleConfig]

    public init(mode: NetworkAccessMode, rules: [NetworkCommandRuleConfig] = []) {
        self.mode = mode
        self.rules = rules
    }

    public static let `default` = NetworkPolicyConfig(
        mode: .allow,
        rules: []
    )

    private enum CodingKeys: String, CodingKey {
        case mode
        case rules
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decodeIfPresent(NetworkAccessMode.self, forKey: .mode) ?? .allow
        rules = try container.decodeIfPresent([NetworkCommandRuleConfig].self, forKey: .rules) ?? []
    }
}

public enum ShellCommandRuleAction: String, Codable, Sendable {
    case allow
    case prompt
    case deny
}

public struct ShellCommandRuleConfig: Codable, Sendable {
    public var prefix: String
    public var action: ShellCommandRuleAction
    public var reason: String?

    public init(prefix: String, action: ShellCommandRuleAction, reason: String? = nil) {
        self.prefix = prefix
        self.action = action
        self.reason = reason
    }
}

public struct ShellCommandPolicyConfig: Codable, Sendable {
    public var allowList: [String]
    public var denyList: [String]
    public var requireApprovalForUnknownCommands: Bool
    public var rules: [ShellCommandRuleConfig]

    public init(
        allowList: [String],
        denyList: [String],
        requireApprovalForUnknownCommands: Bool,
        rules: [ShellCommandRuleConfig] = []
    ) {
        self.allowList = allowList
        self.denyList = denyList
        self.requireApprovalForUnknownCommands = requireApprovalForUnknownCommands
        self.rules = rules
    }

    public static let `default` = ShellCommandPolicyConfig(
        allowList: [],
        denyList: [
            "rm ",
            "sudo ",
            "shutdown",
            "reboot",
            "mkfs",
            "dd ",
            "chown ",
            "launchctl bootout"
        ],
        requireApprovalForUnknownCommands: false,
        rules: []
    )

    private enum CodingKeys: String, CodingKey {
        case allowList
        case denyList
        case requireApprovalForUnknownCommands
        case rules
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowList = try container.decodeIfPresent([String].self, forKey: .allowList) ?? []
        denyList = try container.decodeIfPresent([String].self, forKey: .denyList) ?? []
        requireApprovalForUnknownCommands = try container.decodeIfPresent(Bool.self, forKey: .requireApprovalForUnknownCommands) ?? false
        rules = try container.decodeIfPresent([ShellCommandRuleConfig].self, forKey: .rules) ?? []
    }
}

public struct ShellCommandPolicy: Sendable {
    public let config: ShellCommandPolicyConfig

    public enum Assessment: Sendable, Equatable {
        case allow
        case requireApproval(String)
        case deny(String)
    }

    public init(config: ShellCommandPolicyConfig) {
        self.config = config
    }

    public func assess(command: String) -> Assessment {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()

        if let rule = config.rules.first(where: { normalized.hasPrefix($0.prefix.lowercased()) }) {
            switch rule.action {
            case .allow:
                return .allow
            case .prompt:
                return .requireApproval(rule.reason ?? "Command '\(trimmed)' matched a prompt rule and requires approval before execution.")
            case .deny:
                return .deny(rule.reason ?? "Command denied by config rule: '\(trimmed)'.")
            }
        }

        if let denied = config.denyList.first(where: { normalized.hasPrefix($0.lowercased()) }) {
            return .deny("Command denied by config policy: '\(command)'. It matches deny rule '\(denied)'. Update ashex.config.json if you want to allow it.")
        }

        if !config.allowList.isEmpty {
            let allowed = config.allowList.contains { normalized.hasPrefix($0.lowercased()) }
            if allowed {
                return .allow
            }
            if config.requireApprovalForUnknownCommands {
                return .requireApproval("Command '\(trimmed)' is outside the configured allow list and requires approval before execution.")
            }
            return .deny("Command blocked by config policy: '\(command)'. It does not match the current allow list in ashex.config.json.")
        }

        guard config.requireApprovalForUnknownCommands else {
            return .allow
        }

        if knownSafePrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return .allow
        }

        return .requireApproval("Command '\(trimmed)' is not on the recognized safe command list and requires approval before execution.")
    }

    public func validate(command: String) throws {
        switch assess(command: command) {
        case .allow:
            return
        case .requireApproval(let message), .deny(let message):
            throw AshexError.shell(message)
        }
    }

    private var knownSafePrefixes: [String] {
        [
            "ls",
            "pwd",
            "cat ",
            "sed ",
            "head ",
            "tail ",
            "wc ",
            "rg ",
            "find ",
            "grep ",
            "git status",
            "git diff",
            "git log",
            "git show",
            "swift build",
            "swift test",
            "xcodebuild -list",
        ]
    }
}

public enum UserConfigStore {
    public static let fileName = "ashex.config.json"

    public struct LoadedConfig: Sendable {
        public let effectiveConfig: AshexUserConfig
        public let workspaceFileURL: URL
        public let globalFileURL: URL?
    }

    public static func globalConfigURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("ashex", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func ensure(at fileURL: URL) throws -> AshexUserConfig {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: fileURL.path) {
            let config = AshexUserConfig.default
            try write(config, to: fileURL)
            return config
        }
        return try load(from: fileURL)
    }

    public static func load(from fileURL: URL) throws -> AshexUserConfig {
        let data = try Data(contentsOf: fileURL)
        do {
            return try JSONDecoder().decode(AshexUserConfig.self, from: data)
        } catch {
            throw AshexError.persistence("Failed to decode \(fileURL.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public static func write(_ config: AshexUserConfig, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    public static func loadMerged(
        for workspaceRoot: URL,
        fileManager: FileManager = .default,
        globalFileURL overrideGlobalFileURL: URL? = nil
    ) throws -> LoadedConfig {
        let workspaceFileURL = workspaceRoot.appendingPathComponent(fileName)
        let workspaceConfig = try ensure(at: workspaceFileURL)
        let globalFileURL = overrideGlobalFileURL ?? globalConfigURL(fileManager: fileManager)

        guard fileManager.fileExists(atPath: globalFileURL.path) else {
            return LoadedConfig(
                effectiveConfig: workspaceConfig,
                workspaceFileURL: workspaceFileURL,
                globalFileURL: nil
            )
        }

        let mergedConfig = try merge(globalFileURL: globalFileURL, workspaceFileURL: workspaceFileURL)
        return LoadedConfig(
            effectiveConfig: mergedConfig,
            workspaceFileURL: workspaceFileURL,
            globalFileURL: globalFileURL
        )
    }

    private static func merge(globalFileURL: URL, workspaceFileURL: URL) throws -> AshexUserConfig {
        let globalObject = try loadJSONObject(from: globalFileURL)
        let workspaceObject = try loadJSONObject(from: workspaceFileURL)
        let mergedObject = deepMerge(base: globalObject, override: workspaceObject)
        let data = try JSONSerialization.data(withJSONObject: mergedObject, options: [])
        do {
            return try JSONDecoder().decode(AshexUserConfig.self, from: data)
        } catch {
            throw AshexError.persistence("Failed to decode merged Ashex config: \(error.localizedDescription)")
        }
    }

    private static func loadJSONObject(from fileURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw AshexError.persistence("Failed to decode \(fileURL.lastPathComponent): top-level JSON object expected")
        }
        return dictionary
    }

    private static func deepMerge(base: [String: Any], override: [String: Any]) -> [String: Any] {
        var merged = base
        for (key, value) in override {
            if let valueDict = value as? [String: Any], let baseDict = merged[key] as? [String: Any] {
                merged[key] = deepMerge(base: baseDict, override: valueDict)
            } else {
                merged[key] = value
            }
        }
        return merged
    }
}
