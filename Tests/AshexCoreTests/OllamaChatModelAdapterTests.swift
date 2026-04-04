import AshexCore
import Foundation
import Testing

@Suite(.serialized)
struct OllamaChatModelAdapterTests {
    @Test func parsesFinalAnswerStructuredOutput() async throws {
        let session = makeOllamaStubbedSession(statusCode: 200, body: """
        {
          "message": {
            "content": "{\\"type\\":\\"final_answer\\",\\"final_answer\\":\\"done locally\\",\\"tool_name\\":null,\\"arguments\\":null}"
          }
        }
        """)

        let adapter = OllamaChatModelAdapter(
            configuration: .init(model: "llama3.2", baseURL: URL(string: "http://localhost:11434/api/chat")!),
            session: session
        )

        let action = try await adapter.nextAction(for: sampleModelContext())
        #expect(action == .finalAnswer("done locally"))
    }

    @Test func parsesToolCallStructuredOutput() async throws {
        let session = makeOllamaStubbedSession(statusCode: 200, body: """
        {
          "message": {
            "content": "{\\"type\\":\\"tool_call\\",\\"final_answer\\":null,\\"tool_name\\":\\"filesystem\\",\\"arguments\\":{\\"action\\":\\"list\\"}}"
          }
        }
        """)

        let adapter = OllamaChatModelAdapter(
            configuration: .init(model: "llama3.2", baseURL: URL(string: "http://localhost:11434/api/chat")!),
            session: session
        )

        let action = try await adapter.nextAction(for: sampleModelContext())
        let expected = ModelAction.toolCall(.init(toolName: "filesystem", arguments: [
            "operation": .string("list_directory"),
            "path": .string("."),
        ]))
        #expect(action == expected)
    }
}

private func sampleModelContext() -> ModelContext {
    let thread = ThreadRecord(id: UUID(), createdAt: Date())
    let run = RunRecord(id: UUID(), threadID: thread.id, state: .running, createdAt: Date(), updatedAt: Date())
    return ModelContext(
        thread: thread,
        run: run,
        messages: [
            .init(id: UUID(), threadID: thread.id, runID: run.id, role: .user, content: "list files", createdAt: Date()),
        ],
        availableTools: [
            .init(name: "filesystem", description: "Read/write text files and list or create directories within the workspace"),
            .init(name: "shell", description: "Execute shell commands inside the workspace with streaming stdout/stderr"),
        ]
    )
}

private func makeOllamaStubbedSession(statusCode: Int, body: String) -> URLSession {
    OllamaStubURLProtocol.state.set(statusCode: statusCode, body: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OllamaStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class OllamaStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = OllamaStubResponseState()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let current = Self.state.snapshot()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "http://localhost:11434/api/chat")!,
            statusCode: current.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(current.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OllamaStubResponseState: @unchecked Sendable {
    private let lock = NSLock()
    private var statusCode = 200
    private var body = ""

    func set(statusCode: Int, body: String) {
        lock.lock()
        self.statusCode = statusCode
        self.body = body
        lock.unlock()
    }

    func snapshot() -> (statusCode: Int, body: String) {
        lock.lock()
        defer { lock.unlock() }
        return (statusCode, body)
    }
}
