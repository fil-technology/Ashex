import Foundation

public struct ChromeCdpBrowserBackend: BrowserBackend {
    public let id: BrowserBackendID = .chromeCDP

    public init() {}

    public func isAvailable(config: BrowserConfig) async -> BrowserBackendAvailability {
        let endpointStatus = await endpointAvailability(config: config)
        if endpointStatus.available {
            return endpointStatus
        }
        if let executable = BrowserExecutableDiscovery.resolveChromeExecutable(
            configuredPath: config.executablePath,
            environment: mergedEnvironment(config)
        ) {
            return .init(
                id: id,
                available: true,
                detail: "CDP endpoint unavailable, but managed Chrome launch is available at \(executable)"
            )
        }
        return .init(
            id: id,
            available: false,
            detail: "\(endpointStatus.detail). No Chrome/Chromium executable was found for managed launch."
        )
    }

    public func endpointAvailability(config: BrowserConfig) async -> BrowserBackendAvailability {
        let endpoint = endpointURL(for: config)
        do {
            _ = try await BrowserProcessSupport.waitForReadyEndpoint(baseURL: endpoint, timeoutSeconds: 1)
            return .init(id: id, available: true, detail: "CDP endpoint reachable at \(endpoint.absoluteString)")
        } catch {
            return .init(id: id, available: false, detail: "CDP endpoint unavailable at \(endpoint.absoluteString)")
        }
    }

    public func start(config: BrowserConfig) async throws -> BrowserSession {
        let startupStartedAt = Date()
        let requestedEndpoint = endpointURL(for: config)
        if let endpoint = try? await BrowserProcessSupport.waitForReadyEndpoint(
            baseURL: requestedEndpoint,
            timeoutSeconds: 1
        ) {
            return try await connectExternalSession(config: config, endpoint: endpoint, startupStartedAt: startupStartedAt)
        }

        let launched = try await launchManagedChrome(config: config, requestedEndpoint: requestedEndpoint, startupStartedAt: startupStartedAt)
        return launched
    }

    private func connectExternalSession(
        config: BrowserConfig,
        endpoint: URL,
        startupStartedAt: Date
    ) async throws -> BrowserSession {
        let client = CDPClient(baseURL: endpoint)
        try await client.connect(initialURL: URL(string: "about:blank"))
        return BrowserSession(
            backendID: id.rawValue,
            state: BrowserSessionState(
                config: config,
                endpointURL: endpoint,
                client: client,
                process: nil,
                executablePath: config.executablePath,
                startupStartedAt: startupStartedAt,
                readyAt: Date()
            )
        )
    }

