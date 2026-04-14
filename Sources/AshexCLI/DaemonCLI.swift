import AshexCore
import Darwin
import Foundation

enum DaemonCLICommand: Equatable {
    case daemonRun([String])
    case daemonStart([String])
    case daemonStop([String])
    case daemonStatus([String])
    case telegramTest([String])

    static func parse(arguments: [String]) -> DaemonCLICommand? {
        guard arguments.count >= 2 else { return nil }
        switch (arguments[1], arguments.dropFirst(2).first) {
        case ("daemon", "run"):
            return .daemonRun(Array(arguments.dropFirst(3)))
        case ("daemon", "start"):
            return .daemonStart(Array(arguments.dropFirst(3)))
        case ("daemon", "stop"):
            return .daemonStop(Array(arguments.dropFirst(3)))
        case ("daemon", "status"):
            return .daemonStatus(Array(arguments.dropFirst(3)))
        case ("telegram", "test"):
            return .telegramTest(Array(arguments.dropFirst(3)))
        default:
            return nil
        }
    }
}

enum DaemonCLI {
    static let telegramSecretNamespace = "connector.credentials"
    static let telegramSecretKey = "telegram_bot_token"

    static func handle(arguments: [String]) async throws -> Bool {
        guard let command = DaemonCLICommand.parse(arguments: arguments) else {
            return false
        }

        switch command {
        case .daemonRun(let extraArguments):
            try await run(extraArguments: extraArguments, launchedInBackground: false)
        case .daemonStart(let extraArguments):
            try await start(extraArguments: extraArguments)
        case .daemonStop(let extraArguments):
            try stop(extraArguments: extraArguments)
        case .daemonStatus(let extraArguments):
            try status(extraArguments: extraArguments)
        case .telegramTest(let extraArguments):
            try await telegramTest(extraArguments: extraArguments)
        }

        return true
    }

    private static func run(extraArguments: [String], launchedInBackground: Bool) async throws {
        let configuration = try CLIConfiguration(arguments: [CommandLine.arguments[0]] + extraArguments)
        let persistence = try configuration.makePersistenceStore()
        let logger = DaemonLogger(minimumLevel: daemonLogLevel(from: configuration.userConfig.logging.level))
        let runStore = DaemonConversationRunStore()
        let remoteApprovalInbox = RemoteApprovalInbox(persistence: persistence)
        try await remoteApprovalInbox.normalizeInterruptedApprovals()
        let runtime = try configuration.makeRuntime(
            persistence: persistence,
            provider: configuration.provider,
            model: configuration.model,
            approvalPolicy: ConnectorApprovalPolicy(
                policyMode: configuration.userConfig.telegram.executionPolicy,
                connectorName: "telegram",
                remoteApprovalInbox: remoteApprovalInbox,
                runStore: runStore
            )
        )

        let stateStore = DaemonProcessStateStore(storageRoot: configuration.storageRoot)
        try stateStore.writeCurrentProcess(logPath: stateStore.logFileURL.path)
        defer { try? stateStore.clearIfOwnedByCurrentProcess() }

        let token = resolvedTelegramToken(from: configuration.userConfig.telegram)
        guard configuration.userConfig.telegram.enabled, let token, !token.isEmpty else {
            throw AshexError.model("Telegram daemon mode requires `telegram.enabled` and a bot token in config or ASHEX_TELEGRAM_BOT_TOKEN.")
        }

        let connector = TelegramConnector(
            token: token,
            config: configuration.userConfig.telegram,
            persistence: persistence,
            logger: logger
        )
        let registry = ConnectorRegistry(connectors: [connector])
        let mappingStore = ConnectorConversationMappingStore(persistence: persistence)
        let router = ConversationRouter(mappingStore: mappingStore)
        let dispatcher = RunDispatcher(runtime: runtime, logger: logger)
        let supervisor = DaemonSupervisor(
            registry: registry,
            router: router,
            dispatcher: dispatcher,
            persistence: persistence,
            logger: logger,
            runStore: runStore,
            remoteApprovalInbox: remoteApprovalInbox,
            config: .init(maxIterations: configuration.maxIterations, connectorLabel: "telegram")
        )

        await logger.log(.info, subsystem: "daemon", message: "Daemon boot complete", metadata: [
            "workspace": .string(configuration.workspaceRoot.path),
            "storage": .string(configuration.storageRoot.path),
            "provider": .string(configuration.provider),
            "model": .string(configuration.model),
            "background": .bool(launchedInBackground),
        ])
        try await supervisor.start()
        try await DaemonSignalTrap.waitForTermination()
        await supervisor.stop()
    }

