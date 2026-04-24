import AshexCore
import Foundation

enum BenchmarkCLI {
    static func handle(arguments: [String]) async throws -> Bool {
        guard arguments.dropFirst().first == "benchmark" else { return false }
        let command = arguments.dropFirst().dropFirst().first ?? "help"
        switch command {
        case "list":
            try listSuites()
        case "run":
            try await run(arguments: arguments)
        case "compare":
            try compare(arguments: arguments)
        case "help", "--help", "-h":
            print(helpText)
        default:
            throw AshexError.model("Unknown benchmark command '\(command)'.\n\(helpText)")
        }
        return true
    }

    private static func listSuites() throws {
        let urls = BenchmarkLoader.bundledSuiteURLs()
        if urls.isEmpty {
            print("No bundled benchmark suites found.")
            return
        }
        for url in urls {
            let suite = try BenchmarkLoader.loadSuite(from: url)
            print("\(suite.id): \(suite.title) (\(suite.cases.count) cases) [\(url.lastPathComponent)]")
        }
    }

    private static func run(arguments: [String]) async throws {
        let options = try RunOptions(arguments: arguments)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        try await configuration.validateModelGuardrails()

        let suite = try options.loadSuite()
        let runID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let outputRoot = options.outputURL ?? configuration.storageRoot
            .appendingPathComponent("benchmarks", isDirectory: true)
            .appendingPathComponent("reports", isDirectory: true)
            .appendingPathComponent(runID, isDirectory: true)

        let runner = BenchmarkRunner(
            provider: configuration.provider,
            model: configuration.model,
            maxIterations: configuration.maxIterations
        ) { benchmarkCase in
            let safeCaseID = benchmarkCase.id.map { character in
                character.isLetter || character.isNumber ? character : "_"
            }.map(String.init).joined()
            let storage = configuration.storageRoot
                .appendingPathComponent("benchmarks", isDirectory: true)
                .appendingPathComponent("runs", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            } catch {
                throw AshexError.model("Failed to create benchmark runtime storage at \(storage.path): \(error.localizedDescription)")
            }
            let persistence = SQLitePersistenceStore(databaseURL: storage.appendingPathComponent("\(safeCaseID).sqlite"))
            do {
                try persistence.initialize()
                return try configuration.makeRuntime(
                    persistence: persistence,
                    provider: configuration.provider,
                    model: configuration.model,
                    approvalPolicy: TrustedApprovalPolicy()
                )
            } catch {
                throw AshexError.model("Failed to prepare benchmark runtime for \(benchmarkCase.id) at \(storage.path): \(error.localizedDescription)")
            }
        }

        print("Running \(suite.cases.count) benchmark case(s) against \(configuration.provider)/\(configuration.model)...")
        let summary = await runner.run(suite: suite)

        let jsonURL: URL
        let markdownURL: URL
        if outputRoot.pathExtension == "json" || outputRoot.pathExtension == "md" {
            jsonURL = outputRoot.deletingPathExtension().appendingPathExtension("json")
            markdownURL = outputRoot.deletingPathExtension().appendingPathExtension("md")
        } else {
            jsonURL = outputRoot.appendingPathComponent("benchmark-results.json")
            markdownURL = outputRoot.appendingPathComponent("benchmark-results.md")
        }

        switch options.format {
        case .json:
            try BenchmarkReportWriter.writeJSON(summary, to: jsonURL)
            print("Wrote JSON report: \(jsonURL.path)")
        case .markdown:
            try BenchmarkReportWriter.writeMarkdown(summary, to: markdownURL)
            print("Wrote Markdown report: \(markdownURL.path)")
        case .both:
            try BenchmarkReportWriter.writeJSON(summary, to: jsonURL)
            try BenchmarkReportWriter.writeMarkdown(summary, to: markdownURL)
            print("Wrote reports:")
            print("- \(jsonURL.path)")
            print("- \(markdownURL.path)")
        }

        print("Score: \(format(summary.totalScore))/\(format(summary.maxScore)); passed \(summary.passedCount)/\(summary.results.count)")
    }

