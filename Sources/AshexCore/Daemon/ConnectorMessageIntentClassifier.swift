import Foundation

public enum ConnectorMessageIntent: String, Sendable, Equatable {
    case directChat
    case workspaceTask
}

public enum ConnectorMessageIntentClassifier {
    public static func classify(_ prompt: String) -> ConnectorMessageIntent {
        let lowered = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return .directChat }

        let workspaceSignals = [
            "repo", "repository", "codebase", "project", "workspace", "file", "files", "directory",
            "folder", "readme", "package.swift", "source", "sources", "test", "tests", "build",
            "compile", "run the tests", "fix", "implement", "refactor", "search", "inspect", "read ",
            "open ", "list ", "find ", "grep", "git ", "branch", "commit", "diff", "daemon", "telegram"
        ]
        if workspaceSignals.contains(where: lowered.contains) {
            return .workspaceTask
        }

        let directChatPrefixes = [
            "how are you", "who are you", "what can you do", "hello", "hi", "hey", "thanks",
            "thank you", "good morning", "good evening", "explain", "what is", "what's", "why is",
            "can you explain", "tell me about", "tell me a joke", "help me understand"
        ]
        if directChatPrefixes.contains(where: lowered.hasPrefix) {
            return .directChat
        }

        if lowered.hasSuffix("?"), lowered.split(whereSeparator: \.isWhitespace).count <= 12 {
            return .directChat
        }

        return .workspaceTask
    }
}
