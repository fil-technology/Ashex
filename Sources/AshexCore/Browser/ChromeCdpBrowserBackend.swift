import Foundation

public struct ChromeCdpBrowserBackend: BrowserBackend {
    public let id: BrowserBackendID = .chromeCDP

    public init() {}

    public func isAvailable(config: BrowserConfig) async -> BrowserBackendAvailability {
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
        let endpoint = try await BrowserProcessSupport.waitForReadyEndpoint(
            baseURL: endpointURL(for: config),
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
                process: nil,
                executablePath: config.executablePath,
                startupStartedAt: startupStartedAt,
                readyAt: Date()
            )
        )
    }

    public func stop(session: BrowserSession) async throws {
        await session.state.client.close()
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
}
