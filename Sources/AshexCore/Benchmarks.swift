import Foundation

public enum BenchmarkCategory: String, Codable, Sendable, CaseIterable {
    case reasoning
    case agentic
    case toolUse = "tool_use"
    case coding
    case recovery
    case memory
}

public struct BenchmarkSuite: Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let description: String?
    public let cases: [BenchmarkCase]

    public init(id: String, title: String, description: String? = nil, cases: [BenchmarkCase]) {
        self.id = id
        self.title = title
        self.description = description
        self.cases = cases
    }
}

public struct BenchmarkCase: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let category: BenchmarkCategory
    public let title: String
    public let prompt: String?
    public let steps: [BenchmarkStep]?
    public let expected: BenchmarkExpectation
    public let scoring: BenchmarkScoring?
    public let tags: [String]
    public let timeoutSeconds: Int?

    public init(
        id: String,
        category: BenchmarkCategory,
        title: String,
        prompt: String? = nil,
        steps: [BenchmarkStep]? = nil,
        expected: BenchmarkExpectation = .init(),
        scoring: BenchmarkScoring? = nil,
        tags: [String] = [],
        timeoutSeconds: Int? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.prompt = prompt
        self.steps = steps
        self.expected = expected
        self.scoring = scoring
        self.tags = tags
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct BenchmarkStep: Codable, Sendable, Equatable {
    public let prompt: String

    public init(prompt: String) {
        self.prompt = prompt
    }
}

public struct BenchmarkExpectation: Codable, Sendable, Equatable {
    public let mustContain: [String]
    public let mustNotContain: [String]
    public let approxNumericAnswer: ApproxNumericAnswer?
    public let toolActions: [String]
    public let requiresToolUse: Bool?
    public let shouldAskClarifyingQuestion: Bool?

    public init(
        mustContain: [String] = [],
        mustNotContain: [String] = [],
        approxNumericAnswer: ApproxNumericAnswer? = nil,
        toolActions: [String] = [],
        requiresToolUse: Bool? = nil,
        shouldAskClarifyingQuestion: Bool? = nil
    ) {
        self.mustContain = mustContain
        self.mustNotContain = mustNotContain
        self.approxNumericAnswer = approxNumericAnswer
        self.toolActions = toolActions
        self.requiresToolUse = requiresToolUse
        self.shouldAskClarifyingQuestion = shouldAskClarifyingQuestion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mustContain = try container.decodeIfPresent([String].self, forKey: .mustContain) ?? []
        self.mustNotContain = try container.decodeIfPresent([String].self, forKey: .mustNotContain) ?? []
        self.approxNumericAnswer = try container.decodeIfPresent(ApproxNumericAnswer.self, forKey: .approxNumericAnswer)
        self.toolActions = try container.decodeIfPresent([String].self, forKey: .toolActions) ?? []
        self.requiresToolUse = try container.decodeIfPresent(Bool.self, forKey: .requiresToolUse)
        self.shouldAskClarifyingQuestion = try container.decodeIfPresent(Bool.self, forKey: .shouldAskClarifyingQuestion)
    }
}

public struct ApproxNumericAnswer: Codable, Sendable, Equatable {
    public let value: Double
    public let tolerancePercent: Double

    public init(value: Double, tolerancePercent: Double) {
        self.value = value
        self.tolerancePercent = tolerancePercent
    }
}

public struct BenchmarkScoring: Codable, Sendable, Equatable {
    public let maxScore: Double
    public let criteria: [BenchmarkCriterion]

    public init(maxScore: Double = 10, criteria: [BenchmarkCriterion] = []) {
        self.maxScore = maxScore
        self.criteria = criteria
    }
}

public struct BenchmarkCriterion: Codable, Sendable, Equatable {
    public let name: String
    public let points: Double

    public init(name: String, points: Double) {
        self.name = name
        self.points = points
    }
}

public struct BenchmarkRunSummary: Codable, Sendable, Equatable {
    public let suiteID: String
    public let suiteTitle: String
    public let provider: String
    public let model: String
    public let startedAt: Date
    public let finishedAt: Date
    public let results: [BenchmarkCaseResult]

    public var totalScore: Double { results.reduce(0) { $0 + $1.score } }
    public var maxScore: Double { results.reduce(0) { $0 + $1.maxScore } }
    public var passedCount: Int { results.filter(\.passed).count }

    public init(
        suiteID: String,
        suiteTitle: String,
        provider: String,
        model: String,
        startedAt: Date,
        finishedAt: Date,
        results: [BenchmarkCaseResult]
    ) {
        self.suiteID = suiteID
        self.suiteTitle = suiteTitle
        self.provider = provider
        self.model = model
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.results = results
    }
}

public struct BenchmarkCaseResult: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let category: BenchmarkCategory
    public let title: String
    public let score: Double
    public let maxScore: Double
    public let passed: Bool
    public let durationSeconds: Double
    public let finalAnswer: String
    public let toolActions: [String]
    public let failures: [String]
    public let error: String?

    public init(
        id: String,
        category: BenchmarkCategory,
        title: String,
        score: Double,
        maxScore: Double,
        passed: Bool,
        durationSeconds: Double,
        finalAnswer: String,
        toolActions: [String],
        failures: [String],
        error: String?
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.score = score
        self.maxScore = maxScore
        self.passed = passed
        self.durationSeconds = durationSeconds
        self.finalAnswer = finalAnswer
        self.toolActions = toolActions
        self.failures = failures
        self.error = error
    }
}

