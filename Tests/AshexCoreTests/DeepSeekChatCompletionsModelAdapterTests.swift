@testable import AshexCore
import Foundation
import Testing

@Suite(.serialized)
struct DeepSeekChatCompletionsModelAdapterTests {
    @Test func directReplyEnvelopeParsesReplyJSON() async throws {
        let session = await makeDeepSeekStubbedSession(responses: [
            (200, """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"reply\\":\\"hello from deepseek\\"}"
                  }
                }
              ]
            }
            """)
        ])

        let adapter = DeepSeekChatCompletionsModelAdapter(
            configuration: .init(
                apiKey: "test-key",
                model: "deepseek-v4-flash"
            ),
            session: session
        )

        let thread = ThreadRecord(id: UUID(), createdAt: Date())
        let envelope = try await adapter.directReplyEnvelope(
            history: [
                .init(id: UUID(), threadID: thread.id, runID: nil, role: .user, content: "Say hi", createdAt: Date())
            ],
            systemPrompt: "Be short.",
            attachments: []
        )

        #expect(envelope.text == "hello from deepseek")
    }

    @Test func nextActionParsesToolCallJSON() async throws {
        let session = await makeDeepSeekStubbedSession(responses: [
            (200, """
            {
              "choices": [
                {
                  "message": {
                    "content": "{\\"type\\":\\"tool_call\\",\\"final_answer\\":null,\\"tool_name\\":\\"filesystem\\",\\"arguments\\":{\\"operation\\":\\"list_directory\\",\\"path\\":\\".\\"}}"
                  }
                }
              ]
            }
            """)
        ])

        let adapter = DeepSeekChatCompletionsModelAdapter(
            configuration: .init(
                apiKey: "test-key",
                model: "deepseek-v4-flash"
            ),
            session: session
        )

        let thread = ThreadRecord(id: UUID(), createdAt: Date())
        let run = RunRecord(id: UUID(), threadID: thread.id, state: .running, createdAt: Date(), updatedAt: Date())
        let action = try await adapter.nextAction(for: .init(
            thread: thread,
            run: run,
            messages: [
                .init(id: UUID(), threadID: thread.id, runID: run.id, role: .user, content: "List files", createdAt: Date())
            ],
            availableTools: [
                .init(name: "filesystem", description: "Filesystem tool")
            ]
        ))

        #expect(action == .toolCall(.init(toolName: "filesystem", arguments: [
            "operation": .string("list_directory"),
            "path": .string("."),
        ])))
    }
}

private func makeDeepSeekStubbedSession(responses: [(Int, String)]) async -> URLSession {
    await DeepSeekStubURLProtocol.state.setResponses(responses)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [DeepSeekStubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class DeepSeekStubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = DeepSeekStubState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString.contains("deepseek") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Task {
            let response = await Self.state.next()
            let httpResponse = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.deepseek.com/chat/completions")!,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private actor DeepSeekStubState {
    private var responses: [(statusCode: Int, body: String)] = [(200, "")]
    private var requestCount = 0

    func setResponses(_ responses: [(Int, String)]) {
        requestCount = 0
        self.responses = responses.map { (statusCode: $0.0, body: $0.1) }
    }

    func next() -> (statusCode: Int, body: String) {
        let index = min(requestCount, max(responses.count - 1, 0))
        defer { requestCount += 1 }
        return responses[index]
    }
}
