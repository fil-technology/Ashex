import AshexCore
import Darwin
import Foundation

enum DaemonCLICommand: Equatable {
    case daemonRun([String])
    case daemonStart([String])
    case daemonStop([String])
    case daemonStatus([String])
    case telegramTest([String])
    case cronList([String])
    case cronAdd([String])
    case cronRemove([String])

    static func parse(arguments: [String]) -> DaemonCLICommand? {
        guard arguments.count >= 2 else { return nil }

        if let command = parseNamespaceFirst(arguments: arguments) {
            return command
        }

        if let command = parseVerbFirst(arguments: arguments) {
            return command
        }

        return nil
    }

    private static func parseNamespaceFirst(arguments: [String]) -> DaemonCLICommand? {
        for index in commandCandidateIndexes(in: arguments) {
            let namespace = arguments[index]
            guard arguments.indices.contains(index + 1) else { continue }
            let action = arguments[index + 1]
            let extraArguments = commandExtraArguments(arguments: arguments, commandIndexes: [index, index + 1])
            switch (namespace, action) {
            case ("daemon", "run"), ("deamon", "run"):
                return .daemonRun(extraArguments)
            case ("daemon", "start"), ("deamon", "start"):
                return .daemonStart(extraArguments)
            case ("daemon", "stop"), ("deamon", "stop"):
                return .daemonStop(extraArguments)
            case ("daemon", "status"), ("deamon", "status"):
                return .daemonStatus(extraArguments)
            case ("telegram", "test"):
                return .telegramTest(extraArguments)
            case ("cron", "list"):
                return .cronList(extraArguments)
            case ("cron", "add"):
                return .cronAdd(extraArguments)
            case ("cron", "remove"):
                return .cronRemove(extraArguments)
            default:
                continue
            }
        }

        return nil
    }

    private static func parseVerbFirst(arguments: [String]) -> DaemonCLICommand? {
        for index in commandCandidateIndexes(in: arguments) {
            let action = arguments[index]
            guard arguments.indices.contains(index + 1) else { continue }
            let namespace = arguments[index + 1]
            let extraArguments = commandExtraArguments(arguments: arguments, commandIndexes: [index, index + 1])
            switch (action, namespace) {
            case ("run", "daemon"), ("run", "deamon"):
                return .daemonRun(extraArguments)
            case ("start", "daemon"), ("start", "deamon"):
                return .daemonStart(extraArguments)
            case ("stop", "daemon"), ("stop", "deamon"):
                return .daemonStop(extraArguments)
            case ("status", "daemon"), ("status", "deamon"):
                return .daemonStatus(extraArguments)
            default:
                continue
            }
        }

        return nil
    }

    private static func commandCandidateIndexes(in arguments: [String]) -> [Int] {
        var indexes: [Int] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if optionNamesWithValues.contains(argument), arguments.indices.contains(index + 1) {
                index += 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            indexes.append(index)
            index += 1
        }
        return indexes
    }

    private static func commandExtraArguments(arguments: [String], commandIndexes: Set<Int>) -> [String] {
        arguments.indices
            .filter { $0 != arguments.startIndex && !commandIndexes.contains($0) }
            .map { arguments[$0] }
    }

    private static let optionNamesWithValues: Set<String> = [
        "--workspace",
        "--storage",
        "--max-iterations",
        "--provider",
        "--model",
        "--approval-mode",
        "--id",
        "--schedule",
        "--tz",
        "--timezone",
        "--prompt",
    ]
}

enum DaemonCLI {
    static let telegramSecretNamespace = "connector.credentials"
    static let telegramSecretKey = "telegram_bot_token"
    static let explicitStartEnvironmentKey = "ASHEX_DAEMON_EXPLICIT_START"

