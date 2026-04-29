import AshexCore
import Foundation
import Testing

@Test func runtimeToolFactoryRegistersBrowserTools() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let dbURL = root.appendingPathComponent(".ashex/browser-tools.sqlite")
    try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let store = SQLitePersistenceStore(databaseURL: dbURL)
    try store.initialize()

    let tools = try RuntimeToolFactory.makeTools(
        workspaceURL: root,
        persistence: store,
        userConfig: .default,
        sandbox: .default,
        shellExecutionPolicy: ShellExecutionPolicy(
            sandbox: .default,
            network: .default,
            shell: ShellCommandPolicy(config: .default)
        )
    )
    let names = Set(tools.map(\.name))

    #expect(names.contains("browser_fetch"))
    #expect(names.contains("browser_extract"))
    #expect(names.contains("browser_eval"))
    #expect(names.contains("browser_screenshot"))

    let schemaNames = Set(ToolRegistry(tools: tools).schema().map(\.name))
    #expect(schemaNames.contains("browser_fetch"))
    #expect(schemaNames.contains("browser_extract"))
    #expect(schemaNames.contains("browser_eval"))
    #expect(schemaNames.contains("browser_screenshot"))
}

@Test func runtimeExecutesInjectedBrowserManagerThroughBrowserFetchTool() async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let dbURL = root.appendingPathComponent(".ashex/test.sqlite")
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

    let browser = RecordingBrowserManager()
    let runtime = try AgentRuntime(
        modelAdapter: SequencedBrowserModelAdapter(actions: [
            .toolCall(.init(toolName: "browser_fetch", arguments: [
                "url": .string("https://example.com"),
                "format": .string("markdown"),
            ])),
            .finalAnswer("Fetched Example Domain."),
        ]),
        toolRegistry: ToolRegistry(tools: [
            BrowserFetchTool(manager: browser),
        ]),
        persistence: SQLitePersistenceStore(databaseURL: dbURL),
        workspaceSnapshot: WorkspaceSnapshotBuilder.capture(workspaceRoot: root)
    )

    var finalAnswer = ""
    var sawBrowserToolFinish = false
    for await event in runtime.run(RunRequest(prompt: "Browse https://example.com and summarize it")) {
        switch event.payload {
        case .toolCallFinished(_, _, let success, let summary):
            sawBrowserToolFinish = success && summary.contains("Example Domain")
        case .finalAnswer(_, _, let text):
            finalAnswer = text
        default:
            break
        }
    }

    #expect(await browser.fetchedURLs().contains("https://example.com"))
    #expect(sawBrowserToolFinish)
    #expect(finalAnswer == "Fetched Example Domain.")
}

@Test func browserFetchToolAcceptsSchemelessURL() async throws {
    let browser = RecordingBrowserManager()
    let tool = BrowserFetchTool(manager: browser)

    _ = try await tool.execute(arguments: [
        "url": .string("example.com"),
    ], context: ToolContext(runID: UUID(), emit: { _ in }, cancellation: CancellationToken()))

    #expect(await browser.fetchedURLs() == ["https://example.com"])
}

@Test func browserFetchToolAcceptsBareDomainURL() async throws {
    let browser = RecordingBrowserManager()
    let tool = BrowserFetchTool(manager: browser)

    _ = try await tool.execute(arguments: [
        "url": .string("filsv.com"),
    ], context: ToolContext(runID: UUID(), emit: { _ in }, cancellation: CancellationToken()))

    _ = try await tool.execute(arguments: [
        "url": .string("www.filsv.com"),
    ], context: ToolContext(runID: UUID(), emit: { _ in }, cancellation: CancellationToken()))

    #expect(await browser.fetchedURLs() == ["https://filsv.com", "https://www.filsv.com"])
}

private actor RecordingBrowserManager: BrowserManaging {
    private var urls: [String] = []

    func fetch(url: URL, format: BrowserContentFormat, backend: BrowserBackendID?, timeoutSeconds: Int?) async throws -> BrowserFetchResult {
        urls.append(url.absoluteString)
        return BrowserFetchResult(
            url: url.absoluteString,
            title: "Example Domain",
            backend: backend?.rawValue ?? BrowserBackendID.chromeCDP.rawValue,
            contentType: format.rawValue,
            content: "# Example Domain\n\nThis domain is for use in illustrative examples.",
            timing: BrowserFetchTiming(startupMs: 0, navigationMs: 0, extractionMs: 0)
        )
    }

    func evaluate(url: URL, expression: String, backend: BrowserBackendID?, timeoutSeconds: Int?) async throws -> (BrowserPageResult, BrowserEvaluateResult) {
        throw AshexError.model("Unexpected browser eval in fetch test")
    }

    func screenshot(url: URL, backend: BrowserBackendID?, timeoutSeconds: Int?) async throws -> (BrowserPageResult, Data) {
        throw AshexError.model("Unexpected browser screenshot in fetch test")
    }

    func fetchedURLs() -> [String] {
        urls
    }
}

private actor SequencedBrowserModelAdapter: ModelAdapter {
    let name = "sequenced-browser-test"
    let providerID = "test"
    let modelID = "sequenced-browser-test"
    private var actions: [ModelAction]

    init(actions: [ModelAction]) {
        self.actions = actions
    }

    func nextAction(for context: ModelContext) async throws -> ModelAction {
        guard !actions.isEmpty else {
            throw AshexError.model("No more browser test actions")
        }
        return actions.removeFirst()
    }
}

@Test func browserExtractToolAdvertisesExtractContract() {
    let tool = BrowserExtractTool(manager: BrowserManager(configSection: .default))

    #expect(tool.name == "browser_extract")
    #expect(tool.contract.name == "browser_extract")
    #expect(tool.contract.defaultOperationName == "extract")
}
