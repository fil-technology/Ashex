import Foundation

public enum ContextOptimizationMode: String, Codable, Sendable, CaseIterable {
    case raw
    case turbo
    case triattention
    case automatic = "auto"
}

public enum ContextOptimizationIntent: String, Codable, Sendable, CaseIterable {
    case chat
    case code
    case documentQA = "documentqa"
    case agentRun = "agentrun"
    case multimodal
}

public enum OptimizationBackendKind: String, Codable, Sendable, CaseIterable {
    case disabled
    case esh
}

public struct EshOptimizationBridgeConfig: Codable, Sendable, Equatable {
    public var executablePath: String?
    public var homePath: String?
    public var repoRootPath: String?

    public init(
        executablePath: String? = nil,
        homePath: String? = nil,
        repoRootPath: String? = nil
    ) {
        self.executablePath = executablePath
        self.homePath = homePath
        self.repoRootPath = repoRootPath
    }

    public static let `default` = EshOptimizationBridgeConfig()
}

public struct OptimizationConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var backend: OptimizationBackendKind
    public var mode: ContextOptimizationMode
    public var intent: ContextOptimizationIntent
    public var esh: EshOptimizationBridgeConfig

    public init(
        enabled: Bool = false,
        backend: OptimizationBackendKind = .disabled,
        mode: ContextOptimizationMode = .automatic,
        intent: ContextOptimizationIntent = .agentRun,
        esh: EshOptimizationBridgeConfig = .default
    ) {
        self.enabled = enabled
        self.backend = backend
        self.mode = mode
        self.intent = intent
        self.esh = esh
    }

    public static let `default` = OptimizationConfig()

    private enum CodingKeys: String, CodingKey {
        case enabled
        case backend
        case mode
        case intent
        case esh
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        backend = try container.decodeIfPresent(OptimizationBackendKind.self, forKey: .backend) ?? .disabled
        mode = try container.decodeIfPresent(ContextOptimizationMode.self, forKey: .mode) ?? .automatic
        intent = try container.decodeIfPresent(ContextOptimizationIntent.self, forKey: .intent) ?? .agentRun
        esh = try container.decodeIfPresent(EshOptimizationBridgeConfig.self, forKey: .esh) ?? .default
    }
}

public struct ContextOptimizationResolution: Sendable, Equatable {
    public let mode: ContextOptimizationMode
    public let reason: String

    public init(mode: ContextOptimizationMode, reason: String) {
        self.mode = mode
        self.reason = reason
    }
}

public struct EshOptimizationDoctorReport: Sendable, Equatable {
    public let executablePath: String?
    public let homePath: String
    public let calibrationPath: String
    public let executableAvailable: Bool
    public let calibrationAvailable: Bool
    public let recommendedMode: ContextOptimizationMode
    public let recommendationReason: String

    public init(
        executablePath: String?,
        homePath: String,
        calibrationPath: String,
        executableAvailable: Bool,
        calibrationAvailable: Bool,
        recommendedMode: ContextOptimizationMode,
        recommendationReason: String
    ) {
        self.executablePath = executablePath
        self.homePath = homePath
        self.calibrationPath = calibrationPath
        self.executableAvailable = executableAvailable
        self.calibrationAvailable = calibrationAvailable
        self.recommendedMode = recommendedMode
        self.recommendationReason = recommendationReason
    }
}

public struct ContextOptimizationAdvisor: Sendable {
    public init() {}

    public func resolve(
        taskKind: TaskKind,
        prompt: String,
        provider: String,
        model: String,
        config: OptimizationConfig,
        calibrationAvailable: Bool
    ) -> ContextOptimizationResolution {
        guard config.enabled else {
            return .init(mode: .raw, reason: "optimization is disabled")
        }

        guard TokenSavingsEstimator.isLocalProvider(provider) else {
            return .init(mode: .raw, reason: "remote providers do not use local KV-cache optimization modes")
        }

        guard config.backend != .disabled else {
            return .init(mode: .raw, reason: "no optimization backend is enabled")
        }

        if config.mode != .automatic {
            return .init(mode: config.mode, reason: "explicit optimization mode requested")
        }

        let intent = inferredIntent(taskKind: taskKind, prompt: prompt, configuredIntent: config.intent)
        switch intent {
        case .documentQA, .multimodal:
            return .init(mode: .turbo, reason: "retrieval-heavy intent prefers turbo packaging")
        case .code, .agentRun:
            if shouldPreferTurbo(prompt: prompt) {
                return .init(mode: .turbo, reason: "broader multi-step code task prefers turbo reuse")
            }
            if calibrationAvailable {
                return .init(mode: .triattention, reason: "focused code context with calibration prefers triattention")
            }
            return .init(mode: .turbo, reason: "code intent without calibration falls back to turbo")
        case .chat:
            return .init(mode: .raw, reason: "chat intent defaults to raw mode")
        }
    }

    private func inferredIntent(taskKind: TaskKind, prompt: String, configuredIntent: ContextOptimizationIntent) -> ContextOptimizationIntent {
        if configuredIntent != .agentRun {
            return configuredIntent
        }

        switch taskKind {
        case .bugFix, .feature, .refactor:
            return .code
        case .analysis where TaskPlanner.shouldAttemptModelPlanning(for: prompt):
            return .agentRun
        case .analysis, .general, .docs, .git, .shell:
            return .chat
        }
    }