public enum BenchmarkLoader {
    public static func loadSuite(from url: URL) throws -> BenchmarkSuite {
        let data = try Data(contentsOf: url)
        do {
            return try decoder.decode(BenchmarkSuite.self, from: data)
        } catch {
            if ["yaml", "yml"].contains(url.pathExtension.lowercased()) {
                let jsonData = try JSONCompatibleYAMLConverter.convertToJSONData(data)
                return try decoder.decode(BenchmarkSuite.self, from: jsonData)
            }
            throw error
        }
    }

    public static func bundledSuiteURLs() -> [URL] {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Benchmarks/Suites", isDirectory: true)
        let bundledRoot = Bundle.module.resourceURL?
            .appendingPathComponent("Benchmarks/Suites", isDirectory: true)

        let roots = [bundledRoot, sourceRoot].compactMap { $0 }
        var urls: [URL] = []
        for root in roots {
            if let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ) {
                urls.append(contentsOf: entries.filter { ["json", "yaml", "yml"].contains($0.pathExtension.lowercased()) })
            }
        }
        return Array(Set(urls)).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }()
}

public struct BenchmarkRunner: Sendable {
    public typealias RuntimeFactory = @Sendable (_ benchmarkCase: BenchmarkCase) throws -> any RuntimeStreaming

    private let runtimeFactory: RuntimeFactory
    private let provider: String
    private let model: String
    private let maxIterations: Int

    public init(
        provider: String,
        model: String,
        maxIterations: Int,
        runtimeFactory: @escaping RuntimeFactory
    ) {
        self.provider = provider
        self.model = model
        self.maxIterations = maxIterations
        self.runtimeFactory = runtimeFactory
    }

    public func run(suite: BenchmarkSuite) async -> BenchmarkRunSummary {
        let startedAt = Date()
        var results: [BenchmarkCaseResult] = []
        for benchmarkCase in suite.cases {
            results.append(await run(case: benchmarkCase))
        }
        return BenchmarkRunSummary(
            suiteID: suite.id,
            suiteTitle: suite.title,
            provider: provider,
            model: model,
            startedAt: startedAt,
            finishedAt: Date(),
            results: results
        )
    }

    public func run(case benchmarkCase: BenchmarkCase) async -> BenchmarkCaseResult {
        let startedAt = Date()
        do {
            let outcome = try await runCaseWithTimeout(benchmarkCase)
            let score = BenchmarkScorer.score(case: benchmarkCase, outcome: outcome)
            return BenchmarkCaseResult(
                id: benchmarkCase.id,
                category: benchmarkCase.category,
                title: benchmarkCase.title,
                score: score.score,
                maxScore: score.maxScore,
                passed: score.failures.isEmpty,
                durationSeconds: Date().timeIntervalSince(startedAt),
                finalAnswer: outcome.finalAnswer,
                toolActions: outcome.toolActions,
                failures: score.failures,
                error: nil
            )
        } catch {
            let maxScore = benchmarkCase.scoring?.maxScore ?? 10
            return BenchmarkCaseResult(
                id: benchmarkCase.id,
                category: benchmarkCase.category,
                title: benchmarkCase.title,
                score: 0,
                maxScore: maxScore,
                passed: false,
                durationSeconds: Date().timeIntervalSince(startedAt),
                finalAnswer: "",
                toolActions: [],
                failures: ["runtime_error"],
                error: error.localizedDescription
            )
        }
    }