    static func handle(arguments: [String]) async throws -> Bool {
        guard let command = DaemonCLICommand.parse(arguments: arguments) else {
            return false
        }

        switch command {
        case .daemonRun(let extraArguments):
            let launchedInBackground = ProcessInfo.processInfo.environment[explicitStartEnvironmentKey] == "1"
            try await run(
                extraArguments: extraArguments,
                launchedInBackground: launchedInBackground,
                explicitStartRequested: true
            )
        case .daemonStart(let extraArguments):
            try await start(extraArguments: extraArguments)
        case .daemonStop(let extraArguments):
            try stop(extraArguments: extraArguments)
        case .daemonStatus(let extraArguments):
            try status(extraArguments: extraArguments)
        case .telegramTest(let extraArguments):
            try await telegramTest(extraArguments: extraArguments)
        case .cronList(let extraArguments):
            try cronList(extraArguments: extraArguments)
        case .cronAdd(let extraArguments):
            try cronAdd(extraArguments: extraArguments)
        case .cronRemove(let extraArguments):
            try cronRemove(extraArguments: extraArguments)
        }

        return true
    }

    private static func run(
        extraArguments: [String],
        launchedInBackground: Bool,
        explicitStartRequested: Bool = false
    ) async throws {
        let configuration = try CLIConfiguration(arguments: [CommandLine.arguments[0]] + extraArguments)
        let token = resolvedTelegramToken(from: configuration.userConfig.telegram, storageRoot: configuration.storageRoot)
        let persistence = try configuration.makePersistenceStore()
        let logger = DaemonLogger(minimumLevel: daemonLogLevel(from: configuration.userConfig.logging.level))
        let cronStore = CronJobStore(persistence: persistence)
        let hasCronJobs = (try? cronStore.listJobs().contains { $0.isEnabled }) ?? false
        let connectors: [any Connector]
        if configuration.userConfig.telegram.enabled, let token, !token.isEmpty {
            connectors = [
                TelegramConnector(
                    token: token,
                    config: configuration.userConfig.telegram,
                    persistence: persistence,
                    logger: logger
                )
            ]
        } else {
            connectors = []
        }

        let shouldTreatAsExplicitStart = explicitStartRequested
            || launchedInBackground
            || ProcessInfo.processInfo.environment[explicitStartEnvironmentKey] == "1"
        guard shouldRunDaemon(
            config: configuration.userConfig,
            resolvedTelegramToken: token,
            hasEnabledCronJobs: hasCronJobs,
            explicitStartRequested: shouldTreatAsExplicitStart
        ) else {
            throw AshexError.model("Daemon run requires either Telegram to be enabled with a valid bot token or at least one enabled cron job.")
        }

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

        let registry = ConnectorRegistry(connectors: connectors)
        let mappingStore = ConnectorConversationMappingStore(persistence: persistence)
        let router = ConversationRouter(mappingStore: mappingStore)
        let dispatcher = RunDispatcher(runtime: runtime, logger: logger)
        let cronScheduler = CronScheduler(
            store: cronStore,
            dispatcher: dispatcher,
            persistence: persistence,
            logger: logger,
            maxIterations: configuration.maxIterations
        )
        let listModels: (@Sendable () async throws -> [String])?
        if configuration.provider == "ollama" {
            listModels = {
                let models = try await OllamaCatalogClient().fetchModels(baseURL: CLIConfiguration.ollamaBaseURL())
                return models.map(\.name).sorted()
            }
        } else if configuration.provider == "esh" {
            listModels = {
                try listStandaloneEshModels(configuration: configuration)
            }
        } else {
            listModels = nil
        }
        let switchModel: @Sendable (String) async throws -> Void = { requestedModel in
            let updatedRuntime = try configuration.makeRuntime(
                persistence: persistence,
                provider: configuration.provider,
                model: requestedModel,
                approvalPolicy: ConnectorApprovalPolicy(
                    policyMode: configuration.userConfig.telegram.executionPolicy,
                    connectorName: "telegram",
                    remoteApprovalInbox: remoteApprovalInbox,
                    runStore: runStore
                )
            )
            await dispatcher.replaceRuntime(updatedRuntime)
            let now = Date()
            try persistence.upsertSetting(namespace: "ui.session", key: "default_provider", value: .string(configuration.provider), now: now)
            try persistence.upsertSetting(namespace: "ui.session", key: "default_model", value: .string(requestedModel), now: now)
        }
        let modelControl = DaemonModelControl(
            listModels: listModels,
            switchModel: switchModel
        )
        let audioReplySynthesizer = makeAudioReplySynthesizer(configuration: configuration)
        let supervisor = DaemonSupervisor(
            registry: registry,
            router: router,
            dispatcher: dispatcher,
            persistence: persistence,
            logger: logger,
            runStore: runStore,
            remoteApprovalInbox: remoteApprovalInbox,
            modelControl: modelControl,
            config: .init(
                maxIterations: configuration.maxIterations,
                connectorLabel: "telegram",
                provider: configuration.provider,
                model: configuration.model,
                workspaceRootPath: configuration.workspaceRoot.path,
                sandbox: configuration.userConfig.sandbox,
                executionPolicy: configuration.userConfig.telegram.executionPolicy,
                responseMode: configuration.userConfig.telegram.responseMode,
                audioReplySynthesizer: audioReplySynthesizer
            )
        )

        await logger.log(.info, subsystem: "daemon", message: "Daemon boot complete", metadata: [
            "workspace": .string(configuration.workspaceRoot.path),
            "storage": .string(configuration.storageRoot.path),
            "provider": .string(configuration.provider),
            "model": .string(configuration.model),
            "background": .bool(launchedInBackground),
        ])
        try await supervisor.start()
        await cronScheduler.start()
        try await DaemonSignalTrap.waitForTermination()
        await cronScheduler.stop()
        await supervisor.stop()
    }

