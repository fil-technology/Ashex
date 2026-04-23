import Foundation

public enum ConnectorMessageIntent: String, Sendable, Equatable {
    case directChat
    case workspaceTask
}

public enum ConnectorMessageIntentClassifier {
    public static func classify(_ prompt: String) -> ConnectorMessageIntent {
        let lowered = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return .directChat }

        if lowered.contains("github.com/") || lowered.contains("github repo") {
            return .workspaceTask
        }

        let liveLookupSignals = [
            "weather", "forecast", "latest news", "search latest", "look up", "lookup",
            "search for", "find information", "load this url"
        ]
        if liveLookupSignals.contains(where: lowered.contains) {
            return .workspaceTask
        }

        let explicitToolSignals = [
            "shell:", "run shell", "use curl", "run curl", "curl ", "wget ", "git ", "swift test",
            "xcodebuild", "npm ", "pnpm ", "yarn ", "python ", "ruby ", "node ", "make ",
            "call this api", "request to", "use the shell", "run command", "execute command"
        ]
        if explicitToolSignals.contains(where: lowered.contains) {
            return .workspaceTask
        }

        let workspaceCreationVerbs = [
            "create ", "build ", "generate ", "write ", "make ", "add ", "edit ", "update ",
            "change ", "modify ", "fix "
        ]
        let workspaceCreationObjects = [
            "html", "website", "web site", "page", "landing page", "app", "project",
            "file", "folder", "directory", "localization", "translation", "css", "javascript"
        ]
        if workspaceCreationVerbs.contains(where: lowered.hasPrefix),
           workspaceCreationObjects.contains(where: lowered.contains) {
            return .workspaceTask
        }

        let directChatPrefixes = [
            "how are you", "who are you", "what can you do", "hello", "hi", "hey", "thanks",
            "thank you", "good morning", "good evening", "explain", "what is", "what's", "why is",
            "can you explain", "tell me about", "tell me a joke", "help me understand",
            "give me", "write me", "show me", "summarize", "search latest", "latest news",
            "what is this repo about", "what this repo is about"
        ]
        if directChatPrefixes.contains(where: lowered.hasPrefix) {
            return .directChat
        }

        let workspaceSignals = [
            "repo", "repository", "codebase", "workspace", "package.swift", "readme", "source file",
            "sources/", "tests/", ".swift", ".md", ".json", ".yml", ".yaml", ".toml", ".py", ".js",
            "directory", "folder", "branch", "commit", "diff", "patch", "refactor", "fix the bug",
            "run the tests", "build the project", "inspect the repo", "inspect the codebase",
            "edit file", "open file", "read file", "list files", "find in files", "grep"
        ]
        if workspaceSignals.contains(where: lowered.contains) {
            return .workspaceTask
        }

        if lowered.hasSuffix("?") {
            return .directChat
        }

        let actionButNotToolPrefixes = [
            "search ", "find ", "look for ", "write ", "generate ", "create ", "draft ", "summarize ",
            "tell me ", "show me ", "load ", "fetch "
        ]
        if actionButNotToolPrefixes.contains(where: lowered.hasPrefix),
           !explicitToolSignals.contains(where: lowered.contains) {
            return .directChat
        }

        return .directChat
    }
}
