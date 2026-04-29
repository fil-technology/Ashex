import Foundation

public protocol BrowserManaging: Sendable {
    func fetch(url: URL, format: BrowserContentFormat, backend: BrowserBackendID?, timeoutSeconds: Int?) async throws -> BrowserFetchResult
    func evaluate(url: URL, expression: String, backend: BrowserBackendID?, timeoutSeconds: Int?) async throws -> (BrowserPageResult, BrowserEvaluateResult)
    func screenshot(url: URL, backend: BrowserBackendID?, timeoutSeconds: Int?) async throws -> (BrowserPageResult, Data)
}

extension BrowserManager: BrowserManaging {}

public struct BrowserFetchTool: Tool {
    public let name = "browser_fetch"
    public let description = "Render a web page, wait for JavaScript, and extract readable markdown, text, or HTML for local browser automation and research."
    public let contract = ToolContract(
        name: "browser_fetch",
        description: "Render a page and extract readable content. Use only on URLs the user is allowed to access.",
        category: "browser",
        operationArgumentKey: nil,
        defaultOperationName: "fetch",
        operations: [
            .init(
                name: "fetch",
                description: "Navigate to a page and extract markdown, text, or HTML.",
                mutatesWorkspace: false,
                requiresNetwork: true,
                progressSummary: "fetched rendered browser content",
                arguments: [
                    .init(name: "url", description: "URL to fetch", type: .string, required: true),
                    .init(name: "backend", description: "Browser backend selection", type: .string, required: false, enumValues: BrowserBackendID.allCases.map(\.rawValue)),
                    .init(name: "format", description: "Desired content format", type: .string, required: false, enumValues: ["markdown", "text", "html"]),
                    .init(name: "timeout_seconds", description: "Navigation timeout in seconds", type: .number, required: false),
                ]
            )
        ],
        tags: ["browser", "web", "research"]
    )

    private let manager: any BrowserManaging

    public init(manager: any BrowserManaging) {
        self.manager = manager
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        let url = try requiredURL(arguments: arguments)
        let backend = BrowserBackendID(rawValue: arguments["backend"]?.stringValue ?? "")
        let format = BrowserContentFormat(rawValue: arguments["format"]?.stringValue ?? "markdown") ?? .markdown
        let timeoutSeconds = arguments["timeout_seconds"]?.intValue
        let result = try await manager.fetch(url: url, format: format, backend: backend, timeoutSeconds: timeoutSeconds)

        return .structured(.object([
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
        ]))
    }
}

public struct BrowserExtractTool: Tool {
    public let name = "browser_extract"
    public let description = "Extract rendered page content from a browser backend after JavaScript execution."
    public let contract = ToolContract(
        name: "browser_extract",
        description: "Extract readable content from a rendered page after JavaScript execution.",
        category: "browser",
        operationArgumentKey: nil,
        defaultOperationName: "extract",
        operations: [
            .init(
                name: "extract",
                description: "Navigate to a page and extract markdown, text, or HTML.",
                mutatesWorkspace: false,
                requiresNetwork: true,
                progressSummary: "extracted rendered browser content",
                arguments: [
                    .init(name: "url", description: "URL to extract", type: .string, required: true),
                    .init(name: "backend", description: "Browser backend selection", type: .string, required: false, enumValues: BrowserBackendID.allCases.map(\.rawValue)),
                    .init(name: "format", description: "Desired content format", type: .string, required: false, enumValues: ["markdown", "text", "html"]),
                    .init(name: "timeout_seconds", description: "Navigation timeout in seconds", type: .number, required: false),
                ]
            )
        ],
        tags: ["browser", "web", "research"]
    )

    private let fetchTool: BrowserFetchTool

    public init(manager: any BrowserManaging) {
        self.fetchTool = BrowserFetchTool(manager: manager)
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        try await fetchTool.execute(arguments: arguments, context: context)
    }
}