    private static func compare(arguments: [String]) throws {
        let options = try CompareOptions(arguments: arguments)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summaries = try options.inputURLs.map { url in
            try decoder.decode(BenchmarkRunSummary.self, from: Data(contentsOf: url))
        }
        let markdown = BenchmarkReportWriter.comparisonMarkdown(summaries: summaries)
        if let outputURL = options.outputURL {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
            print("Wrote comparison report: \(outputURL.path)")
        } else {
            print(markdown)
        }
    }

    private static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    static let helpText = """
    Usage:
      ashex benchmark list
      ashex benchmark run [--suite ID_OR_PATH] [--format json|markdown|both] [--output PATH] [options]
      ashex benchmark compare RESULT.json RESULT.json... [--output report.md]

    Benchmark run options also accept:
      --workspace PATH
      --storage PATH
      --provider NAME
      --model NAME
      --max-iterations N
    """

    private enum OutputFormat: String {
        case json
        case markdown
        case both
    }

    private struct RunOptions {
        var suite: String?
        var outputURL: URL?
        var format: OutputFormat = .both
        var configurationArguments: [String]

        init(arguments: [String]) throws {
            var configurationArguments = [arguments.first ?? "ashex"]
            var iterator = arguments.dropFirst().dropFirst().dropFirst().makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case "--suite":
                    guard let value = iterator.next() else { throw AshexError.model("Missing value for --suite") }
                    suite = value
                case "--output":
                    guard let value = iterator.next() else { throw AshexError.model("Missing value for --output") }
                    outputURL = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
                case "--format":
                    guard let value = iterator.next(), let parsed = OutputFormat(rawValue: value) else {
                        throw AshexError.model("Invalid value for --format. Supported: json, markdown, both")
                    }
                    format = parsed
                case "--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode":
                    guard let value = iterator.next() else { throw AshexError.model("Missing value for \(argument)") }
                    configurationArguments.append(argument)
                    configurationArguments.append(value)
                default:
                    throw AshexError.model("Unknown benchmark run option '\(argument)'")
                }
            }
            self.configurationArguments = configurationArguments
        }

        func loadSuite() throws -> BenchmarkSuite {
            if let suite {
                let url = URL(fileURLWithPath: suite, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
                if FileManager.default.fileExists(atPath: url.path) {
                    return try BenchmarkLoader.loadSuite(from: url)
                }
                let matches = try BenchmarkLoader.bundledSuiteURLs()
                    .map { try BenchmarkLoader.loadSuite(from: $0) }
                    .filter { $0.id == suite || $0.id.replacingOccurrences(of: "_", with: "-") == suite }
                guard let match = matches.first else {
                    throw AshexError.model("Benchmark suite '\(suite)' was not found. Run `ashex benchmark list`.")
                }
                return match
            }

            let suites = try BenchmarkLoader.bundledSuiteURLs().map { try BenchmarkLoader.loadSuite(from: $0) }
            return BenchmarkSuite(
                id: "starter",
                title: "Starter Benchmark Suite",
                description: "All bundled starter benchmark cases.",
                cases: suites.flatMap(\.cases)
            )
        }
    }

    private struct CompareOptions {
        var inputURLs: [URL] = []
        var outputURL: URL?

        init(arguments: [String]) throws {
            var iterator = arguments.dropFirst().dropFirst().dropFirst().makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case "--output":
                    guard let value = iterator.next() else { throw AshexError.model("Missing value for --output") }
                    outputURL = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
                default:
                    inputURLs.append(URL(fileURLWithPath: argument, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL)
                }
            }
            guard inputURLs.count >= 2 else {
                throw AshexError.model("Benchmark comparison requires at least two JSON result files")
            }
        }
    }
}
