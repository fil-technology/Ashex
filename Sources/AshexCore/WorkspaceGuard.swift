import Foundation

public struct WorkspaceGuard: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
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
}
