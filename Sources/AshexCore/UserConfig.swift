import Foundation

public struct AshexUserConfig: Codable, Sendable {
    public var version: Int
    public var shell: ShellCommandPolicyConfig

    public init(
        version: Int = 1,
        shell: ShellCommandPolicyConfig = .default
    ) {
        self.version = version
        self.shell = shell
    }

    public static let `default` = AshexUserConfig()
}

public struct ShellCommandPolicyConfig: Codable, Sendable {
    public var allowList: [String]
    public var denyList: [String]
    public var requireApprovalForUnknownCommands: Bool

    public init(
        allowList: [String],
        denyList: [String],
        requireApprovalForUnknownCommands: Bool
    ) {
        self.allowList = allowList
        self.denyList = denyList
        self.requireApprovalForUnknownCommands = requireApprovalForUnknownCommands
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
        requireApprovalForUnknownCommands: false
    )
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
}
