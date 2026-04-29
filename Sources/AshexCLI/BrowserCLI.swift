import AshexCore
import Foundation

enum BrowserCLI {
    static func handle(arguments: [String]) async throws -> Bool {
        guard arguments.dropFirst().first == "browser" else { return false }
        let subcommand = arguments.dropFirst().dropFirst().first ?? "help"
        switch subcommand {
        case "doctor":
            try await doctor(arguments: arguments)
        case "backends":
            try await backends(arguments: arguments)
        case "fetch":
            try await fetch(arguments: arguments)
        case "eval":
            try await eval(arguments: arguments)
        case "screenshot":
            try await screenshot(arguments: arguments)
        case "serve":
            try await serve(arguments: arguments)
        case "benchmark":
            try await benchmark(arguments: arguments)
        case "help", "--help", "-h":
            print(helpText)
        default:
            throw AshexError.model("Unknown browser command '\(subcommand)'.\n\(helpText)")
        }
        return true
    }

    private static func doctor(arguments: [String]) async throws {
        let configuration = try CLIConfiguration(arguments: passthroughConfigurationArguments(arguments))
        let report = await BrowserManager(configSection: configuration.userConfig.browser).doctor()
        print("Configured backend: \(report.configuredBackend)")
        print("Obscura path: \(report.obscuraPath ?? "<not found>")")
        print("Obscura available: \(report.obscuraAvailable ? "yes" : "no")")
        print("Obscura detail: \(report.obscuraDetail)")
        print("CDP endpoint: \(report.cdpEndpoint)")
        print("CDP reachable: \(report.cdpReachable ? "yes" : "no")")
        print("CDP detail: \(report.cdpDetail)")
        print("Known limitations:")
        for limitation in report.limitations {
            print("- \(limitation)")
        }
    }

    private static func backends(arguments: [String]) async throws {
        let configuration = try CLIConfiguration(arguments: passthroughConfigurationArguments(arguments))
        let manager = BrowserManager(configSection: configuration.userConfig.browser)
        let statuses = await manager.availableBackends()
        for status in statuses {
            print("\(status.id.rawValue): \(status.available ? "available" : "unavailable") - \(status.detail)")
        }
    }

    private static func fetch(arguments: [String]) async throws {
        let options = try FetchOptions(arguments: arguments)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let manager = BrowserManager(configSection: configuration.userConfig.browser)
        let format: BrowserContentFormat = options.markdown ? .markdown : (options.text ? .text : (options.html ? .html : .markdown))
        let result = try await manager.fetch(
            url: options.url,
            format: format,
            backend: options.backend,
            timeoutSeconds: options.timeoutSeconds
        )

        if options.json {
            print(JSONValue.object([
                "url": .string(result.url),
                "title": result.title.map(JSONValue.string) ?? .null,
                "backend": .string(result.backend),
                "contentType": .string(result.contentType),
                "content": .string(result.content),
                "timing": .object([
                    "startupMs": .number(Double(result.timing.startupMs)),
                    "navigationMs": .number(Double(result.timing.navigationMs)),
                    "extractionMs": .number(Double(result.timing.extractionMs)),
                ]),
            ]).prettyPrinted)
        } else {
            print(result.content)
        }
    }

    private static func eval(arguments: [String]) async throws {
        let options = try EvalOptions(arguments: arguments)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let manager = BrowserManager(configSection: configuration.userConfig.browser)
        let (page, result) = try await manager.evaluate(
            url: options.url,
            expression: options.javascript,
            backend: options.backend,
            timeoutSeconds: options.timeoutSeconds
        )
        if options.json {
            print(JSONValue.object([
                "url": .string(page.url),
                "title": page.title.map(JSONValue.string) ?? .null,
                "backend": .string(page.backend),
                "value": result.value,
                "description": .string(result.description),
            ]).prettyPrinted)
        } else {
            print(result.description)
        }
    }

