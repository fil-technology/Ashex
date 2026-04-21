import Darwin
import Foundation

public struct HostResources: Sendable, Equatable {
    public let physicalMemoryBytes: UInt64
    public let usableLocalModelMemoryBytes: UInt64
    public let estimatedMemoryBandwidthGBps: Double?
    public let chipDescription: String?
    public let isUnifiedMemory: Bool

    public init(
        physicalMemoryBytes: UInt64,
        usableLocalModelMemoryBytes: UInt64? = nil,
        estimatedMemoryBandwidthGBps: Double? = nil,
        chipDescription: String? = nil,
        isUnifiedMemory: Bool = false
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.usableLocalModelMemoryBytes = usableLocalModelMemoryBytes ?? physicalMemoryBytes
        self.estimatedMemoryBandwidthGBps = estimatedMemoryBandwidthGBps
        self.chipDescription = chipDescription
        self.isUnifiedMemory = isUnifiedMemory
    }

    public static func current() -> HostResources {
        let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
        let chipDescription = SystemProfiler.chipDescription()
        let isUnifiedMemory = SystemProfiler.isAppleSilicon(chipDescription: chipDescription)
        let reserveBytes = ModelBudget.reserveBytes(
            physicalMemoryBytes: physicalMemoryBytes,
            isUnifiedMemory: isUnifiedMemory
        )

        return .init(
            physicalMemoryBytes: physicalMemoryBytes,
            usableLocalModelMemoryBytes: max(physicalMemoryBytes &- reserveBytes, physicalMemoryBytes / 2),
            estimatedMemoryBandwidthGBps: SystemProfiler.memoryBandwidthGBps(chipDescription: chipDescription, physicalMemoryBytes: physicalMemoryBytes),
            chipDescription: chipDescription,
            isUnifiedMemory: isUnifiedMemory
        )
    }
}

public struct LocalModelDescriptor: Sendable, Equatable {
    public let name: String
    public let sizeBytes: UInt64?

    public init(name: String, sizeBytes: UInt64?) {
        self.name = name
        self.sizeBytes = sizeBytes
    }
}

public enum ModelGuardrailSeverity: String, Sendable, Equatable {
    case ok
    case warning
    case blocked
}

public struct ModelGuardrailAssessment: Sendable, Equatable {
    public let severity: ModelGuardrailSeverity
    public let headline: String
    public let details: [String]
    public let selectedModel: String
    public let modelSizeBytes: UInt64?
    public let estimatedWorkingSetBytes: UInt64?
    public let estimatedContextReserveBytes: UInt64?
    public let usableLocalModelMemoryBytes: UInt64
    public let physicalMemoryBytes: UInt64
    public let estimatedTokensPerSecond: Double?

    public init(
        severity: ModelGuardrailSeverity,
        headline: String,
        details: [String],
        selectedModel: String,
        modelSizeBytes: UInt64?,
        estimatedWorkingSetBytes: UInt64?,
        estimatedContextReserveBytes: UInt64?,
        usableLocalModelMemoryBytes: UInt64,
        physicalMemoryBytes: UInt64,
        estimatedTokensPerSecond: Double?
    ) {
        self.severity = severity
        self.headline = headline
        self.details = details
        self.selectedModel = selectedModel
        self.modelSizeBytes = modelSizeBytes
        self.estimatedWorkingSetBytes = estimatedWorkingSetBytes
        self.estimatedContextReserveBytes = estimatedContextReserveBytes
        self.usableLocalModelMemoryBytes = usableLocalModelMemoryBytes
        self.physicalMemoryBytes = physicalMemoryBytes
        self.estimatedTokensPerSecond = estimatedTokensPerSecond
    }
}