    static func shouldRunDaemon(
        config: AshexUserConfig,
        resolvedTelegramToken: String?,
        hasEnabledCronJobs: Bool,
        explicitStartRequested: Bool = false
    ) -> Bool {
        explicitStartRequested
            || config.daemon.enabled
            || hasEnabledCronJobs
            || (config.telegram.enabled && resolvedTelegramToken?.isEmpty == false)
    }

    static func explicitStartEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment[explicitStartEnvironmentKey] = "1"
        return environment
    }

    private static func listStandaloneEshModels(configuration: CLIConfiguration) throws -> [String] {
        let inspector = EshOptimizationInspector()
        guard let executablePath = inspector.resolveExecutablePath(config: configuration.userConfig.optimization.esh) else {
            throw AshexError.model("`esh` was not found. Bundle it with Ashex, set optimization.esh.executablePath, or set ESH_EXECUTABLE.")
        }

        let homePath = inspector.resolveHomePath(config: configuration.userConfig.optimization.esh)
        let capabilities = try CLIConfiguration.inspectEshCapabilities(
            executablePath: executablePath,
            homePath: homePath
        )
        return capabilities.installedModels
            .map(\.id)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
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
        process.environment = explicitStartEnvironment()
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        process.standardOutput = handle
        process.standardError = handle
        try process.run()

        let status = try await waitForStartedDaemon(process: process, stateStore: stateStore)
        guard status?.isRunning == true else {
            try? handle.close()
            if process.isRunning {
                process.terminate()
            }
            throw AshexError.model(daemonStartupFailureMessage(
                logURL: logURL,
                fallback: process.isRunning
                    ? "Daemon startup timed out before it reported ready."
                    : "Daemon failed to start in background."
            ))
        }
        try? handle.close()

        print("ash daemon started")
        print("pid: \(status?.pid ?? process.processIdentifier)")
        print("log: \(logURL.path)")
    }

    static func waitForStartedDaemon(
        process: Process,
        stateStore: DaemonProcessStateStore,
        timeoutSeconds: TimeInterval = 20,
        pollIntervalNanoseconds: UInt64 = 150_000_000
    ) async throws -> DaemonProcessStatus? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        repeat {
            if let status = try stateStore.status(), status.isRunning {
                return status
            }
            if !process.isRunning {
                return try stateStore.status()
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        } while Date() < deadline

        return try stateStore.status()
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
        let token = resolvedTelegramToken(from: configuration.userConfig.telegram, storageRoot: configuration.storageRoot)
        guard let token, !token.isEmpty else {
            throw AshexError.model("Missing Telegram bot token. Set `telegram.botToken` in config or ASHEX_TELEGRAM_BOT_TOKEN.")
        }
        let client = URLSessionTelegramBotClient()
        let identity = try await client.getMe(token: token)
        print("telegram ok")
        print("bot_id: \(identity.id)")
        print("username: \(identity.username ?? "<none>")")
    }

    private static func cronList(extraArguments: [String]) throws {
        let configuration = try CLIConfiguration(arguments: [CommandLine.arguments[0]] + extraArguments)
        let store = CronJobStore(persistence: try configuration.makePersistenceStore())
        let jobs = try store.listJobs()
        if jobs.isEmpty {
            print("no cron jobs configured")
            return
        }
        let formatter = ISO8601DateFormatter()
        for job in jobs {
            print("\(job.id) [\(job.isEnabled ? "enabled" : "disabled")]")
            print("  schedule: \(job.schedule.expression)")
            print("  timezone: \(job.schedule.timeZoneIdentifier)")
            print("  next_run: \(formatter.string(from: job.nextRunAt))")
            if let lastRunAt = job.lastRunAt {
                print("  last_run: \(formatter.string(from: lastRunAt))")
            }
            print("  prompt: \(job.prompt)")
        }
    }

    private static func cronAdd(extraArguments: [String]) throws {
        let configuration = try CLIConfiguration(arguments: [CommandLine.arguments[0]] + extraArguments)
        let parsed = try parseCronArguments(extraArguments)
        let schedule = CronSchedule(
            expression: parsed.expression,
            timeZoneIdentifier: parsed.timeZoneIdentifier ?? TimeZone.current.identifier
        )
        let nextRunAt = try schedule.nextRunDate(after: Date())
        let job = CronJobRecord(
            id: parsed.id,
            prompt: parsed.prompt,
            schedule: schedule,
            createdAt: Date(),
            nextRunAt: nextRunAt
        )
        let store = CronJobStore(persistence: try configuration.makePersistenceStore())
        try store.save(job)
        print("cron job saved")
        print("id: \(job.id)")
        print("schedule: \(job.schedule.expression)")
        print("timezone: \(job.schedule.timeZoneIdentifier)")
        print("next_run: \(ISO8601DateFormatter().string(from: job.nextRunAt))")
    }

    private static func cronRemove(extraArguments: [String]) throws {
        let configuration = try CLIConfiguration(arguments: [CommandLine.arguments[0]] + extraArguments)
        guard let id = optionValue(named: "--id", in: extraArguments) else {
            throw AshexError.model("cron remove requires --id <job-id>")
        }
        let store = CronJobStore(persistence: try configuration.makePersistenceStore())
        try store.delete(id: id)
        print("removed cron job \(id)")
    }

    private static func parseCronArguments(_ arguments: [String]) throws -> (id: String, expression: String, timeZoneIdentifier: String?, prompt: String) {
        guard let id = optionValue(named: "--id", in: arguments) else {
            throw AshexError.model("cron add requires --id <job-id>")
        }
        guard let expression = optionValue(named: "--expr", in: arguments) ?? optionValue(named: "--schedule", in: arguments) else {
            throw AshexError.model("cron add requires --expr \"MIN HOUR DAY MONTH WEEKDAY\"")
        }
        guard let prompt = optionValue(named: "--prompt", in: arguments) else {
            throw AshexError.model("cron add requires --prompt \"...\"")
        }
        return (id, expression, optionValue(named: "--tz", in: arguments) ?? optionValue(named: "--timezone", in: arguments), prompt)
    }

    private static func optionValue(named option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func resolvedTelegramToken(from config: TelegramConfig, storageRoot: URL) -> String? {
        let envToken = ProcessInfo.processInfo.environment["ASHEX_TELEGRAM_BOT_TOKEN"]
        if envToken?.isEmpty == false {
            return envToken
        }
        if let configToken = config.botToken, !configToken.isEmpty {
            return configToken
        }
        let secretStore = LocalJSONSecretStore(fileURL: storageRoot.appendingPathComponent("secrets.json"))
        if let stored = try? secretStore.readSecret(namespace: telegramSecretNamespace, key: telegramSecretKey),
           !stored.isEmpty {
            return stored
        }
        return nil
    }

    static func daemonStartupFailureMessage(logURL: URL, fallback: String) -> String {
        let logTail = daemonLogTail(logURL: logURL)
        guard !logTail.isEmpty else {
            return "\(fallback) Check \(logURL.path)"
        }
        var message = "\(fallback)\nRecent daemon log:\n\(logTail)"
        if let action = daemonStartupFailureAction(for: logTail) {
            message += "\nAction: \(action)"
        }
        return message
    }

    static func daemonLogTail(logURL: URL, maxLines: Int = 8) -> String {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }

        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { line in
                line.range(of: "Action:", options: [.anchored, .caseInsensitive]) == nil
            }

        return lines.suffix(maxLines).joined(separator: "\n")
    }

    private static func daemonStartupFailureAction(for logTail: String) -> String? {
        let lowercased = logTail.lowercased()
        if lowercased.contains("telegram") && lowercased.contains("bot token") {
            return "Save a Telegram bot token in Assistant Setup, set ASHEX_TELEGRAM_BOT_TOKEN, or add an enabled cron job."
        }
        if lowercased.contains("cron job") {
            return "Add an enabled cron job or enable Telegram with a valid bot token."
        }
        if lowercased.contains("no space left on device") || lowercased.contains("error: other(28)") {
            return "Free disk space, then start the daemon again. The daemon needs writable storage for its SQLite database, state file, and log."
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

    private static func makeAudioReplySynthesizer(
        configuration: CLIConfiguration
    ) -> (@Sendable (_ text: String, _ workspaceRootPath: String) async throws -> InputAttachment)? {
        let resolvedAudioModel = configuration.userConfig.audio.resolvedModel(
            chatProvider: configuration.provider,
            chatModel: configuration.model
        )
        guard resolvedAudioModel.provider != "local" else {
            return nil
        }

        return { text, workspaceRootPath in
            do {
                let adapter = try configuration.makeModelAdapter(
                    provider: resolvedAudioModel.provider,
                    model: resolvedAudioModel.model
                )
                guard let directChatAdapter = adapter as? any DirectChatModelAdapter else {
                    return try await DaemonAudioReplySynthesizer.synthesize(text: text, workspaceRootPath: workspaceRootPath)
                }

                let threadID = UUID()
                let request = """
                Generate a spoken audio file containing this assistant reply text.
                Return the generated file as a line beginning with `Generated audio file:`.

                \(text)
                """
                let envelope = try await directChatAdapter.directReplyEnvelope(
                    history: [
                        MessageRecord(
                            id: UUID(),
                            threadID: threadID,
                            runID: nil,
                            role: .user,
                            content: request,
                            createdAt: Date()
                        )
                    ],
                    systemPrompt: "You are Ashex's audio reply synthesizer. Produce audio output when the selected model supports it.",
                    attachments: []
                )
                if let attachment = envelope.text
                    .components(separatedBy: .newlines)
                    .compactMap(GeneratedAudioReplyParser.attachment(from:))
                    .first {
                    return attachment
                }
            } catch {
                // Fall back to the local speech synthesizer so Telegram audio mode still replies.
            }

            return try await DaemonAudioReplySynthesizer.synthesize(text: text, workspaceRootPath: workspaceRootPath)
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
            let trapState = SignalTrapState(
                interruptSource: interruptSource,
                termSource: termSource,
                continuation: continuation
            )
            let finish: @Sendable () -> Void = {
                trapState.finish()
            }
            interruptSource.setEventHandler(handler: finish)
            termSource.setEventHandler(handler: finish)
            interruptSource.resume()
            termSource.resume()
        }
    }

    private final class SignalTrapState: @unchecked Sendable {
        private let interruptSource: DispatchSourceSignal
        private let termSource: DispatchSourceSignal
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(
            interruptSource: DispatchSourceSignal,
            termSource: DispatchSourceSignal,
            continuation: CheckedContinuation<Void, Error>
        ) {
            self.interruptSource = interruptSource
            self.termSource = termSource
            self.continuation = continuation
        }

        func finish() {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()

            guard let continuation else { return }
            interruptSource.cancel()
            termSource.cancel()
            continuation.resume()
        }
    }
}
