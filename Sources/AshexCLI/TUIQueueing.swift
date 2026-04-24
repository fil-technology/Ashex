import Foundation

enum StorageFailureRouting {
    static func isStoragePressure(message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("storage volume is nearly full") ||
            normalized.contains("database or disk is full") ||
            normalized.contains("no space left on device") ||
            normalized.contains("disk full")
    }

    static func recoveryHint(message _: String? = nil) -> String {
        "Free disk space or restart Ashex with `--storage` pointing to a volume with more room."
    }

    static func runtimeFailureDetails(message: String) -> [String] {
        [
            "Ashex could not write to its local history database because storage is nearly full.",
            message,
            "Ashex is keeping the UI alive, but chat history and run state will stay unreliable until storage pressure is resolved."
        ]
    }
}

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

enum ProviderFailureRouting {
    static func isOllamaModelResourceFailure(message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("out of memory") ||
            normalized.contains("failed to allocate") ||
            normalized.contains("insufficient memory")
    }

    static func recoveryHint(provider: String, message: String? = nil) -> String {
        if let message, StorageFailureRouting.isStoragePressure(message: message) {
            return StorageFailureRouting.recoveryHint(message: message)
        }

        if provider == "ollama",
           let message,
           isOllamaModelResourceFailure(message: message) {
            return "Ollama is running. Choose a smaller installed model, stop other Ollama models with `ollama stop <model>`, or restart Ollama and refresh."
        }
        if provider == "esh",
           let message,
           isOllamaModelResourceFailure(message: message) {
            return "The selected `esh` model or context does not currently fit in memory. Choose a smaller model, reduce context usage, or refresh after switching models."
        }

        switch provider {
        case "openai":
            return "Set OPENAI_API_KEY, then open Provider Settings and refresh or keep using mock."
        case "anthropic":
            return "Add ANTHROPIC_API_KEY in Provider Settings or the environment, then refresh or keep using mock."
        case "esh":
            return "Bundle or install `esh`, then open Provider Settings and refresh or switch to mock."
        case "dflash":
            return "Start `dflash-serve`, then open Provider Settings and refresh or keep using mock."
        case "ollama":
            return "Start Ollama with `ollama serve`, then open Provider Settings and refresh or switch to mock."
        default:
            return "Open Provider Settings to choose a working provider."
        }
    }

    static func runtimeFailureDetails(provider: String, message: String) -> [String] {
        if StorageFailureRouting.isStoragePressure(message: message) {
            return StorageFailureRouting.runtimeFailureDetails(message: message)
        }

        if provider == "ollama", isOllamaModelResourceFailure(message: message) {
            return [
                "Selected Ollama model could not fit in available memory.",
                message,
                "Ashex is using the mock fallback until the selected model can load."
            ]
        }
        if provider == "esh", isOllamaModelResourceFailure(message: message) {
            return [
                "Selected `esh` model could not fit in available memory.",
                message,
                "Ashex is using the mock fallback until the selected `esh` model can load."
            ]
        }

        return [
            message,
            "Ashex could not rebuild the selected provider runtime. The TUI stays alive and queued prompts will wait until the provider is available again."
        ]
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