    private static func start(extraArguments: [String]) async throws {
        let configuration = try CLIConfiguration(arguments: [CommandLine.arguments[0]] + extraArguments)
        let stateStore = DaemonProcessStateStore(storageRoot: configuration.storageRoot)
        if let status = try stateStore.status(), status.isRunning {
            print("ash daemon is already running with pid \(status.pid)")
            return
        }

        let logURL = stateStore.logFileURL
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: Data())
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()

        let process = Process()
        process.executableURL = try ExecutableLocator.currentExecutableURL()
        process.arguments = ["daemon", "run"] + extraArguments
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()

        print("ash daemon started")
        print("pid: \(process.processIdentifier)")
        print("log: \(logURL.path)")
    }

    private static func stop(extraArguments: [String]) throws {
        let configuration = try CLIConfiguration(arguments: [CommandLine.arguments[0]] + extraArguments)
        let stateStore = DaemonProcessStateStore(storageRoot: configuration.storageRoot)
        guard let status = try stateStore.status(), status.pid > 0 else {
            print("ash daemon is not running")
            return
        }

        if kill(status.pid, SIGTERM) == 0 {
            print("Sent SIGTERM to ash daemon pid \(status.pid)")
        } else {
            perror("kill")
        }
    }

    private static func status(extraArguments: [String]) throws {
        let configuration = try CLIConfiguration(arguments: [CommandLine.arguments[0]] + extraArguments)
        let stateStore = DaemonProcessStateStore(storageRoot: configuration.storageRoot)
        if let status = try stateStore.status(), status.isRunning {
            print("ash daemon running")
            print("pid: \(status.pid)")
            print("started_at: \(ISO8601DateFormatter().string(from: status.startedAt))")
            print("log: \(status.logPath)")
        } else {
            print("ash daemon not running")
        }
    }

    private static func telegramTest(extraArguments: [String]) async throws {
        let configuration = try CLIConfiguration(arguments: [CommandLine.arguments[0]] + extraArguments)
        let token = resolvedTelegramToken(from: configuration.userConfig.telegram)
        guard let token, !token.isEmpty else {
            throw AshexError.model("Missing Telegram bot token. Set `telegram.botToken` in config or ASHEX_TELEGRAM_BOT_TOKEN.")
        }
        let client = URLSessionTelegramBotClient()
        let identity = try await client.getMe(token: token)
        print("telegram ok")
        print("bot_id: \(identity.id)")
        print("username: \(identity.username ?? "<none>")")
    }

    private static func resolvedTelegramToken(from config: TelegramConfig) -> String? {
        let envToken = ProcessInfo.processInfo.environment["ASHEX_TELEGRAM_BOT_TOKEN"]
        if envToken?.isEmpty == false {
            return envToken
        }
        if let configToken = config.botToken, !configToken.isEmpty {
            return configToken
        }
        let secretStore = KeychainSecretStore()
        if let stored = try? secretStore.readSecret(namespace: telegramSecretNamespace, key: telegramSecretKey),
           !stored.isEmpty {
            return stored
        }
        return nil
    }

    private static func daemonLogLevel(from level: LoggingLevel) -> DaemonLogLevel {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .warning
        case .error: return .error
        }
    }
}

private enum DaemonSignalTrap {
    static func waitForTermination() async throws {
        try await withCheckedThrowingContinuation { continuation in
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            let queue = DispatchQueue(label: "ashex.daemon.signals")
            let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
            let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
            let finish: @Sendable () -> Void = {
                interruptSource.cancel()
                termSource.cancel()
                continuation.resume()
            }
            interruptSource.setEventHandler(handler: finish)
            termSource.setEventHandler(handler: finish)
            interruptSource.resume()
            termSource.resume()
        }
    }
}
