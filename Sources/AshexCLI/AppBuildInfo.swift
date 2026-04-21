import Foundation

struct AppBuildInfo: Sendable {
    let version: String
    let commit: String?

    var displayLabel: String {
        if let commit, !commit.isEmpty {
            return "\(version)+\(commit)"
        }
        return version
    }

    static let current = AppBuildInfo.load()

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableURL: URL? = Bundle.main.executableURL,
        sourceFilePath: String = #filePath
    ) -> AppBuildInfo {
        let sidecar = executableURL.map { $0.deletingLastPathComponent().appendingPathComponent("ashex.version") }
        let sidecarValues = sidecar.flatMap(loadSidecar)
        let version = nonEmpty(environment["ASHEX_VERSION"])
            ?? nonEmpty(sidecarValues?["version"])
            ?? "dev"
        let commit = nonEmpty(environment["ASHEX_COMMIT"])
            ?? nonEmpty(sidecarValues?["commit"])
            ?? gitCommit(sourceFilePath: sourceFilePath)

        return AppBuildInfo(version: version, commit: commit)
    }

    private static func loadSidecar(url: URL) -> [String: String]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] =
                parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return values
    }

    private static func gitCommit(sourceFilePath: String) -> String? {
        var directory = URL(fileURLWithPath: sourceFilePath).deletingLastPathComponent()
        let fileManager = FileManager.default
        while directory.path != "/" {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return runGitShortHead(in: directory)
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func runGitShortHead(in directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "--short", "HEAD"]
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return nonEmpty(String(data: data, encoding: .utf8))
        } catch {
            return nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}