    private func launchManagedChrome(
        config: BrowserConfig,
        requestedEndpoint: URL,
        startupStartedAt: Date
    ) async throws -> BrowserSession {
        guard let executable = BrowserExecutableDiscovery.resolveChromeExecutable(
            configuredPath: config.executablePath,
            environment: mergedEnvironment(config)
        ) else {
            throw BrowserBackendError.unavailable("Chrome CDP backend selected but no CDP endpoint was reachable at \(requestedEndpoint.absoluteString), and no Chrome/Chromium executable was found. Start Chrome with remote debugging, configure browser.cdp.endpoint, or install Chrome/Chromium.")
        }

        let host = safeDebugHost(from: requestedEndpoint)
        let port: Int
        if let requestedPort = requestedEndpoint.port {
            port = requestedPort
        } else {
            port = try BrowserProcessSupport.chooseFreePort(host: host)
        }
        let endpoint = URL(string: "http://\(host):\(port)")!
        let userDataDirectory = try makeUserDataDirectory(config: config)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = launchArguments(config: config, host: host, port: port, userDataDirectory: userDataDirectory.url)
        process.environment = mergedEnvironment(config)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let managed = BrowserManagedProcess(process: process, stdoutPipe: stdout, stderrPipe: stderr)

        do {
            _ = try await BrowserProcessSupport.waitForReadyEndpoint(
                baseURL: endpoint,
                timeoutSeconds: config.startupTimeoutSeconds
            )
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
                    temporaryUserDataDirectory: userDataDirectory.removeOnStop ? userDataDirectory.url : nil,
                    startupStartedAt: startupStartedAt,
                    readyAt: Date()
                )
            )
        } catch {
            managed.terminateIfRunning()
            if userDataDirectory.removeOnStop {
                try? FileManager.default.removeItem(at: userDataDirectory.url)
            }
            let stderrTail = managed.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            if stderrTail.isEmpty {
                throw error
            }
            throw BrowserBackendError.startupFailed("Managed Chrome failed to start: \(stderrTail)")
        }
    }

    public func stop(session: BrowserSession) async throws {
        await session.state.client.close()
        session.state.process?.terminateIfRunning()
        if let directory = session.state.temporaryUserDataDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    public func navigate(session: BrowserSession, url: URL, options: BrowserNavigateOptions) async throws -> BrowserPageResult {
        let started = Date()
        try await session.state.client.navigate(url: url, timeoutSeconds: options.timeoutSeconds)
        let title = try await session.state.client.title()
        return BrowserPageResult(
            url: url.absoluteString,
            title: title,
            loadTimeMs: Int(Date().timeIntervalSince(started) * 1000),
            backend: session.backendID
        )
    }

    public func evaluate(session: BrowserSession, expression: String) async throws -> BrowserEvaluateResult {
        try await session.state.client.evaluate(expression: expression)
    }

    public func screenshot(session: BrowserSession, options: BrowserScreenshotOptions) async throws -> Data {
        try await session.state.client.screenshot(options: options)
    }

    public func extractText(session: BrowserSession) async throws -> String {
        let evaluated = try await session.state.client.evaluate(expression: "document.body ? document.body.innerText : ''")
        return evaluated.value.stringValue ?? evaluated.description
    }

    public func extractMarkdown(session: BrowserSession) async throws -> String {
        if let custom = try? await session.state.client.evaluate(expression: "globalThis.LP && typeof LP.getMarkdown === 'function' ? LP.getMarkdown() : null"),
           let markdown = custom.value.stringValue,
           !markdown.isEmpty,
           markdown != "null" {
            return markdown
        }

        let fallbackScript = """
        (() => {
          const body = document.body;
          if (!body) { return ""; }
          const blocks = Array.from(body.querySelectorAll("h1,h2,h3,h4,h5,h6,p,li,pre,code,blockquote"));
          if (blocks.length === 0) { return body.innerText || ""; }
          return blocks.map(node => {
            const text = (node.innerText || "").trim();
            if (!text) { return ""; }
            if (/^H[1-6]$/.test(node.tagName)) {
              return "#".repeat(Number(node.tagName.slice(1))) + " " + text;
            }
            if (node.tagName === "LI") { return "- " + text; }
            if (node.tagName === "PRE" || node.tagName === "CODE") { return "```\\n" + text + "\\n```"; }
            if (node.tagName === "BLOCKQUOTE") { return "> " + text; }
            return text;
          }).filter(Boolean).join("\\n\\n");
        })()
        """
        let evaluated = try await session.state.client.evaluate(expression: fallbackScript)
        if let markdown = evaluated.value.stringValue {
            return markdown
        }
        return try await extractText(session: session)
    }

    public func extractHTML(session: BrowserSession) async throws -> String {
        try await session.state.client.outerHTML()
    }

    private func endpointURL(for config: BrowserConfig) -> URL {
        if let endpoint = config.cdpEndpoint, let url = URL(string: endpoint) {
            return url
        }
        return URL(string: "http://\(config.host):\(config.port == 0 ? 9222 : config.port)")!
    }

    private func safeDebugHost(from endpoint: URL) -> String {
        let host = endpoint.host ?? "127.0.0.1"
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return "127.0.0.1"
        }
        return "127.0.0.1"
    }

    private func makeUserDataDirectory(config: BrowserConfig) throws -> (url: URL, removeOnStop: Bool) {
        if let userDataDir = config.userDataDir, !userDataDir.isEmpty {
            let url = URL(fileURLWithPath: userDataDir)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return (url, false)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ashex-chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (url, true)
    }

    private func launchArguments(config: BrowserConfig, host: String, port: Int, userDataDirectory: URL) -> [String] {
        var arguments = [
            "--remote-debugging-address=\(host)",
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(userDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
        ]
        if config.headless {
            arguments.append("--headless=new")
            arguments.append("--disable-gpu")
        }
        arguments.append(contentsOf: config.extraArgs)
        arguments.append("about:blank")
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
