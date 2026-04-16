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

    @Test func retriesWhenStructuredOutputContentIsEmpty() async throws {
        let session = makeOllamaStubbedSession(responses: [
            (
                200,
                """
                {
                  "message": {
                    "content": ""
                  }
                }
                """
            ),
            (
                200,
                """
                {
                  "message": {
                    "content": "{\\"type\\":\\"final_answer\\",\\"final_answer\\":\\"recovered\\",\\"tool_name\\":null,\\"arguments\\":null}"
                  }
                }
                """
            ),
        ])

        let adapter = OllamaChatModelAdapter(
            configuration: .init(model: "llama3.2", baseURL: URL(string: "http://localhost:11434/api/chat")!),
            session: session
        )

        let action = try await adapter.nextAction(for: sampleModelContext())
        #expect(action == .finalAnswer("recovered"))
        #expect(OllamaStubURLProtocol.state.requestCount == 2)
    }

    @Test func unwrapsFencedStructuredOutputBeforeDecoding() async throws {
        let session = makeOllamaStubbedSession(statusCode: 200, body: """
        {
          "message": {
            "content": "```json\\n{\\"type\\":\\"final_answer\\",\\"final_answer\\":\\"wrapped\\",\\"tool_name\\":null,\\"arguments\\":null}\\n```"
          }
        }
        """)

        let adapter = OllamaChatModelAdapter(
            configuration: .init(model: "llama3.2", baseURL: URL(string: "http://localhost:11434/api/chat")!),
            session: session
        )

        let action = try await adapter.nextAction(for: sampleModelContext())
        #expect(action == .finalAnswer("wrapped"))
    }

    @Test func appliesConfiguredRequestTimeoutToOllamaRequests() async throws {
        let session = makeOllamaStubbedSession(statusCode: 200, body: """
        {
          "message": {
            "content": "{\\"type\\":\\"final_answer\\",\\"final_answer\\":\\"done locally\\",\\"tool_name\\":null,\\"arguments\\":null}"
          }
        }
        """)

        let adapter = OllamaChatModelAdapter(
            configuration: .init(
                model: "llama3.2",
                baseURL: URL(string: "http://localhost:11434/api/chat")!,
                requestTimeoutSeconds: 321
            ),
            session: session
        )

        _ = try await adapter.nextAction(for: sampleModelContext())
        #expect(abs(OllamaStubURLProtocol.state.lastRequestTimeout - 321) < 0.001)
    }

    @Test func parsesStructuredTaskPlanOutput() async throws {
        let session = makeOllamaStubbedSession(statusCode: 200, body: """
        {
          "message": {
            "content": "{\\"steps\\":[{\\"title\\":\\"Inspect the current implementation\\",\\"phase\\":\\"exploration\\"},{\\"title\\":\\"Implement the requested controls\\",\\"phase\\":\\"mutation\\"},{\\"title\\":\\"Validate the updated behavior\\",\\"phase\\":\\"validation\\"}]}"
          }
        }
        """)

        let adapter = OllamaChatModelAdapter(
            configuration: .init(model: "llama3.2", baseURL: URL(string: "http://localhost:11434/api/chat")!),
            session: session
        )

        let plan = try await adapter.taskPlan(for: "Add Telegram stop and chunk controls", taskKind: .feature)

        #expect(plan?.steps.count == 3)
        #expect(plan?.steps[1].title == "Implement the requested controls")
        #expect(plan?.steps[2].phase == .validation)
    }

    @Test func directReplyFallsBackToPlainTextContent() async throws {
        let session = makeOllamaStubbedSession(statusCode: 200, body: """
        {
          "message": {
            "content": "I'm doing well, thanks for asking."
          }
        }
        """)

        let adapter = OllamaChatModelAdapter(
            configuration: .init(model: "llama3.2", baseURL: URL(string: "http://localhost:11434/api/chat")!),
            session: session
        )

        let reply = try await adapter.directReply(
            history: [
                .init(id: UUID(), threadID: UUID(), runID: UUID(), role: .user, content: "How are you?", createdAt: Date())
            ],
            systemPrompt: "You are helpful."
        )

        #expect(reply == "I'm doing well, thanks for asking.")
    }

    @Test func directReplyRetriesWhenStructuredReplyIsEmpty() async throws {
        let session = makeOllamaStubbedSession(responses: [
            (
                200,
                """
                {
                  "message": {
                    "content": "{\\"reply\\":\\"\\"}"
                  }
                }
                """
            ),
            (
                200,
                """
                {
                  "message": {
                    "content": "{\\"reply\\":\\"It looks like an ASO skills repository for app-store optimization workflows.\\"}"
                  }
                }
                """
            ),
        ])

        let adapter = OllamaChatModelAdapter(
            configuration: .init(model: "llama3.2", baseURL: URL(string: "http://localhost:11434/api/chat")!),
            session: session
        )

        let reply = try await adapter.directReply(
            history: [
                .init(id: UUID(), threadID: UUID(), runID: UUID(), role: .user, content: "What this repo is about: https://github.com/Eronred/aso-skills", createdAt: Date())
            ],
            systemPrompt: "You are helpful."
        )

        #expect(reply == "It looks like an ASO skills repository for app-store optimization workflows.")
        #expect(OllamaStubURLProtocol.state.requestCount == 2)
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
    OllamaStubURLProtocol.state.setResponses([(statusCode, body)])
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OllamaStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private func makeOllamaStubbedSession(responses: [(Int, String)]) -> URLSession {
    OllamaStubURLProtocol.state.setResponses(responses)
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
        Self.state.record(timeoutInterval: request.timeoutInterval)
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
    private var responses: [(statusCode: Int, body: String)] = [(200, "")]
    private(set) var requestCount = 0
    private(set) var lastRequestTimeout: TimeInterval = 0

    func setResponses(_ responses: [(Int, String)]) {
        lock.lock()
        self.responses = responses.map { (statusCode: $0.0, body: $0.1) }
        self.requestCount = 0
        self.lastRequestTimeout = 0
        lock.unlock()
    }

    func snapshot() -> (statusCode: Int, body: String) {
        lock.lock()
        defer { lock.unlock() }
        let index = min(requestCount, max(responses.count - 1, 0))
        let response = responses[index]
        requestCount += 1
        return response
    }

    func record(timeoutInterval: TimeInterval) {
        lock.lock()
        lastRequestTimeout = timeoutInterval
        lock.unlock()
    }
}
