import AshexCore
import Foundation

enum OptimizationCLICommand: Equatable {
    case doctor([String])
    case resolve([String])

    static func parse(arguments: [String]) -> OptimizationCLICommand? {
        guard arguments.count >= 3, arguments[1] == "optimize" else { return nil }
        switch arguments[2] {
        case "doctor":
            return .doctor(Array(arguments.dropFirst(3)))
        case "resolve":
            return .resolve(Array(arguments.dropFirst(3)))
        default:
            return nil
        }
    }
}

enum OptimizationCLI {
    static func handle(arguments: [String]) throws -> Bool {
        guard let command = OptimizationCLICommand.parse(arguments: arguments) else {
            return false
        }

        switch command {
        case .doctor(let extraArguments):
            try doctor(extraArguments: extraArguments)
        case .resolve(let extraArguments):
            try resolve(extraArguments: extraArguments)
        }

        return true
    }

    private static func doctor(extraArguments: [String]) throws {
        let configuration = try CLIConfiguration(arguments: [CommandLine.arguments[0]] + extraArguments)
        let optimization = configuration.userConfig.optimization
        let inspector = EshOptimizationInspector()
        let report = inspector.doctor(
            provider: configuration.provider,
            model: configuration.model,
            taskKind: .feature,
            prompt: "Inspect current optimization support and recommend a cache mode.",
            config: optimization
        )

        print("optimization enabled: \(optimization.enabled)")
        print("backend: \(optimization.backend.rawValue)")
        print("configured_mode: \(optimization.mode.rawValue)")
        print("configured_intent: \(optimization.intent.rawValue)")
        print("provider: \(configuration.provider)")
        print("model: \(configuration.model)")
        print("esh_executable: \(report.executablePath ?? "<not found>")")
        print("esh_home: \(report.homePath)")
        print("triattention_calibration: \(report.calibrationPath)")
        print("esh_available: \(report.executableAvailable)")
        print("triattention_ready: \(report.calibrationAvailable)")
        print("recommended_mode: \(report.recommendedMode.rawValue)")
        print("reason: \(report.recommendationReason)")
    }

    private static func resolve(extraArguments: [String]) throws {
        guard let task = optionValue(named: "--task", in: extraArguments), !task.isEmpty else {
            throw AshexError.model("optimize resolve requires --task \"...\"")
        }
        let configurationArguments = removingOption(named: "--task", from: extraArguments)
        let configuration = try CLIConfiguration(arguments: [CommandLine.arguments[0]] + configurationArguments)
        let optimization = configuration.userConfig.optimization
        let taskKind = TaskPlanner.classify(prompt: task)
        let inspector = EshOptimizationInspector()
        let report = inspector.doctor(
            provider: configuration.provider,
            model: configuration.model,
            taskKind: taskKind,
            prompt: task,
            config: optimization
        )

        print("task_kind: \(taskKind.rawValue)")
        print("provider: \(configuration.provider)")
        print("model: \(configuration.model)")
        print("recommended_mode: \(report.recommendedMode.rawValue)")
        print("reason: \(report.recommendationReason)")
        print("triattention_ready: \(report.calibrationAvailable)")
    }

    private static func optionValue(named option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func removingOption(named option: String, from arguments: [String]) -> [String] {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return arguments
        }
        var copy = arguments
        copy.removeSubrange(index...(index + 1))
        return copy
    }
}