public struct BrowserEvalTool: Tool {
    public let name = "browser_eval"
    public let description = "Navigate to a page and evaluate JavaScript in the rendered DOM for debugging and inspection."
    public let contract = ToolContract(
        name: "browser_eval",
        description: "Evaluate JavaScript on a rendered page. Do not use this for credential theft, bypassing access controls, or abusive scraping.",
        category: "browser",
        operationArgumentKey: nil,
        defaultOperationName: "eval",
        operations: [
            .init(
                name: "eval",
                description: "Navigate to a page and evaluate JavaScript.",
                mutatesWorkspace: false,
                requiresNetwork: true,
                progressSummary: "evaluated JavaScript in browser",
                arguments: [
                    .init(name: "url", description: "URL to open", type: .string, required: true),
                    .init(name: "javascript", description: "JavaScript expression to evaluate", type: .string, required: true),
                    .init(name: "backend", description: "Browser backend selection", type: .string, required: false, enumValues: BrowserBackendID.allCases.map(\.rawValue)),
                    .init(name: "timeout_seconds", description: "Navigation timeout in seconds", type: .number, required: false),
                ]
            )
        ],
        tags: ["browser", "dom", "debugging"]
    )

    private let manager: any BrowserManaging

    public init(manager: any BrowserManaging) {
        self.manager = manager
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        let url = try requiredURL(arguments: arguments)
        guard let script = arguments["javascript"]?.stringValue, !script.isEmpty else {
            throw AshexError.invalidToolArguments("browser_eval.javascript must be a non-empty string")
        }
        let backend = BrowserBackendID(rawValue: arguments["backend"]?.stringValue ?? "")
        let timeoutSeconds = arguments["timeout_seconds"]?.intValue
        let (page, result) = try await manager.evaluate(url: url, expression: script, backend: backend, timeoutSeconds: timeoutSeconds)
        return .structured(.object([
            "url": .string(page.url),
            "title": page.title.map(JSONValue.string) ?? .null,
            "backend": .string(page.backend),
            "value": result.value,
            "description": .string(result.description),
        ]))
    }
}

public struct BrowserScreenshotTool: Tool {
    public let name = "browser_screenshot"
    public let description = "Render a page and capture a screenshot for debugging, testing, and visual inspection."
    public let contract = ToolContract(
        name: "browser_screenshot",
        description: "Capture a PNG screenshot of a rendered page.",
        category: "browser",
        operationArgumentKey: nil,
        defaultOperationName: "screenshot",
        operations: [
            .init(
                name: "screenshot",
                description: "Navigate to a page and capture a screenshot.",
                mutatesWorkspace: false,
                requiresNetwork: true,
                progressSummary: "captured browser screenshot",
                arguments: [
                    .init(name: "url", description: "URL to open", type: .string, required: true),
                    .init(name: "backend", description: "Browser backend selection", type: .string, required: false, enumValues: BrowserBackendID.allCases.map(\.rawValue)),
                    .init(name: "timeout_seconds", description: "Navigation timeout in seconds", type: .number, required: false),
                ]
            )
        ],
        tags: ["browser", "screenshot", "debugging"]
    )

    private let manager: any BrowserManaging

    public init(manager: any BrowserManaging) {
        self.manager = manager
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        let url = try requiredURL(arguments: arguments)
        let backend = BrowserBackendID(rawValue: arguments["backend"]?.stringValue ?? "")
        let timeoutSeconds = arguments["timeout_seconds"]?.intValue
        let (page, data) = try await manager.screenshot(url: url, backend: backend, timeoutSeconds: timeoutSeconds)
        return .structured(.object([
            "url": .string(page.url),
            "title": page.title.map(JSONValue.string) ?? .null,
            "backend": .string(page.backend),
            "contentType": .string("image/png"),
            "dataBase64": .string(data.base64EncodedString()),
        ]))
    }
}

private func requiredURL(arguments: JSONObject) throws -> URL {
    guard let rawURL = arguments["url"]?.stringValue,
          let url = BrowserURLNormalizer.normalize(rawURL),
          url.scheme != nil else {
        throw AshexError.invalidToolArguments("browser.url must be a valid URL")
    }
    return url
}
