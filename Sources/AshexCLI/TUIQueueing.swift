import Foundation

struct QueuedPrompt: Equatable, Sendable {
    let id: Int
    let text: String
    let enqueuedAt: Date
    let attemptCount: Int

    init(id: Int, text: String, enqueuedAt: Date = Date(), attemptCount: Int = 0) {
        self.id = id
        self.text = text
        self.enqueuedAt = enqueuedAt
        self.attemptCount = attemptCount
    }

    func incrementingAttemptCount() -> Self {
        Self(id: id, text: text, enqueuedAt: enqueuedAt, attemptCount: attemptCount + 1)
    }
}

struct PromptQueueState: Sendable {
    private(set) var queuedPrompts: [QueuedPrompt] = []
    private(set) var nextPromptID = 1

    var isEmpty: Bool { queuedPrompts.isEmpty }
    var count: Int { queuedPrompts.count }
    var first: QueuedPrompt? { queuedPrompts.first }

    @discardableResult
    mutating func enqueue(_ text: String, now: Date = Date()) -> QueuedPrompt {
        let prompt = QueuedPrompt(id: nextPromptID, text: text, enqueuedAt: now)
        nextPromptID += 1
        queuedPrompts.append(prompt)
        return prompt
    }

    mutating func dequeue() -> QueuedPrompt? {
        guard !queuedPrompts.isEmpty else { return nil }
        return queuedPrompts.removeFirst()
    }

    mutating func requeueAtFront(_ prompt: QueuedPrompt) {
        queuedPrompts.insert(prompt, at: 0)
    }
}

enum PromptFailureRouting {
    static func shouldRetry(message: String) -> Bool {
        let normalized = message.lowercased()
        let retryIndicators = [
            "429",
            "rate limit",
            "too many requests",
            "overloaded",
            "temporarily unavailable",
            "service unavailable",
            "server overloaded",
            "out of tokens",
            "insufficient_quota",
            "quota exceeded",
            "token limit",
            "connection refused",
            "failed to connect",
            "could not connect",
            "connection reset",
            "timed out",
            "timeout",
            "network",
            "unavailable",
            "try again"
        ]
        let cancellationIndicators = [
            "cancelled",
            "canceled"
        ]

        if cancellationIndicators.contains(where: normalized.contains) {
            return false
        }

        return retryIndicators.contains(where: normalized.contains)
    }
}

enum WorkspaceSelection {
    static let visibleRecentWorkspaceLimit = 8

    static func maxSelectionIndex(for recentWorkspaceCount: Int) -> Int {
        min(max(recentWorkspaceCount, 0), visibleRecentWorkspaceLimit)
    }

    static func clamped(_ selection: Int, recentWorkspaceCount: Int) -> Int {
        min(max(selection, 0), maxSelectionIndex(for: recentWorkspaceCount))
    }
}
