import Foundation

public struct GitHubRepoTool: Tool {
    public let name = "github_repo"
    public let description = "Read-only inspection of public GitHub or other remote git repositories without changing the current workspace"
    public let contract = ToolContract(
        name: "github_repo",
        description: "Read-only inspection of public GitHub or other remote git repositories without changing the current workspace",
        kind: .embedded,
        category: "github",
        operationArgumentKey: "operation",
        operations: [
            .init(
                name: "inspect_repository",
                description: "Fetch repository metadata, top-level entries, latest commit, and README excerpt",
                mutatesWorkspace: false,
                requiresNetwork: true,
                inspectedPathArguments: ["repository_url"],
                progressSummary: "inspected remote repository",
                approval: .init(risk: .low, summary: "Inspect remote repository", reasonTemplate: "{{repository_url}} @ {{ref}}"),
                arguments: [
                    .init(name: "repository_url", description: "GitHub repository URL or clone URL", type: .string, required: true),
                    .init(name: "ref", description: "Optional branch, tag, or commit to inspect", type: .string, required: false),
                    .init(name: "refresh_remote", description: "Refresh the cached remote mirror before reading", type: .bool, required: false),
                ]
            ),
            .init(
                name: "list_files",
                description: "List files or directories from a remote repository path",
                mutatesWorkspace: false,
                requiresNetwork: true,
                inspectedPathArguments: ["repository_url", "path"],
                progressSummary: "listed remote repository files",
                approval: .init(risk: .low, summary: "List remote repository files", reasonTemplate: "{{repository_url}} @ {{ref}} {{path}}"),
                arguments: [
                    .init(name: "repository_url", description: "GitHub repository URL or clone URL", type: .string, required: true),
                    .init(name: "ref", description: "Optional branch, tag, or commit to inspect", type: .string, required: false),
                    .init(name: "path", description: "Optional repository-relative path to list", type: .string, required: false),
                    .init(name: "recursive", description: "List recursively instead of only direct entries", type: .bool, required: false),
                    .init(name: "limit", description: "Maximum number of entries to return", type: .number, required: false),
                    .init(name: "refresh_remote", description: "Refresh the cached remote mirror before reading", type: .bool, required: false),
                ]
            ),
            .init(
                name: "read_file",
                description: "Read one UTF-8 text file from a remote repository",
                mutatesWorkspace: false,
                requiresNetwork: true,
                inspectedPathArguments: ["repository_url", "path"],
                progressSummary: "read remote repository file",
                approval: .init(risk: .low, summary: "Read remote repository file", reasonTemplate: "{{repository_url}} @ {{ref}} {{path}}"),
                arguments: [
                    .init(name: "repository_url", description: "GitHub repository URL or clone URL", type: .string, required: true),
                    .init(name: "path", description: "Repository-relative file path", type: .string, required: false),
                    .init(name: "ref", description: "Optional branch, tag, or commit to inspect", type: .string, required: false),
                    .init(name: "refresh_remote", description: "Refresh the cached remote mirror before reading", type: .bool, required: false),
                ]
            ),
            .init(
                name: "search_text",
                description: "Search repository text content with git grep",
                mutatesWorkspace: false,
                requiresNetwork: true,
                inspectedPathArguments: ["repository_url", "path"],
                progressSummary: "searched remote repository text",
                approval: .init(risk: .low, summary: "Search remote repository text", reasonTemplate: "{{repository_url}} @ {{ref}} for {{query}}"),
                arguments: [
                    .init(name: "repository_url", description: "GitHub repository URL or clone URL", type: .string, required: true),
                    .init(name: "query", description: "Text query for git grep", type: .string, required: true),
                    .init(name: "ref", description: "Optional branch, tag, or commit to inspect", type: .string, required: false),
                    .init(name: "path", description: "Optional repository-relative path filter", type: .string, required: false),
                    .init(name: "limit", description: "Maximum number of matches to return", type: .number, required: false),
                    .init(name: "refresh_remote", description: "Refresh the cached remote mirror before reading", type: .bool, required: false),
                ]
            ),
        ],
        tags: ["core", "github", "git", "remote", "network"]
    )

