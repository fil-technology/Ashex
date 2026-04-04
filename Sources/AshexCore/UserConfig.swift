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

    public init(config: ShellCommandPolicyConfig) {
        self.config = config
    }

    public func validate(command: String) throws {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let denied = config.denyList.first(where: { normalized.hasPrefix($0.lowercased()) }) {
            throw AshexError.shell("Command denied by config policy: '\(command)'. It matches deny rule '\(denied)'. Update ashex.config.json if you want to allow it.")
        }

        guard !config.allowList.isEmpty else { return }

        let allowed = config.allowList.contains { normalized.hasPrefix($0.lowercased()) }
        if !allowed {
            throw AshexError.shell("Command blocked by config policy: '\(command)'. It does not match the current allow list in ashex.config.json.")
        }
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
