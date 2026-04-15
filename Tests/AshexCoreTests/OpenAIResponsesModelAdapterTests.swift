import AshexCore
import Foundation
import Testing

@Suite(.serialized)
struct OpenAIResponsesModelAdapterTests {
    @Test func parsesFinalAnswerStructuredOutput() async throws {
        let session = makeStubbedSession(statusCode: 200, body: """
        {
          "output": [
            {
              "content": [
                {
                  "type": "output_text",
                  "text": "{\\"type\\":\\"final_answer\\",\\"final_answer\\":\\"done\\",\\"tool_name\\":null,\\"arguments\\":null}"
                }
              ]
            }
          ]
        }
        """)

        let adapter = OpenAIResponsesModelAdapter(
            configuration: .init(apiKey: "test-key", model: "gpt-5.4-mini", baseURL: URL(string: "https://example.com/v1/responses")!),
            session: session
        )

        let action = try await adapter.nextAction(for: sampleContext())
        #expect(action == .finalAnswer("done"))
    }

    @Test func parsesToolCallStructuredOutput() async throws {
        let session = makeStubbedSession(statusCode: 200, body: """
        {
          "output": [
            {
              "content": [
                {
                  "type": "output_text",
                  "text": "{\\"type\\":\\"tool_call\\",\\"final_answer\\":null,\\"tool_name\\":\\"filesystem\\",\\"arguments\\":{\\"operation\\":\\"list_directory\\",\\"path\\":\\".\\"}}"
                }
              ]
            }
          ]
        }
        """)

        let adapter = OpenAIResponsesModelAdapter(
            configuration: .init(apiKey: "test-key", model: "gpt-5.4-mini", baseURL: URL(string: "https://example.com/v1/responses")!),
            session: session
        )

        let action = try await adapter.nextAction(for: sampleContext())
        let expected = ModelAction.toolCall(.init(toolName: "filesystem", arguments: [
            "operation": JSONValue.string("list_directory"),
            "path": JSONValue.string("."),
        ]))
        #expect(action == expected)
    }

    @Test func directReplyFallsBackToPlainTextOutput() async throws {
        let session = makeStubbedSession(statusCode: 200, body: """
        {
          "output": [
            {
              "content": [
                {
                  "type": "output_text",
                  "text": "I'm doing well. How can I help?"
                }
              ]
            }
          ]
        }
        """)

        let adapter = OpenAIResponsesModelAdapter(
            configuration: .init(apiKey: "test-key", model: "gpt-5.4-mini", baseURL: URL(string: "https://example.com/v1/responses")!),
            session: session
        )

        let reply = try await adapter.directReply(
            history: [
                .init(id: UUID(), threadID: UUID(), runID: UUID(), role: .user, content: "How are you?", createdAt: Date())
            ],
            systemPrompt: "You are helpful."
        )

        #expect(reply == "I'm doing well. How can I help?")
    }

    @Test func parsesStructuredTaskPlanOutput() async throws {
        let session = makeStubbedSession(statusCode: 200, body: """
        {
          "output": [
            {
              "content": [
                {
                  "type": "output_text",
                  "text": "{\\"steps\\":[{\\"title\\":\\"Inspect the current runtime flow\\",\\"phase\\":\\"exploration\\"},{\\"title\\":\\"Implement the Telegram model toggle\\",\\"phase\\":\\"mutation\\"},{\\"title\\":\\"Validate the updated Telegram flow\\",\\"phase\\":\\"validation\\"}]}"
                }
              ]
            }
          ]
        }
        """)

        let adapter = OpenAIResponsesModelAdapter(
            configuration: .init(apiKey: "test-key", model: "gpt-5.4-mini", baseURL: URL(string: "https://example.com/v1/responses")!),
            session: session
        )

        let plan = try await adapter.taskPlan(for: "Add Telegram model switching and validate the flow", taskKind: .feature)

        #expect(plan?.steps.count == 3)
        #expect(plan?.steps.first?.title == "Inspect the current runtime flow")
        #expect(plan?.steps.last?.phase == .validation)
    }
}

private func sampleContext() -> ModelContext {
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

private func makeStubbedSession(statusCode: Int, body: String) -> URLSession {
    StubURLProtocol.state.set(statusCode: statusCode, body: body)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubResponseState()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let current = Self.state.snapshot()
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.com")!,
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

private final class StubResponseState: @unchecked Sendable {
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
