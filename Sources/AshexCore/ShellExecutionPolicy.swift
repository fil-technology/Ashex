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

        if Self.isDestructiveShellCommand(trimmed) {
            approvalReasons.append("Command '\(trimmed)' appears destructive or privilege-elevated and requires explicit approval.")
        }

        if Self.isCredentialSensitiveCommand(trimmed) {
            approvalReasons.append("Command '\(trimmed)' may read, print, or export credentials and requires explicit approval.")
        }

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
        if isDestructiveShellCommand(lowered) {
            return true
        }

        let prefixes = [
            "rm ", "mv ", "cp ", "mkdir ", "touch ", "sed -i", "perl -pi",
            "python ", "python3 ", "node ", "tee ", "echo ",
            "chmod ", "chown ", "git reset", "git clean", "git checkout --", "git restore ",
            "swift build", "swift test", "swift package",
            "xcodebuild", "npm run build", "pnpm run build", "yarn build"
        ]
        if prefixes.contains(where: { lowered.hasPrefix($0) }) {
            return true
        }
        return lowered.contains(" >")
            || lowered.contains("> ")
            || lowered.contains(">>")
    }

    public static func isNetworkCommand(_ command: String) -> Bool {
        let command = command.lowercased()
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

    public static func isDestructiveShellCommand(_ command: String) -> Bool {
        let lowered = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }

        if lowered.hasPrefix("sudo ") {
            return true
        }

        if lowered.hasPrefix("rm ") {
            let destructiveFlags = ["-rf", "-fr", "-r ", "-r/", "-r\t", "--recursive"]
            if destructiveFlags.contains(where: lowered.contains) {
                return true
            }
        }

        if lowered.hasPrefix("git reset --hard")
            || lowered.hasPrefix("git clean ") && lowered.contains("-f")
            || lowered.hasPrefix("chmod -r")
            || lowered.hasPrefix("chown -r")
            || lowered.hasPrefix("kill -9")
            || lowered.hasPrefix("killall ")
            || lowered.hasPrefix("mkfs")
            || lowered.hasPrefix("diskutil erase")
            || lowered.hasPrefix("diskutil partition")
            || lowered.hasPrefix("dd ") && lowered.contains(" of=") {
            return true
        }

        return lowered.contains("| xargs rm")
            || lowered.contains("|xargs rm")
            || lowered.contains(" xargs rm ")
    }

    public static func isCredentialSensitiveCommand(_ command: String) -> Bool {
        let lowered = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return false }

        if lowered.hasPrefix("security find-generic-password")
            || lowered.hasPrefix("security find-internet-password")
            || lowered.hasPrefix("op read ")
            || lowered.hasPrefix("op item get ")
            || lowered.hasPrefix("pass show ") {
            return true
        }

        if lowered.hasPrefix("cat ") || lowered.hasPrefix("less ") || lowered.hasPrefix("more ") {
            let credentialPaths = [
                ".env", "~/.ssh", "/.ssh/", "id_rsa", "id_ed25519", ".netrc",
                "~/.aws/credentials", ".aws/credentials", "credentials.json"
            ]
            if credentialPaths.contains(where: lowered.contains) {
                return true
            }
        }

        if lowered.hasPrefix("export ")
            || lowered.hasPrefix("printenv")
            || lowered == "env"
            || lowered.hasPrefix("env ")
            || lowered.hasPrefix("env |") {
            return containsCredentialIdentifier(lowered)
        }

        if lowered.contains("$") && containsCredentialIdentifier(lowered) {
            return true
        }

        if (lowered.hasPrefix("grep ") || lowered.hasPrefix("rg "))
            && lowered.contains(".env")
            && containsCredentialIdentifier(lowered) {
            return true
        }

        return false
    }

    private static func containsCredentialIdentifier(_ command: String) -> Bool {
        let identifiers = [
            "api_key", "apikey", "access_key", "secret", "token", "password",
            "passwd", "credential", "private_key", "client_secret", "session_key"
        ]
        return identifiers.contains(where: command.contains)
    }
}