    private static func screenshot(arguments: [String]) async throws {
        let options = try ScreenshotOptions(arguments: arguments)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let manager = BrowserManager(configSection: configuration.userConfig.browser)
        let (_, data) = try await manager.screenshot(
            url: options.url,
            backend: options.backend,
            timeoutSeconds: options.timeoutSeconds
        )
        let outputURL = options.outputURL ?? defaultScreenshotURL(for: options.url)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outputURL, options: .atomic)
        print(outputURL.path)
    }

    private static func serve(arguments: [String]) async throws {
        let options = try ServeOptions(arguments: arguments)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let manager = BrowserManager(configSection: configuration.userConfig.browser)
        let (backend, session) = try await manager.startSession(backend: options.backend, timeoutSeconds: options.timeoutSeconds)
        print("Backend: \(backend.id.rawValue)")
        print("Endpoint: \(session.endpointURL.absoluteString)")
        print("Press Ctrl+C to stop.")
        while true {
            try await Task.sleep(for: .seconds(60))
        }
    }

    private static func benchmark(arguments: [String]) async throws {
        let options = try BenchmarkOptions(arguments: arguments)
        let configuration = try CLIConfiguration(arguments: options.configurationArguments)
        let manager = BrowserManager(configSection: configuration.userConfig.browser)
        let result = await manager.benchmark(url: options.url, backend: options.backend, timeoutSeconds: options.timeoutSeconds)
        if options.json {
            print(JSONValue.object([
                "backend": .string(result.backend),
                "executablePath": result.executablePath.map(JSONValue.string) ?? .null,
                "startupMs": .number(Double(result.startupMs)),
                "readyMs": .number(Double(result.readyMs)),
                "navigationMs": .number(Double(result.navigationMs)),
                "extractionMs": .number(Double(result.extractionMs)),
                "screenshotMs": .number(Double(result.screenshotMs)),
                "peakRSSBytes": result.peakRSSBytes.map { .number(Double($0)) } ?? .null,
                "success": .bool(result.success),
                "errorSummary": result.errorSummary.map(JSONValue.string) ?? .null,
            ]).prettyPrinted)
        } else {
            print("backend          \(result.backend)")
            print("executable       \(result.executablePath ?? "n/a")")
            print("startupMs        \(result.startupMs)")
            print("readyMs          \(result.readyMs)")
            print("navigationMs     \(result.navigationMs)")
            print("extractionMs     \(result.extractionMs)")
            print("screenshotMs     \(result.screenshotMs)")
            print("peakRSSBytes     \(result.peakRSSBytes.map(String.init) ?? "n/a")")
            print("success          \(result.success ? "yes" : "no")")
            if let errorSummary = result.errorSummary {
                print("error            \(errorSummary)")
            }
        }
    }

    private static func passthroughConfigurationArguments(_ arguments: [String]) -> [String] {
        var result = [arguments.first ?? "ashex"]
        var iterator = arguments.dropFirst().dropFirst().dropFirst().makeIterator()
        while let argument = iterator.next() {
            if ["--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode"].contains(argument),
               let value = iterator.next() {
                result.append(argument)
                result.append(value)
            }
        }
        return result
    }

    private static func defaultScreenshotURL(for url: URL) -> URL {
        let host = url.host ?? "page"
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("\(host)-\(timestamp).png")
    }

    static let helpText = """
    Usage:
      ashex browser doctor [options]
      ashex browser backends [options]
      ashex browser fetch <url> [--backend auto|obscura|chrome-cdp] [--markdown|--text|--html] [--json] [options]
      ashex browser eval <url> <javascript> [--backend auto|obscura|chrome-cdp] [--json] [options]
      ashex browser screenshot <url> [--output path] [--backend auto|obscura|chrome-cdp] [options]
      ashex browser serve [--backend obscura|chrome-cdp|auto] [options]
      ashex browser benchmark <url> [--backend auto|obscura|chrome-cdp] [--json] [options]

    Options:
      --workspace PATH
      --storage PATH
      --provider NAME
      --model NAME
      --approval-mode MODE
    """
}

private struct FetchOptions {
    let url: URL
    let backend: BrowserBackendID?
    let markdown: Bool
    let text: Bool
    let html: Bool
    let json: Bool
    let timeoutSeconds: Int?
    let configurationArguments: [String]

    init(arguments: [String]) throws {
        var url: URL?
        var backend: BrowserBackendID?
        var markdown = false
        var text = false
        var html = false
        var json = false
        var timeoutSeconds: Int?
        var configurationArguments = [arguments.first ?? "ashex"]
        var iterator = arguments.dropFirst().dropFirst().dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--backend":
                guard let value = iterator.next(), let parsed = BrowserBackendID(rawValue: value) else {
                    throw AshexError.model("Invalid value for --backend")
                }
                backend = parsed
            case "--markdown":
                markdown = true
            case "--text":
                text = true
            case "--html":
                html = true
            case "--json":
                json = true
            case "--timeout", "--timeout-seconds":
                guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                    throw AshexError.model("Invalid value for \(argument)")
                }
                timeoutSeconds = parsed
            case "--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for \(argument)") }
                configurationArguments.append(argument)
                configurationArguments.append(value)
            default:
                if url == nil, let parsed = BrowserURLNormalizer.normalize(argument) {
                    url = parsed
                } else {
                    throw AshexError.model("Unknown browser fetch argument '\(argument)'")
                }
            }
        }
        guard let url else { throw AshexError.model("browser fetch requires a URL") }
        self.url = url
        self.backend = backend
        self.markdown = markdown
        self.text = text
        self.html = html
        self.json = json
        self.timeoutSeconds = timeoutSeconds
        self.configurationArguments = configurationArguments
    }
}

private struct EvalOptions {
    let url: URL
    let javascript: String
    let backend: BrowserBackendID?
    let json: Bool
    let timeoutSeconds: Int?
    let configurationArguments: [String]