public enum LocalModelGuardrails {
    public static func assessOllamaModel(
        model: String,
        installedModels: [LocalModelDescriptor],
        resources: HostResources = .current()
    ) -> ModelGuardrailAssessment {
        guard let selected = installedModels.first(where: { $0.name == model }) else {
            return .init(
                severity: .warning,
                headline: "Selected model is not installed",
                details: [
                    "Ashex could not find \(model) in the local Ollama catalog.",
                    "Pull the model first or choose one of the installed models before running."
                ],
                selectedModel: model,
                modelSizeBytes: nil,
                estimatedWorkingSetBytes: nil,
                estimatedContextReserveBytes: nil,
                usableLocalModelMemoryBytes: resources.usableLocalModelMemoryBytes,
                physicalMemoryBytes: resources.physicalMemoryBytes,
                estimatedTokensPerSecond: nil
            )
        }

        guard let modelSizeBytes = selected.sizeBytes else {
            return .init(
                severity: .warning,
                headline: "Model size is unknown",
                details: [
                    "Ashex could not determine the local model size for \(model).",
                    "Without a size estimate, it cannot apply memory guardrails accurately."
                ],
                selectedModel: model,
                modelSizeBytes: nil,
                estimatedWorkingSetBytes: nil,
                estimatedContextReserveBytes: nil,
                usableLocalModelMemoryBytes: resources.usableLocalModelMemoryBytes,
                physicalMemoryBytes: resources.physicalMemoryBytes,
                estimatedTokensPerSecond: nil
            )
        }

        let contextReserveBytes = ModelBudget.contextReserveBytes(modelSizeBytes: modelSizeBytes)
        let runtimeOverheadBytes = ModelBudget.runtimeOverheadBytes(modelSizeBytes: modelSizeBytes)
        let estimatedWorkingSetBytes = modelSizeBytes + contextReserveBytes + runtimeOverheadBytes
        let usageRatio = Double(estimatedWorkingSetBytes) / Double(max(resources.usableLocalModelMemoryBytes, 1))
        let estimatedTokensPerSecond = estimateTokensPerSecond(
            bandwidthGBps: resources.estimatedMemoryBandwidthGBps,
            workingSetBytes: estimatedWorkingSetBytes
        )

        let sizeSummary = """
        Model file size \(formatBytes(modelSizeBytes)); estimated working set \(formatBytes(estimatedWorkingSetBytes)); background-safe budget \(formatBytes(resources.usableLocalModelMemoryBytes)) out of \(formatBytes(resources.physicalMemoryBytes)) system RAM.
        """
        let contextSummary = "Ashex reserves about \(formatBytes(contextReserveBytes)) for context, KV cache, and runtime overhead."
        let chipSummary = resources.chipDescription.map {
            if let bandwidth = resources.estimatedMemoryBandwidthGBps {
                return "\($0) with estimated memory bandwidth \(String(format: "%.0f", bandwidth)) GB/s."
            }
            return $0
        }

        let throughputSummary = estimatedTokensPerSecond.map {
            "Estimated memory-bound throughput is about \(String(format: "%.1f", $0)) tk/s."
        }

        let smallerModels = installedModels
            .filter { ($0.sizeBytes ?? .max) < modelSizeBytes }
            .sorted { ($0.sizeBytes ?? .max) < ($1.sizeBytes ?? .max) }
            .prefix(3)
            .map(\.name)

        let physicalMemoryRatio = Double(estimatedWorkingSetBytes) / Double(max(resources.physicalMemoryBytes, 1))
        if physicalMemoryRatio >= 0.95 {
            var details = [sizeSummary, contextSummary]
            if let chipSummary { details.append(chipSummary) }
            if let throughputSummary { details.append(throughputSummary) }
            details.append("This model is close to or above total system RAM after runtime overhead, so Ashex blocks it by default.")
            if !smallerModels.isEmpty {
                details.append("Try a smaller local model instead: \(smallerModels.joined(separator: ", ")).")
            }
            return .init(
                severity: .blocked,
                headline: "Selected model exceeds the hard local-memory limit",
                details: details,
                selectedModel: model,
                modelSizeBytes: modelSizeBytes,
                estimatedWorkingSetBytes: estimatedWorkingSetBytes,
                estimatedContextReserveBytes: contextReserveBytes,
                usableLocalModelMemoryBytes: resources.usableLocalModelMemoryBytes,
                physicalMemoryBytes: resources.physicalMemoryBytes,
                estimatedTokensPerSecond: estimatedTokensPerSecond
            )
        }

        if usageRatio >= 0.7 {
            var details = [sizeSummary, contextSummary]
            if let chipSummary { details.append(chipSummary) }
            if let throughputSummary { details.append(throughputSummary) }
            details.append("This model is installed and may run, but it is large enough that other apps can feel pressure while Ashex is active.")
            if !smallerModels.isEmpty {
                details.append("If you want a lighter option, try: \(smallerModels.joined(separator: ", ")).")
            }
            return .init(
                severity: .warning,
                headline: "Selected model is memory-heavy for this Mac",
                details: details,
                selectedModel: model,
                modelSizeBytes: modelSizeBytes,
                estimatedWorkingSetBytes: estimatedWorkingSetBytes,
                estimatedContextReserveBytes: contextReserveBytes,
                usableLocalModelMemoryBytes: resources.usableLocalModelMemoryBytes,
                physicalMemoryBytes: resources.physicalMemoryBytes,
                estimatedTokensPerSecond: estimatedTokensPerSecond
            )
        }

        var details = [sizeSummary, contextSummary]
        if let chipSummary { details.append(chipSummary) }
        if let throughputSummary { details.append(throughputSummary) }
        details.append("Ashex expects this model to fit comfortably on the current Mac.")
        return .init(
            severity: .ok,
            headline: "Selected model fits the local memory budget",
            details: details,
            selectedModel: model,
            modelSizeBytes: modelSizeBytes,
            estimatedWorkingSetBytes: estimatedWorkingSetBytes,
            estimatedContextReserveBytes: contextReserveBytes,
            usableLocalModelMemoryBytes: resources.usableLocalModelMemoryBytes,
            physicalMemoryBytes: resources.physicalMemoryBytes,
            estimatedTokensPerSecond: estimatedTokensPerSecond
        )
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func estimateTokensPerSecond(bandwidthGBps: Double?, workingSetBytes: UInt64) -> Double? {
        guard let bandwidthGBps, workingSetBytes > 0 else { return nil }
        let workingSetGB = Double(workingSetBytes) / 1_000_000_000
        guard workingSetGB > 0 else { return nil }
        return (bandwidthGBps / workingSetGB) * 0.9
    }
}

public struct OllamaCatalogClient: Sendable {
    public init() {}

