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
    #expect(!PromptFailureRouting.shouldRetry(message: "Run cancelled by user"))
    #expect(!PromptFailureRouting.shouldRetry(message: "Prompt violated policy"))
}

@Test func workspaceSelectionClampMatchesVisibleWorkspaceList() {
    #expect(WorkspaceSelection.clamped(-1, recentWorkspaceCount: 3) == 0)
    #expect(WorkspaceSelection.clamped(3, recentWorkspaceCount: 3) == 3)
    #expect(WorkspaceSelection.clamped(12, recentWorkspaceCount: 20) == WorkspaceSelection.visibleRecentWorkspaceLimit)
    #expect(WorkspaceSelection.maxSelectionIndex(for: 0) == 0)
}