    init(arguments: [String]) throws {
        var remaining: [String] = []
        var backend: BrowserBackendID?
        var json = false
        var timeoutSeconds: Int?
        var configurationArguments = [arguments.first ?? "ashex"]
        var iterator = arguments.dropFirst().dropFirst().dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--backend":
                guard let value = iterator.next(), let parsed = BrowserBackendID(rawValue: value) else {
                    throw AshexError.model("Invalid value for --backend")
                }
                backend = parsed
            case "--json":
                json = true
            case "--timeout", "--timeout-seconds":
                guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                    throw AshexError.model("Invalid value for \(argument)")
                }
                timeoutSeconds = parsed
            case "--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for \(argument)") }
                configurationArguments.append(argument)
                configurationArguments.append(value)
            default:
                remaining.append(argument)
            }
        }
        guard remaining.count >= 2, let url = BrowserURLNormalizer.normalize(remaining[0]) else {
            throw AshexError.model("browser eval requires a URL and JavaScript expression")
        }
        self.url = url
        self.javascript = remaining.dropFirst().joined(separator: " ")
        self.backend = backend
        self.json = json
        self.timeoutSeconds = timeoutSeconds
        self.configurationArguments = configurationArguments
    }
}

private struct ScreenshotOptions {
    let url: URL
    let outputURL: URL?
    let backend: BrowserBackendID?
    let timeoutSeconds: Int?
    let configurationArguments: [String]

    init(arguments: [String]) throws {
        var url: URL?
        var outputURL: URL?
        var backend: BrowserBackendID?
        var timeoutSeconds: Int?
        var configurationArguments = [arguments.first ?? "ashex"]
        var iterator = arguments.dropFirst().dropFirst().dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--output":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for --output") }
                outputURL = URL(fileURLWithPath: value, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
            case "--backend":
                guard let value = iterator.next(), let parsed = BrowserBackendID(rawValue: value) else {
                    throw AshexError.model("Invalid value for --backend")
                }
                backend = parsed
            case "--timeout", "--timeout-seconds":
                guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                    throw AshexError.model("Invalid value for \(argument)")
                }
                timeoutSeconds = parsed
            case "--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for \(argument)") }
                configurationArguments.append(argument)
                configurationArguments.append(value)
            default:
                if url == nil, let parsed = BrowserURLNormalizer.normalize(argument) {
                    url = parsed
                } else {
                    throw AshexError.model("Unknown browser screenshot argument '\(argument)'")
                }
            }
        }
        guard let url else { throw AshexError.model("browser screenshot requires a URL") }
        self.url = url
        self.outputURL = outputURL
        self.backend = backend
        self.timeoutSeconds = timeoutSeconds
        self.configurationArguments = configurationArguments
    }
}

private struct ServeOptions {
    let backend: BrowserBackendID?
    let timeoutSeconds: Int?
    let configurationArguments: [String]

    init(arguments: [String]) throws {
        var backend: BrowserBackendID?
        var timeoutSeconds: Int?
        var configurationArguments = [arguments.first ?? "ashex"]
        var iterator = arguments.dropFirst().dropFirst().dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--backend":
                guard let value = iterator.next(), let parsed = BrowserBackendID(rawValue: value) else {
                    throw AshexError.model("Invalid value for --backend")
                }
                backend = parsed
            case "--timeout", "--timeout-seconds":
                guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                    throw AshexError.model("Invalid value for \(argument)")
                }
                timeoutSeconds = parsed
            case "--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for \(argument)") }
                configurationArguments.append(argument)
                configurationArguments.append(value)
            default:
                throw AshexError.model("Unknown browser serve argument '\(argument)'")
            }
        }
        self.backend = backend
        self.timeoutSeconds = timeoutSeconds
        self.configurationArguments = configurationArguments
    }
}

private struct BenchmarkOptions {
    let url: URL
    let backend: BrowserBackendID?
    let json: Bool
    let timeoutSeconds: Int?
    let configurationArguments: [String]

    init(arguments: [String]) throws {
        var url: URL?
        var backend: BrowserBackendID?
        var json = false
        var timeoutSeconds: Int?
        var configurationArguments = [arguments.first ?? "ashex"]
        var iterator = arguments.dropFirst().dropFirst().dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--backend":
                guard let value = iterator.next(), let parsed = BrowserBackendID(rawValue: value) else {
                    throw AshexError.model("Invalid value for --backend")
                }
                backend = parsed
            case "--json":
                json = true
            case "--timeout", "--timeout-seconds":
                guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                    throw AshexError.model("Invalid value for \(argument)")
                }
                timeoutSeconds = parsed
            case "--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode":
                guard let value = iterator.next() else { throw AshexError.model("Missing value for \(argument)") }
                configurationArguments.append(argument)
                configurationArguments.append(value)
            default:
                if url == nil, let parsed = BrowserURLNormalizer.normalize(argument) {
                    url = parsed
                } else {
                    throw AshexError.model("Unknown browser benchmark argument '\(argument)'")
                }
            }
        }
        guard let url else { throw AshexError.model("browser benchmark requires a URL") }
        self.url = url
        self.backend = backend
        self.json = json
        self.timeoutSeconds = timeoutSeconds
        self.configurationArguments = configurationArguments
    }
}