    public func fetchModels(baseURL: URL, session: URLSession = .shared) async throws -> [LocalModelDescriptor] {
        let tagsURL = baseURL.deletingLastPathComponent().appendingPathComponent("tags")
        let (data, response) = try await session.data(from: tagsURL)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw AshexError.model("Failed to read Ollama model catalog from \(tagsURL.absoluteString)")
        }

        let payload = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return payload.models.map {
            .init(name: $0.name, sizeBytes: $0.size.flatMap { UInt64(exactly: $0) })
        }
    }

    private struct OllamaTagsResponse: Decodable {
        let models: [OllamaModel]

        struct OllamaModel: Decodable {
            let name: String
            let size: Int64?
        }
    }
}

private enum ModelBudget {
    static func reserveBytes(physicalMemoryBytes: UInt64, isUnifiedMemory: Bool) -> UInt64 {
        let fraction = isUnifiedMemory ? 0.30 : 0.22
        let baseline = isUnifiedMemory ? gigabytes(6) : gigabytes(4)
        return max(UInt64(Double(physicalMemoryBytes) * fraction), baseline)
    }

    static func contextReserveBytes(modelSizeBytes: UInt64) -> UInt64 {
        if modelSizeBytes <= megabytes(512) {
            return max(megabytes(384), UInt64(Double(modelSizeBytes) * 0.45))
        }
        if modelSizeBytes <= gigabytes(1) {
            return max(megabytes(512), UInt64(Double(modelSizeBytes) * 0.32))
        }
        return max(gigabytes(1), UInt64(Double(modelSizeBytes) * 0.18))
    }

    static func runtimeOverheadBytes(modelSizeBytes: UInt64) -> UInt64 {
        if modelSizeBytes <= megabytes(512) {
            return max(megabytes(256), UInt64(Double(modelSizeBytes) * 0.20))
        }
        if modelSizeBytes <= gigabytes(1) {
            return max(megabytes(384), UInt64(Double(modelSizeBytes) * 0.12))
        }
        return max(megabytes(768), UInt64(Double(modelSizeBytes) * 0.08))
    }

    static func gigabytes(_ value: UInt64) -> UInt64 {
        value * 1_000_000_000
    }

    static func megabytes(_ value: UInt64) -> UInt64 {
        value * 1_000_000
    }
}

private enum SystemProfiler {
    static func chipDescription() -> String? {
        sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model")
    }

    static func isAppleSilicon(chipDescription: String?) -> Bool {
        if let chip = chipDescription?.lowercased(), chip.contains("apple") {
            return true
        }
        return sysctlInt("hw.optional.arm64") == 1
    }

    static func memoryBandwidthGBps(chipDescription: String?, physicalMemoryBytes: UInt64) -> Double? {
        guard let chip = chipDescription?.lowercased() else {
            return fallbackBandwidth(physicalMemoryBytes: physicalMemoryBytes)
        }

        let appleSiliconMap: [(String, Double)] = [
            ("m4 max", 600), ("m4 pro", 300), ("m4", 150),
            ("m3 max", 400), ("m3 pro", 200), ("m3", 100),
            ("m2 ultra", 800), ("m2 max", 400), ("m2 pro", 200), ("m2", 100),
            ("m1 ultra", 800), ("m1 max", 400), ("m1 pro", 200), ("m1", 200),
        ]

        for (marker, bandwidth) in appleSiliconMap where chip.contains(marker) {
            return bandwidth
        }

        return fallbackBandwidth(physicalMemoryBytes: physicalMemoryBytes)
    }

    private static func fallbackBandwidth(physicalMemoryBytes: UInt64) -> Double {
        let gigabytes = Double(physicalMemoryBytes) / 1_000_000_000
        switch gigabytes {
        case 0..<16:
            return 48
        case 16..<32:
            return 68
        case 32..<64:
            return 102
        default:
            return 150
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size: size_t = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            let bytes = pointer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
