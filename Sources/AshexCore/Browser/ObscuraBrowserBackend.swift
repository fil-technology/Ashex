import Foundation

public struct ObscuraBrowserBackend: BrowserBackend {
    public let id: BrowserBackendID = .obscura

    public init() {}

    public func isAvailable(config: BrowserConfig) async -> BrowserBackendAvailability {
        guard let executable = BrowserExecutableDiscovery.resolveExecutable(
            configuredPath: config.executablePath,
            defaultName: "obscura",
            environment: config.environment
        ) else {
            return .init(id: id, available: false, detail: "Obscura binary not found in config or PATH.")
        }

        let flags = await BrowserProcessSupport.availableFlags(executablePath: executable, environment: mergedEnvironment(config))
        let detail = flags.isEmpty ? "Obscura found at \(executable), but help probing returned no flags." : "Obscura found at \(executable)"
        return .init(id: id, available: true, detail: detail)
    }

    public func start(config: BrowserConfig) async throws -> BrowserSession {
        guard let executable = BrowserExecutableDiscovery.resolveExecutable(
            configuredPath: config.executablePath,
            defaultName: "obscura",
            environment: mergedEnvironment(config)
        ) else {
            throw BrowserBackendError.unavailable("Obscura was requested, but no `obscura` executable was found. Set browser.obscura.path or add it to PATH.")
        }

        let startupStartedAt = Date()
        let flags = await BrowserProcessSupport.availableFlags(executablePath: executable, environment: mergedEnvironment(config))
        let port = config.port > 0 ? config.port : (try BrowserProcessSupport.chooseFreePort(host: config.host))
        let endpoint = URL(string: "http://\(config.host):\(port)")!

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = buildServeArguments(config: config, port: port, availableFlags: flags)
        process.environment = mergedEnvironment(config)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let managed = BrowserManagedProcess(process: process, stdoutPipe: stdout, stderrPipe: stderr)

        do {
            _ = try await BrowserProcessSupport.waitForReadyEndpoint(baseURL: endpoint, timeoutSeconds: config.startupTimeoutSeconds)
            let client = CDPClient(baseURL: endpoint)
            try await client.connect(initialURL: URL(string: "about:blank"))
            return BrowserSession(
                backendID: id.rawValue,
                state: BrowserSessionState(
                    config: config,
                    endpointURL: endpoint,
                    client: client,
                    process: managed,
                    executablePath: executable,
                    startupStartedAt: startupStartedAt,
                    readyAt: Date()
                )
            )
        } catch {
            managed.terminateIfRunning()
            let stderrTail = managed.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderrTail.isEmpty {
                throw error
            }
            throw BrowserBackendError.startupFailed("Obscura failed to start: \(stderrTail)")
        }
    }

    public func stop(session: BrowserSession) async throws {
        await session.state.client.close()
        session.state.process?.terminateIfRunning()
    }

    public func navigate(session: BrowserSession, url: URL, options: BrowserNavigateOptions) async throws -> BrowserPageResult {
        try await ChromeCdpBrowserBackend().navigate(session: session, url: url, options: options)
    }

    public func evaluate(session: BrowserSession, expression: String) async throws -> BrowserEvaluateResult {
        try await ChromeCdpBrowserBackend().evaluate(session: session, expression: expression)
    }

    public func screenshot(session: BrowserSession, options: BrowserScreenshotOptions) async throws -> Data {
        try await ChromeCdpBrowserBackend().screenshot(session: session, options: options)
    }

    public func extractText(session: BrowserSession) async throws -> String {
        try await ChromeCdpBrowserBackend().extractText(session: session)
    }

    public func extractMarkdown(session: BrowserSession) async throws -> String {
        try await ChromeCdpBrowserBackend().extractMarkdown(session: session)
    }

    public func extractHTML(session: BrowserSession) async throws -> String {
        try await ChromeCdpBrowserBackend().extractHTML(session: session)
    }

    private func buildServeArguments(config: BrowserConfig, port: Int, availableFlags: Set<String>) -> [String] {
        var arguments = ["serve", "--host", config.host, "--port", String(port)]
        if config.headless, availableFlags.contains("--headless") {
            arguments.append("--headless")
        }
        if config.stealthEnabled, availableFlags.contains("--stealth") {
            arguments.append("--stealth")
        }
        if config.blockTrackers, availableFlags.contains("--block-trackers") {
            arguments.append("--block-trackers")
        }
        arguments.append(contentsOf: config.extraArgs)
        return arguments
    }

    private func mergedEnvironment(_ config: BrowserConfig) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in config.environment {
            environment[key] = value
        }
        return environment
    }
}