    private func shouldPreferTurbo(prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        let connectiveCount = [
            " and ", " then ", " also ", "\n- ", "\n1.", "; "
        ].reduce(into: 0) { partial, marker in
            partial += lowered.components(separatedBy: marker).count - 1
        }
        return prompt.count > 220 || connectiveCount >= 2
    }
}

public struct EshOptimizationInspector: Sendable {
    private let environment: [String: String]
    private let fileExists: @Sendable (String) -> Bool
    private let currentExecutablePath: String?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        currentExecutablePath: String? = ProcessInfo.processInfo.arguments.first
    ) {
        self.environment = environment
        self.fileExists = fileExists
        self.currentExecutablePath = currentExecutablePath
    }

    public func doctor(
        provider: String,
        model: String,
        taskKind: TaskKind,
        prompt: String,
        config: OptimizationConfig
    ) -> EshOptimizationDoctorReport {
        let executable = resolveExecutablePath(config: config.esh)
        let homePath = resolveHomePath(config: config.esh)
        let calibrationPath = triAttentionCalibrationPath(for: model, homePath: homePath)
        let calibrationAvailable = fileExists(calibrationPath)
        let resolution = ContextOptimizationAdvisor().resolve(
            taskKind: taskKind,
            prompt: prompt,
            provider: provider,
            model: model,
            config: config,
            calibrationAvailable: calibrationAvailable
        )

        return EshOptimizationDoctorReport(
            executablePath: executable,
            homePath: homePath,
            calibrationPath: calibrationPath,
            executableAvailable: executable.map(fileExists) ?? false,
            calibrationAvailable: calibrationAvailable,
            recommendedMode: resolution.mode,
            recommendationReason: resolution.reason
        )
    }

    public func triAttentionCalibrationPath(for modelID: String, homePath: String) -> String {
        URL(fileURLWithPath: homePath, isDirectory: true)
            .appendingPathComponent("compression", isDirectory: true)
            .appendingPathComponent(sanitize(modelID), isDirectory: true)
            .appendingPathComponent("triattention", isDirectory: true)
            .appendingPathComponent("triattention_calib.safetensors")
            .path
    }

    public func resolveHomePath(config: EshOptimizationBridgeConfig) -> String {
        if let configured = config.homePath, !configured.isEmpty {
            return configured
        }
        if let env = environment["ESH_HOME"] ?? environment["LLMCACHE_HOME"], !env.isEmpty {
            return env
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".esh", isDirectory: true).path
    }

    public func resolveExecutablePath(config: EshOptimizationBridgeConfig) -> String? {
        if let configured = config.executablePath, !configured.isEmpty {
            return configured
        }
        if let env = environment["ASHEX_ESH_EXECUTABLE"] ?? environment["ESH_EXECUTABLE"], !env.isEmpty {
            return env
        }
        for candidate in preferredExecutableCandidates() where fileExists(candidate) {
            return candidate
        }

        let pathValue = environment["PATH"] ?? ""
        for pathEntry in pathValue.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(pathEntry), isDirectory: true).appendingPathComponent("esh")
            if fileExists(candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private func sanitize(_ value: String) -> String {
        value.map { character in
            switch character {
            case "/", ":", "?", "&", "=", "\\", " ":
                "_"
            default:
                character
            }
        }.reduce(into: "") { partial, character in
            partial.append(character)
        }
    }

    private func preferredExecutableCandidates() -> [String] {
        bundledExecutableCandidates() + siblingWorkspaceExecutableCandidates()
    }

    private func bundledExecutableCandidates() -> [String] {
        guard let currentExecutablePath, !currentExecutablePath.isEmpty else {
            return []
        }

        let executableURL = URL(fileURLWithPath: currentExecutablePath).resolvingSymlinksInPath()
        let executableDirectory = executableURL.deletingLastPathComponent()
        let parentDirectory = executableDirectory.deletingLastPathComponent()

        return [
            executableDirectory.appendingPathComponent("esh").path,
            parentDirectory.appendingPathComponent("libexec/esh").path,
            parentDirectory.appendingPathComponent("bin/esh").path,
        ]
    }

    private func siblingWorkspaceExecutableCandidates() -> [String] {
        guard let pwd = environment["PWD"], !pwd.isEmpty else {
            return []
        }

        let workingDirectory = URL(fileURLWithPath: pwd, isDirectory: true).resolvingSymlinksInPath()
        var searchRoots: [URL] = []
        var cursor = workingDirectory
        for _ in 0..<6 {
            searchRoots.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }

        var candidates: [String] = []
        for root in searchRoots {
            let eshRoot = root
                .appendingPathComponent("Coding", isDirectory: true)
                .appendingPathComponent("MLX+TurboQuant", isDirectory: true)
                .appendingPathComponent("Source", isDirectory: true)
            candidates.append(contentsOf: [
                eshRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/esh").path,
                eshRoot.appendingPathComponent(".build/arm64-apple-macosx/release/esh").path,
                eshRoot.appendingPathComponent(".build/debug/esh").path,
                eshRoot.appendingPathComponent(".build/release/esh").path,
            ])
        }
        return candidates
    }
}