    private func runCaseWithTimeout(_ benchmarkCase: BenchmarkCase) async throws -> BenchmarkOutcome {
        let timeout = benchmarkCase.timeoutSeconds ?? 120
        return try await withThrowingTaskGroup(of: BenchmarkOutcome.self) { group in
            group.addTask {
                try await self.runCaseWithoutTimeout(benchmarkCase)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                throw AshexError.model("Benchmark case timed out after \(timeout) seconds")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func runCaseWithoutTimeout(_ benchmarkCase: BenchmarkCase) async throws -> BenchmarkOutcome {
        let runtime = try runtimeFactory(benchmarkCase)
        let prompts = benchmarkCase.steps?.map(\.prompt) ?? benchmarkCase.prompt.map { [$0] } ?? []
        guard !prompts.isEmpty else {
            throw AshexError.model("Benchmark case \(benchmarkCase.id) has no prompt or steps")
        }

        var threadID: UUID?
        var finalAnswer = ""
        var toolActions: [String] = []
        var toolSuccesses: [Bool] = []
        var errors: [String] = []

        for prompt in prompts {
            let stream = runtime.run(.init(prompt: prompt, maxIterations: maxIterations, threadID: threadID))
            for await event in stream {
                switch event.payload {
                case .runStarted(let newThreadID, _):
                    if threadID == nil {
                        threadID = newThreadID
                    }
                case .toolCallStarted(_, _, let toolName, let arguments):
                    toolActions.append(BenchmarkToolActionFormatter.actionName(toolName: toolName, arguments: arguments))
                case .toolCallFinished(_, _, let success, _):
                    toolSuccesses.append(success)
                case .finalAnswer(_, _, let text):
                    finalAnswer = text
                case .error(_, let message):
                    errors.append(message)
                default:
                    break
                }
            }
        }

        return BenchmarkOutcome(
            finalAnswer: finalAnswer,
            toolActions: toolActions,
            toolSuccesses: toolSuccesses,
            errors: errors
        )
    }
}

public enum BenchmarkScorer {
    public struct Score: Sendable, Equatable {
        public let score: Double
        public let maxScore: Double
        public let failures: [String]
    }

    public static func score(case benchmarkCase: BenchmarkCase, outcome: BenchmarkOutcome) -> Score {
        let expectation = benchmarkCase.expected
        let maxScore = benchmarkCase.scoring?.maxScore ?? 10
        var checks: [(String, Bool)] = []
        let normalizedAnswer = outcome.finalAnswer.lowercased()

        for value in expectation.mustContain {
            checks.append(("mustContain:\(value)", normalizedAnswer.contains(value.lowercased())))
        }

        for value in expectation.mustNotContain {
            checks.append(("mustNotContain:\(value)", !normalizedAnswer.contains(value.lowercased())))
        }

        if let approx = expectation.approxNumericAnswer {
            checks.append(("approxNumericAnswer:\(approx.value)", containsApproximateNumber(in: outcome.finalAnswer, expectation: approx)))
        }

        for action in expectation.toolActions {
            checks.append(("toolAction:\(action)", outcome.toolActions.contains { $0 == action || $0.hasSuffix(".\(action)") }))
        }

        if let requiresToolUse = expectation.requiresToolUse {
            checks.append(("requiresToolUse", requiresToolUse == !outcome.toolActions.isEmpty))
        }

        if let shouldAskClarifyingQuestion = expectation.shouldAskClarifyingQuestion {
            checks.append(("shouldAskClarifyingQuestion", shouldAskClarifyingQuestion == asksClarifyingQuestion(outcome.finalAnswer)))
        }

        if !outcome.errors.isEmpty {
            checks.append(("noRuntimeErrors", false))
        }

        guard !checks.isEmpty else {
            return Score(score: maxScore, maxScore: maxScore, failures: [])
        }

        let failures = checks.filter { !$0.1 }.map(\.0)
        let passed = Double(checks.count - failures.count)
        let score = (passed / Double(checks.count)) * maxScore
        return Score(score: (score * 100).rounded() / 100, maxScore: maxScore, failures: failures)
    }

    private static func containsApproximateNumber(in text: String, expectation: ApproxNumericAnswer) -> Bool {
        let numbers = extractNumbers(from: text)
        let tolerance = abs(expectation.value) * (expectation.tolerancePercent / 100)
        return numbers.contains { abs($0 - expectation.value) <= tolerance }
    }

    private static func extractNumbers(from text: String) -> [Double] {
        let pattern = #"[-+]?\d[\d,]*(?:\.\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: nsRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return Double(text[range].replacingOccurrences(of: ",", with: ""))
        }
    }

    private static func asksClarifyingQuestion(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return normalized.contains("?")
            || normalized.contains("clarify")
            || normalized.contains("check")
            || normalized.contains("confirm")
            || normalized.contains("missing")
    }
}

public struct BenchmarkOutcome: Sendable, Equatable {
    public let finalAnswer: String
    public let toolActions: [String]
    public let toolSuccesses: [Bool]
    public let errors: [String]

    public init(finalAnswer: String, toolActions: [String], toolSuccesses: [Bool], errors: [String]) {
        self.finalAnswer = finalAnswer
        self.toolActions = toolActions
        self.toolSuccesses = toolSuccesses
        self.errors = errors
    }
}

public enum BenchmarkReportWriter {
    public static func writeJSON(_ summary: BenchmarkRunSummary, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(summary)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    public static func writeMarkdown(_ summary: BenchmarkRunSummary, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown(for: summary).write(to: url, atomically: true, encoding: .utf8)
    }

    public static func markdown(for summary: BenchmarkRunSummary) -> String {
        var lines: [String] = [
            "# Ashex Benchmark Report",
            "",
            "- Suite: \(summary.suiteTitle) (`\(summary.suiteID)`)",
            "- Model: \(summary.provider)/\(summary.model)",
            "- Score: \(format(summary.totalScore))/\(format(summary.maxScore))",
            "- Passed: \(summary.passedCount)/\(summary.results.count)",
            "",
            "| Case | Category | Score | Result | Failures |",
            "| --- | --- | ---: | --- | --- |",
        ]

        for result in summary.results {
            let failures = result.failures.isEmpty ? "" : result.failures.joined(separator: ", ")
            lines.append("| `\(result.id)` | \(result.category.rawValue) | \(format(result.score))/\(format(result.maxScore)) | \(result.passed ? "pass" : "fail") | \(failures) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func comparisonMarkdown(summaries: [BenchmarkRunSummary]) -> String {
        var lines = [
            "# Ashex Benchmark Comparison",
            "",
            "| Model | Suite | Score | Passed |",
            "| --- | --- | ---: | ---: |",
        ]
        for summary in summaries.sorted(by: { $0.totalScore > $1.totalScore }) {
            lines.append("| \(summary.provider)/\(summary.model) | \(summary.suiteID) | \(format(summary.totalScore))/\(format(summary.maxScore)) | \(summary.passedCount)/\(summary.results.count) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }
}

private enum BenchmarkToolActionFormatter {
    static func actionName(toolName: String, arguments: JSONObject) -> String {
        if let operation = arguments["operation"]?.stringValue, !operation.isEmpty {
            switch (toolName, operation) {
            case ("filesystem", "write_text_file"):
                return "create_file"
            case ("filesystem", "read_text_file"):
                return "read_file"
            case ("filesystem", "list_directory"):
                return "list_files"
            default:
                return "\(toolName).\(operation)"
            }
        }
        return toolName
    }
}

private enum JSONCompatibleYAMLConverter {
    static func convertToJSONData(_ data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AshexError.model("YAML benchmark file is not valid UTF-8")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return data
        }
        throw AshexError.model("Only JSON-compatible YAML benchmark files are supported")
    }
}
