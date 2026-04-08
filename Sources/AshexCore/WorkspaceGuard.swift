import Foundation

public struct WorkspaceGuard: Sendable {
    public let rootURL: URL
    public let sandbox: SandboxPolicyConfig

    public init(rootURL: URL, sandbox: SandboxPolicyConfig = .default) {
        self.rootURL = rootURL.standardizedFileURL
        self.sandbox = sandbox
    }

    public func resolve(path: String) throws -> URL {
        let candidate = URL(fileURLWithPath: path, relativeTo: rootURL)
            .standardizedFileURL

        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let candidatePath = candidate.path

        if candidatePath == rootURL.path || candidatePath.hasPrefix(rootPath) {
            return candidate
        }

        throw AshexError.workspaceViolation("Path escapes workspace root: \(path)")
    }

    public func resolveForMutation(path: String) throws -> URL {
        let candidate = try resolve(path: path)
        try validateMutation(for: candidate, originalPath: path)
        return candidate
    }

    private func validateMutation(for candidate: URL, originalPath: String) throws {
        switch sandbox.mode {
        case .readOnly:
            throw AshexError.workspaceViolation("Workspace sandbox is read-only. Mutation blocked for path: \(originalPath)")
        case .workspaceWrite:
            if isProtected(candidate: candidate) {
                throw AshexError.workspaceViolation("Path is protected by the workspace sandbox: \(originalPath). Update ashex.config.json or switch sandbox mode if you intend to change it.")
            }
        case .dangerFullAccess:
            return
        }
    }

    private func isProtected(candidate: URL) -> Bool {
        let rootPath = rootURL.path
        let candidatePath = candidate.path
        let relativePath: String
        if candidatePath == rootPath {
            relativePath = "."
        } else {
            relativePath = String(candidatePath.dropFirst(rootPath.count + 1))
        }

        return sandbox.protectedPaths.contains { protectedPath in
            relativePath == protectedPath || relativePath.hasPrefix(protectedPath + "/")
        }
    }
}