    private let executionRuntime: any ExecutionRuntime
    private let cacheRoot: URL

    public init(
        executionRuntime: any ExecutionRuntime,
        cacheRoot: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ashex-github-repo-cache", isDirectory: true)
    ) {
        self.executionRuntime = executionRuntime
        self.cacheRoot = cacheRoot
    }

    public func execute(arguments: JSONObject, context: ToolContext) async throws -> ToolContent {
        try await context.cancellation.checkCancellation()

        guard let operation = arguments["operation"]?.stringValue, !operation.isEmpty else {
            throw AshexError.invalidToolArguments("github_repo.operation must be a non-empty string")
        }

        let request = try RepositoryRequest(arguments: arguments)
        let mirrorURL = try await prepareMirror(for: request, cancellation: context.cancellation)

        switch operation {
        case "inspect_repository":
            return try await inspectRepository(request: request, mirrorURL: mirrorURL, cancellation: context.cancellation)
        case "list_files":
            return try await listFiles(request: request, mirrorURL: mirrorURL, arguments: arguments, cancellation: context.cancellation)
        case "read_file":
            return try await readFile(request: request, mirrorURL: mirrorURL, cancellation: context.cancellation)
        case "search_text":
            return try await searchText(request: request, mirrorURL: mirrorURL, arguments: arguments, cancellation: context.cancellation)
        default:
            throw AshexError.invalidToolArguments("Unsupported github_repo operation: \(operation)")
        }
    }

    private func prepareMirror(for request: RepositoryRequest, cancellation: CancellationToken) async throws -> URL {
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let mirrorURL = cacheRoot.appendingPathComponent(cacheKey(for: request.cloneURL), isDirectory: true)
        let mirrorPath = shellQuoted(mirrorURL.path)

        if FileManager.default.fileExists(atPath: mirrorURL.path) {
            if request.refreshRemote {
                _ = try await runGitCommand(
                    "git --git-dir \(mirrorPath) remote update --prune",
                    workspaceURL: cacheRoot,
                    cancellation: cancellation,
                    timeout: 60
                )
            }
            return mirrorURL
        }

        _ = try await runGitCommand(
            "git clone --mirror \(shellQuoted(request.cloneURL)) \(mirrorPath)",
            workspaceURL: cacheRoot,
            cancellation: cancellation,
            timeout: 90
        )
        return mirrorURL
    }

    private func inspectRepository(
        request: RepositoryRequest,
        mirrorURL: URL,
        cancellation: CancellationToken
    ) async throws -> ToolContent {
        let topLevel = try await lines(
            from: "git --git-dir \(shellQuoted(mirrorURL.path)) ls-tree --name-only \(shellQuoted(request.ref))",
            workspaceURL: cacheRoot,
            cancellation: cancellation,
            timeout: 30
        )
        let allFiles = try await lines(
            from: "git --git-dir \(shellQuoted(mirrorURL.path)) ls-tree -r --name-only \(shellQuoted(request.ref))",
            workspaceURL: cacheRoot,
            cancellation: cancellation,
            timeout: 30
        )
        let latestCommit = try await runGitCommand(
            "git --git-dir \(shellQuoted(mirrorURL.path)) log -1 --format=%H%n%s%n%an%n%ad --date=iso-strict \(shellQuoted(request.ref))",
            workspaceURL: cacheRoot,
            cancellation: cancellation,
            timeout: 30
        ).stdout
        let defaultBranch = (try? await runGitCommand(
            "git --git-dir \(shellQuoted(mirrorURL.path)) symbolic-ref --short HEAD",
            workspaceURL: cacheRoot,
            cancellation: cancellation,
            timeout: 15
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines))

        let readmePath = allFiles.first(where: Self.isLikelyReadme)
        let readmeExcerpt: String?
        if let readmePath {
            readmeExcerpt = try await snippet(
                for: readmePath,
                request: request,
                mirrorURL: mirrorURL,
                cancellation: cancellation
            )
        } else {
            readmeExcerpt = nil
        }

        let commitParts = latestCommit.split(separator: "\n", omittingEmptySubsequences: false)
        let payload: JSONValue = .object([
            "repository_url": .string(request.originalURL),
            "clone_url": .string(request.cloneURL),
            "ref": .string(request.ref),
            "default_branch": .string(defaultBranch ?? ""),
            "top_level_entries": .array(topLevel.prefix(50).map(JSONValue.string)),
            "file_count": .number(Double(allFiles.count)),
            "latest_commit": .object([
                "hash": .string(commitParts.indices.contains(0) ? String(commitParts[0]) : ""),
                "subject": .string(commitParts.indices.contains(1) ? String(commitParts[1]) : ""),
                "author": .string(commitParts.indices.contains(2) ? String(commitParts[2]) : ""),
                "date": .string(commitParts.indices.contains(3) ? String(commitParts[3]) : ""),
            ]),
            "readme_path": readmePath.map(JSONValue.string) ?? .null,
            "readme_excerpt": readmeExcerpt.map(JSONValue.string) ?? .null,
        ])
        return .structured(payload)
    }

