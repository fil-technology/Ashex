import Foundation

public struct LocalModelGuardrailPolicyResolution: Equatable, Sendable {
    public let shouldRunLocalMemoryGuardrail: Bool
    public let eshBridgeExecutablePath: String?
    public let reason: String

    public init(
        shouldRunLocalMemoryGuardrail: Bool,
        eshBridgeExecutablePath: String?,
        reason: String
    ) {
        self.shouldRunLocalMemoryGuardrail = shouldRunLocalMemoryGuardrail
        self.eshBridgeExecutablePath = eshBridgeExecutablePath
        self.reason = reason
    }
}

public enum LocalModelGuardrailPolicy {
    public static func resolve(
        provider: String,
        userConfig: AshexUserConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        currentExecutablePath: String? = ProcessInfo.processInfo.arguments.first
    ) -> LocalModelGuardrailPolicyResolution {
        guard provider == "ollama" else {
            return .init(
                shouldRunLocalMemoryGuardrail: false,
                eshBridgeExecutablePath: nil,
                reason: "Provider \(provider) does not use the local Ollama memory guardrail."
            )
        }

        let optimization = userConfig.optimization
        guard optimization.enabled, optimization.backend == .esh else {
            return .init(
                shouldRunLocalMemoryGuardrail: true,
                eshBridgeExecutablePath: nil,
                reason: "Ollama is not routed through the esh optimization bridge."
            )
        }

        let inspector = EshOptimizationInspector(
            environment: environment,
            fileExists: fileExists,
            currentExecutablePath: currentExecutablePath
        )
        guard let executablePath = inspector.resolveExecutablePath(config: optimization.esh),
              fileExists(executablePath) else {
            return .init(
                shouldRunLocalMemoryGuardrail: true,
                eshBridgeExecutablePath: nil,
                reason: "Ollama requested esh routing, but no usable esh executable was found."
            )
        }

        return .init(
            shouldRunLocalMemoryGuardrail: false,
            eshBridgeExecutablePath: executablePath,
            reason: "Ollama is routed through esh, so the local Ollama model memory guardrail does not apply."
        )
    }
}
