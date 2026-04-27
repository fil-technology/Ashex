import AshexCore
import Foundation

struct EshModelSearchResult: Equatable, Sendable {
    let model: String
    let source: String
    let state: String
    let kind: String
    let size: String
    let downloads: String
    let date: String

    var displayName: String {
        model
    }

    var detail: String {
        [source, state, kind, size, downloads, date]
            .filter { !$0.isEmpty && $0 != "-" }
            .joined(separator: " • ")
    }
}

enum OpenAIAudioCatalog {
    static let speechModels = [
        "gpt-4o-mini-tts",
        "tts-1",
        "tts-1-hd",
    ]

    static func displayModels() -> [String] {
        speechModels.map { "\("openai")/\($0) • OpenAI speech model" }
    }
}

enum AudioSelectionCatalog {
    static func displayModels(
        chatProvider: String,
        chatModel: String,
        chatAvailableModels: [String],
        eshAudioModels: [String]
    ) -> [String] {
        var displayModels: [String] = []
        var seen = Set<String>()

        func append(provider: String, model: String, detail: String) {
            let reference = "\(provider)/\(model)"
            guard seen.insert(reference).inserted else { return }
            displayModels.append("\(reference) • \(detail)")
        }

        if AudioModelSupport.supportsVoice(provider: chatProvider, model: chatModel) {
            append(provider: chatProvider, model: chatModel, detail: "Current chat model")
        }

        for displayName in chatAvailableModels {
            guard let model = ModelCatalogDisplay.selectableModelName(from: displayName) else { continue }
            append(provider: chatProvider, model: model, detail: "Available from \(chatProvider)")
        }

        for model in eshAudioModels {
            append(provider: "esh", model: model, detail: "Installed esh audio model")
        }

        for displayName in OpenAIAudioCatalog.displayModels() {
            guard let model = ModelCatalogDisplay.selectableModelName(from: displayName) else { continue }
            append(provider: "openai", model: model, detail: "OpenAI speech model")
        }

        return displayModels
    }
}

enum EshCommandClient {
    static func listInstalledModels(configuration: CLIConfiguration) throws -> [String] {
        let resolved = try resolvedPaths(configuration: configuration)
        let capabilities = try CLIConfiguration.inspectEshCapabilities(
            executablePath: resolved.executablePath,
            homePath: resolved.homePath
        )
        return capabilities.installedModels
            .map(\.id)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func listInstalledAudioModels(configuration: CLIConfiguration) throws -> [String] {
        let output = try run(configuration: configuration, arguments: ["audio", "models"])
        return output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { line in
                line
                    .components(separatedBy: .whitespaces)
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    static func searchModels(
        configuration: CLIConfiguration,
        query: String,
        limit: Int = 8
    ) throws -> [EshModelSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let output = try run(
            configuration: configuration,
            arguments: ["model", "search", trimmed, "--limit", String(max(limit, 1))]
        )
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard lines.count > 1 else { return [] }

        return lines.dropFirst().compactMap(parseSearchResult(line:))
    }

    static func installModel(configuration: CLIConfiguration, query: String) throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AshexError.model("Model search term is empty.")
        }
        return try run(configuration: configuration, arguments: ["model", "install", trimmed])
    }

    static func speak(
        configuration: CLIConfiguration,
        text: String,
        model: String,
        outputURL: URL
    ) throws {
        _ = try run(
            configuration: configuration,
            arguments: ["audio", "speak", text, "--model", model, "--out", outputURL.path, "--force"]
        )
    }

    private static func parseSearchResult(line: String) -> EshModelSearchResult? {
        let columns = line.split(whereSeparator: { $0 == "\t" }).map(String.init)
        let normalizedColumns = columns.count > 1 ? columns : splitColumns(line)
        guard normalizedColumns.count >= 7 else { return nil }
        return EshModelSearchResult(
            model: normalizedColumns[2].trimmingCharacters(in: .whitespacesAndNewlines),
            source: normalizedColumns[0].trimmingCharacters(in: .whitespacesAndNewlines),
            state: normalizedColumns[1].trimmingCharacters(in: .whitespacesAndNewlines),
            kind: normalizedColumns[3].trimmingCharacters(in: .whitespacesAndNewlines),
            size: normalizedColumns[4].trimmingCharacters(in: .whitespacesAndNewlines),
            downloads: normalizedColumns[5].trimmingCharacters(in: .whitespacesAndNewlines),
            date: normalizedColumns[6].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func splitColumns(_ line: String) -> [String] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = regexColumnSeparator.matches(in: line, options: [], range: range)
        guard !matches.isEmpty else {
            return line
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        }

        var columns: [String] = []
        var currentLocation = range.location
        for match in matches {
            let segmentRange = NSRange(location: currentLocation, length: match.range.location - currentLocation)
            if let swiftRange = Range(segmentRange, in: line) {
                let column = line[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
                if !column.isEmpty {
                    columns.append(column)
                }
            }
            currentLocation = match.range.location + match.range.length
        }
        let tailRange = NSRange(location: currentLocation, length: range.length - currentLocation)
        if let swiftTailRange = Range(tailRange, in: line) {
            let column = line[swiftTailRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !column.isEmpty {
                columns.append(column)
            }
        }
        return columns
    }

    private static let regexColumnSeparator = try! NSRegularExpression(pattern: "\\s{2,}")

    private static func run(configuration: CLIConfiguration, arguments: [String]) throws -> String {
        let resolved = try resolvedPaths(configuration: configuration)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: resolved.executablePath)
        process.arguments = arguments
        process.environment = mergedEnvironment(homePath: resolved.homePath)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw AshexError.model(errorOutput.isEmpty ? output : errorOutput)
        }

        return output
    }

    private static func resolvedPaths(configuration: CLIConfiguration) throws -> (executablePath: String, homePath: String) {
        let inspector = EshOptimizationInspector()
        guard let executablePath = inspector.resolveExecutablePath(config: configuration.userConfig.optimization.esh) else {
            throw AshexError.model("`esh` was not found. Bundle it with Ashex, set optimization.esh.executablePath, or set ESH_EXECUTABLE.")
        }
        let homePath = inspector.resolveHomePath(config: configuration.userConfig.optimization.esh)
        return (executablePath, homePath)
    }

    private static func mergedEnvironment(homePath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ESH_HOME"] = homePath
        environment["COLUMNS"] = "240"
        return environment
    }
}