    private func listFiles(
        request: RepositoryRequest,
        mirrorURL: URL,
        arguments: JSONObject,
        cancellation: CancellationToken
    ) async throws -> ToolContent {
        let recursive = arguments["recursive"]?.boolValue ?? false
        let limit = max(arguments["limit"]?.intValue ?? 200, 1)
        let path = request.path
        var command = "git --git-dir \(shellQuoted(mirrorURL.path)) ls-tree"
        if recursive {
            command += " -r"
        }
        command += " --name-only \(shellQuoted(request.ref))"
        if let path, !path.isEmpty {
            command += " -- \(shellQuoted(path))"
        }

        let entries = try await lines(from: command, workspaceURL: cacheRoot, cancellation: cancellation, timeout: 30)
        return .structured(.object([
            "repository_url": .string(request.originalURL),
            "clone_url": .string(request.cloneURL),
            "ref": .string(request.ref),
            "path": path.map(JSONValue.string) ?? .null,
            "recursive": .bool(recursive),
            "entries": .array(entries.prefix(limit).map(JSONValue.string)),
            "entry_count": .number(Double(entries.count)),
            "truncated": .bool(entries.count > limit),
        ]))
    }

    private func readFile(
        request: RepositoryRequest,
        mirrorURL: URL,
        cancellation: CancellationToken
    ) async throws -> ToolContent {
        guard let path = request.path, !path.isEmpty else {
            throw AshexError.invalidToolArguments("github_repo.path must be provided for read_file")
        }
        let objectSpec = "\(request.ref):\(path)"
        let content = try await runGitCommand(
            "git --git-dir \(shellQuoted(mirrorURL.path)) show \(shellQuoted(objectSpec))",
            workspaceURL: cacheRoot,
            cancellation: cancellation,
            timeout: 30
        ).stdout
        return .structured(.object([
            "repository_url": .string(request.originalURL),
            "clone_url": .string(request.cloneURL),
            "ref": .string(request.ref),
            "path": .string(path),
            "content": .string(content),
        ]))
    }

    private func searchText(
        request: RepositoryRequest,
        mirrorURL: URL,
        arguments: JSONObject,
        cancellation: CancellationToken
    ) async throws -> ToolContent {
        let query = try requiredString("query", in: arguments)
        let limit = max(arguments["limit"]?.intValue ?? 50, 1)
        var command = "git --git-dir \(shellQuoted(mirrorURL.path)) grep -n --no-color -I -e \(shellQuoted(query)) \(shellQuoted(request.ref))"
        if let path = request.path, !path.isEmpty {
            command += " -- \(shellQuoted(path))"
        }

        let output = try await runGitCommand(
            command,
            workspaceURL: cacheRoot,
            cancellation: cancellation,
            timeout: 30,
            allowExitCodeOne: true
        )
        let matches = output.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        return .structured(.object([
            "repository_url": .string(request.originalURL),
            "clone_url": .string(request.cloneURL),
            "ref": .string(request.ref),
            "path": request.path.map(JSONValue.string) ?? .null,
            "query": .string(query),
            "matches": .array(matches.prefix(limit).map(JSONValue.string)),
            "match_count": .number(Double(matches.count)),
            "truncated": .bool(matches.count > limit),
        ]))
    }

