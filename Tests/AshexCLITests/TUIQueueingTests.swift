@testable import AshexCLI
import Testing

@Test func promptQueueTracksOrderAndFrontRequeue() {
    var queue = PromptQueueState()

    let first = queue.enqueue("first")
    let second = queue.enqueue("second")

    #expect(queue.count == 2)
    #expect(queue.dequeue() == first)

    queue.requeueAtFront(first.incrementingAttemptCount())

    #expect(queue.count == 2)
    #expect(queue.dequeue()?.id == first.id)
    #expect(queue.dequeue() == second)
    #expect(queue.isEmpty)
}

@Test func promptFailureRoutingRetriesTransientProviderFailures() {
    #expect(PromptFailureRouting.shouldRetry(message: "429 Too Many Requests"))
    #expect(PromptFailureRouting.shouldRetry(message: "Model is temporarily unavailable, try again later"))
    #expect(PromptFailureRouting.shouldRetry(message: "connection refused"))
    #expect(!PromptFailureRouting.shouldRetry(message: "Ollama request failed with HTTP 500: out of memory"))
    #expect(!PromptFailureRouting.shouldRetry(message: "Run cancelled by user"))
    #expect(!PromptFailureRouting.shouldRetry(message: "Prompt violated policy"))
}

@Test func versionFlagIsRecognized() {
    #expect(AshexCLI.isVersionRequested(arguments: ["ashex", "--version"]))
    #expect(AshexCLI.isVersionRequested(arguments: ["ashex", "-v"]))
    #expect(!AshexCLI.isVersionRequested(arguments: ["ashex", "hello"]))
}

@Test func appBuildInfoFormatsVersionAndCommit() {
    let info = AppBuildInfo.load(
        environment: [
            "ASHEX_VERSION": "v1.2.3",
            "ASHEX_COMMIT": "abc1234"
        ],
        executableURL: nil,
        sourceFilePath: "/tmp/not-a-repo/AppBuildInfo.swift"
    )

    #expect(info.displayLabel == "v1.2.3+abc1234")
}

@Test func workspaceSelectionClampMatchesVisibleWorkspaceList() {
    #expect(WorkspaceSelection.clamped(-1, recentWorkspaceCount: 3) == 0)
    #expect(WorkspaceSelection.clamped(3, recentWorkspaceCount: 3) == 3)
    #expect(WorkspaceSelection.clamped(12, recentWorkspaceCount: 20) == WorkspaceSelection.visibleRecentWorkspaceLimit)
    #expect(WorkspaceSelection.maxSelectionIndex(for: 0) == 0)
}

@Test func ollamaModelOrderingPrefersGeneralModelsOverFunctionModels() {
    let ordered = OllamaModelDisplayOrdering.orderedDisplayNames(
        [
            "functiongemma:latest • 300 MB",
            "gemma4:latest • 9.6 GB"
        ],
        selectedModel: "llama3.2"
    )

    #expect(ordered.first == "gemma4:latest • 9.6 GB")
}

@Test func ollamaModelOrderingKeepsUsableSelectedModelFirst() {
    let ordered = OllamaModelDisplayOrdering.orderedDisplayNames(
        [
            "qwen2.5-coder:7b • 4.7 GB",
            "gemma4:latest • 9.6 GB"
        ],
        selectedModel: "qwen2.5-coder:7b"
    )

    #expect(ordered.first == "qwen2.5-coder:7b • 4.7 GB")
}
