import Foundation

public struct ShellExecutionPolicy: Sendable {
    public let sandbox: SandboxPolicyConfig
    public let network: NetworkPolicyConfig
    public let shell: ShellCommandPolicy

    public init(sandbox: SandboxPolicyConfig, network: NetworkPolicyConfig, shell: ShellCommandPolicy) {
        self.sandbox = sandbox
        self.network = network
        self.shell = shell
    }

    public func assess(command: String) -> ShellCommandPolicy.Assessment {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)

        if sandbox.mode == .readOnly, Self.isMutatingShellCommand(trimmed) {
            return .deny("Workspace sandbox is read-only, so mutating shell commands are blocked.")
        }

        var approvalReasons: [String] = []

        switch assessNetwork(command: trimmed) {
        case .allow:
            break
        case .requireApproval(let reason):
            approvalReasons.append(reason)
        case .deny(let reason):
            return .deny(reason)
        }

        switch shell.assess(command: trimmed) {
        case .allow:
            break
        case .requireApproval(let reason):
            approvalReasons.append(reason)
        case .deny(let reason):
            return .deny(reason)
        }

        if !approvalReasons.isEmpty {
            return .requireApproval(approvalReasons.joined(separator: "\n"))
        }

        return .allow
    }

    public func validate(command: String, approvalGranted: Bool = false) throws {
        switch assess(command: command) {
        case .allow:
            return
        case .requireApproval(let message):
            guard approvalGranted else {
                throw AshexError.shell(message)
            }
        case .deny(let message):
            throw AshexError.shell(message)
        }
    }

    private func assessNetwork(command: String) -> ShellCommandPolicy.Assessment {
        let lowered = command.lowercased()

        if let rule = network.rules.first(where: { lowered.hasPrefix($0.prefix.lowercased()) }) {
            switch rule.action {
            case .allow:
                return .allow
            case .prompt:
                return .requireApproval(rule.reason ?? "Command '\(command)' matched a network prompt rule and requires approval.")
            case .deny:
                return .deny(rule.reason ?? "Command '\(command)' is denied by a network policy rule.")
            }
        }

        guard Self.isNetworkCommand(lowered) else {
            return .allow
        }

        switch network.mode {
        case .allow:
            return .allow
        case .prompt:
            return .requireApproval("Command '\(command)' appears to require network access and requires approval under the current network policy.")
        case .deny:
            return .deny("Command '\(command)' appears to require network access, but network access is disabled by policy.")
        }
    }

    public static func isMutatingShellCommand(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let prefixes = ["rm ", "mv ", "cp ", "mkdir ", "touch ", "sed -i", "perl -pi", "python ", "python3 ", "node ", "tee ", "echo "]
        if prefixes.contains(where: { lowered.hasPrefix($0) }) {
            return true
        }
        return lowered.contains(" > ") || lowered.contains(">>")
    }

    public static func isNetworkCommand(_ command: String) -> Bool {
        let prefixes = [
            "curl ", "wget ", "http ", "https ", "ssh ", "scp ", "sftp ",
            "git clone", "git fetch", "git pull", "git push",
            "npm install", "npm update", "npm publish",
            "pnpm install", "pnpm add", "pnpm update",
            "yarn install", "yarn add",
            "pip install", "pip3 install",
            "cargo install", "cargo add",
            "go get ", "gem install", "bundle install",
            "brew install", "brew update", "pod install"
        ]
        if prefixes.contains(where: command.hasPrefix) {
            return true
        }

        return command.contains("http://") || command.contains("https://")
    }
}