    private func snippet(
        for path: String,
        request: RepositoryRequest,
        mirrorURL: URL,
        cancellation: CancellationToken
    ) async throws -> String {
        let objectSpec = "\(request.ref):\(path)"
        let content = try await runGitCommand(
            "git --git-dir \(shellQuoted(mirrorURL.path)) show \(shellQuoted(objectSpec))",
            workspaceURL: cacheRoot,
            cancellation: cancellation,
            timeout: 30
        ).stdout
        return content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(20)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lines(
        from command: String,
        workspaceURL: URL,
        cancellation: CancellationToken,
        timeout: TimeInterval
    ) async throws -> [String] {
        let stdout = try await runGitCommand(command, workspaceURL: workspaceURL, cancellation: cancellation, timeout: timeout).stdout
        return stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func runGitCommand(
        _ command: String,
        workspaceURL: URL,
        cancellation: CancellationToken,
        timeout: TimeInterval,
        allowExitCodeOne: Bool = false
    ) async throws -> ShellExecutionResult {
        let result = try await executionRuntime.execute(
            .init(command: command, workspaceURL: workspaceURL, timeout: timeout),
            cancellationToken: cancellation,
            onStdout: { _ in },
            onStderr: { _ in }
        )

        if result.timedOut {
            throw AshexError.shell("Remote repository command timed out after \(Int(timeout))s")
        }

        if result.exitCode != 0 && !(allowExitCodeOne && result.exitCode == 1) {
            throw AshexError.shell("Remote repository command failed with exit code \(result.exitCode)\nstdout:\n\(result.stdout)\nstderr:\n\(result.stderr)")
        }

        return result
    }

    private func requiredString(_ key: String, in arguments: JSONObject) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw AshexError.invalidToolArguments("github_repo.\(key) must be a non-empty string")
        }
        return value
    }

    private func cacheKey(for repositoryURL: String) -> String {
        Data(repositoryURL.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isLikelyReadme(path: String) -> Bool {
        path.split(separator: "/").count == 1 && path.lowercased().hasPrefix("readme")
    }
}

private struct RepositoryRequest {
    let originalURL: String
    let cloneURL: String
    let ref: String
    let path: String?
    let refreshRemote: Bool

    init(arguments: JSONObject) throws {
        let repositoryURL = try Self.requiredString("repository_url", in: arguments)
        let parsed = Self.normalizeRepositoryURL(repositoryURL)
        originalURL = repositoryURL
        cloneURL = parsed.cloneURL
        ref = arguments["ref"]?.stringValue ?? parsed.ref ?? "HEAD"
        path = arguments["path"]?.stringValue ?? parsed.path
        refreshRemote = arguments["refresh_remote"]?.boolValue ?? true
    }

    private static func requiredString(_ key: String, in arguments: JSONObject) throws -> String {
        guard let value = arguments[key]?.stringValue, !value.isEmpty else {
            throw AshexError.invalidToolArguments("github_repo.\(key) must be a non-empty string")
        }
        return value
    }

    private static func normalizeRepositoryURL(_ raw: String) -> (cloneURL: String, ref: String?, path: String?) {
        guard let components = URLComponents(string: raw),
              let host = components.host?.lowercased(),
              host.contains("github.com") else {
            return (raw, nil, nil)
        }

        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            return (raw, nil, nil)
        }

        let owner = parts[0]
        let repo = parts[1].replacingOccurrences(of: ".git", with: "")
        let cloneURL = "https://github.com/\(owner)/\(repo).git"

        guard parts.count >= 4, ["tree", "blob"].contains(parts[2]) else {
            return (cloneURL, nil, nil)
        }

        let ref = parts[3]
        let path = parts.count > 4 ? parts.dropFirst(4).joined(separator: "/") : nil
        return (cloneURL, ref, path)
    }
}
