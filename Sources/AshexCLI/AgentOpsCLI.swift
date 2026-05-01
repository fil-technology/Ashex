import AshexCore
import Foundation

enum AgentOpsCLI {
    private static let commands: Set<String> = [
        "context", "soul", "memory", "skills", "mcp", "kb", "sessions", "tasks",
        "processes", "learnings", "routes", "rpc", "doctor",
    ]

    static func handle(arguments: [String]) async throws -> Bool {
        guard let commandIndex = arguments.indices.dropFirst().first(where: { commands.contains(arguments[$0]) }) else {
            return false
        }

        let command = arguments[commandIndex]
        let commandArguments = stripGlobalOptions(Array(arguments[(commandIndex + 1)...]))
        let configuration = try CLIConfiguration(arguments: arguments)
        let home = AgentHome(storageRoot: configuration.storageRoot, workspaceRoot: configuration.workspaceRoot)
        try home.initialize()

        switch command {
        case "context":
            try handleContext(commandArguments, home: home)
        case "soul":
            try handleSoul(commandArguments, home: home)
        case "memory":
            try handleMemory(commandArguments, home: home)
        case "skills":
            try handleSkills(commandArguments, home: home)
        case "mcp":
            try await handleMCP(commandArguments, home: home, configuration: configuration)
        case "kb":
            try handleKB(commandArguments, home: home)
        case "sessions":
            try handleSessions(commandArguments, home: home, configuration: configuration)
        case "tasks":
            try handleTasks(commandArguments, home: home)
        case "processes":
            try handleProcesses(commandArguments, home: home)
        case "learnings":
            try handleLearnings(commandArguments, home: home)
        case "routes":
            try handleRoutes(commandArguments, configuration: configuration)
        case "rpc":
            try await handleRPC(commandArguments, configuration: configuration)
        case "doctor":
            try handleDoctor(home: home, configuration: configuration)
        default:
            return false
        }
        return true
    }

    private static func handleContext(_ arguments: [String], home: AgentHome) throws {
        let subcommand = arguments.first ?? "list"
        switch subcommand {
        case "list":
            let bundle = try AgentContextLoader(home: home).loadContext()
            for file in bundle.files {
                print("\(file.relativePath)\(file.truncated ? " (truncated)" : "")")
            }
            for warning in bundle.warnings {
                print("warning: \(warning.relativePath): \(warning.findings.joined(separator: "; "))")
            }
        case "init":
            let report = try home.initialize(createProjectContextFiles: true)
            print(report.createdPaths.isEmpty ? "Context files already exist." : "Created:\n" + report.createdPaths.joined(separator: "\n"))
        case "doctor":
            let bundle = try AgentContextLoader(home: home).loadContext()
            print("Context files: \(bundle.files.count)")
            if bundle.warnings.isEmpty {
                print("Prompt-injection warnings: none")
            } else {
                for warning in bundle.warnings {
                    print("warning: \(warning.relativePath): \(warning.findings.joined(separator: "; "))")
                }
            }
        default:
            throw AshexError.model("Usage: ashex context <list|init|doctor>")
        }
    }

    private static func handleSoul(_ arguments: [String], home: AgentHome) throws {
        let subcommand = arguments.first ?? "show"
        switch subcommand {
        case "show":
            print(try String(contentsOf: home.paths.soulFile, encoding: .utf8))
        case "edit":
            try openEditorOrPrintPath(home.paths.soulFile)
        default:
            throw AshexError.model("Usage: ashex soul <show|edit>")
        }
    }

    private static func handleMemory(_ arguments: [String], home: AgentHome) throws {
        guard let subcommand = arguments.first else {
            throw AshexError.model("Usage: ashex memory <list|show|add|replace|remove|search>")
        }
        let store = AgentMemoryStore(home: home)
        switch subcommand {
        case "list":
            for scope in AgentMemoryScope.allCases {
                print("\(scope.rawValue): \(home.paths.displayPath(for: store.fileURL(for: scope)))")
            }
        case "show":
            let scope = try parseMemoryScope(arguments.dropFirst().first)
            print(try store.read(scope: scope))
        case "add":
            let scope = try parseMemoryScope(arguments.dropFirst().first)
            let text = arguments.dropFirst(2).joined(separator: " ")
            guard !text.isEmpty else { throw AshexError.model("Usage: ashex memory add <scope> <text>") }
            try store.append(scope: scope, text: text)
            print("Added memory to \(scope.rawValue).")
        case "replace":
            let rest = Array(arguments.dropFirst())
            guard rest.count >= 3 else { throw AshexError.model("Usage: ashex memory replace <scope> <unique-substring> <replacement>") }
            try store.replace(scope: parseMemoryScope(rest[0]), uniqueSubstring: rest[1], replacement: rest.dropFirst(2).joined(separator: " "))
            print("Replaced memory.")
        case "remove":
            let rest = Array(arguments.dropFirst())
            guard rest.count >= 2 else { throw AshexError.model("Usage: ashex memory remove <scope> <unique-substring>") }
            try store.remove(scope: parseMemoryScope(rest[0]), uniqueSubstring: rest.dropFirst().joined(separator: " "))
            print("Removed memory.")
        case "search":
            let query = arguments.dropFirst().joined(separator: " ")
            guard !query.isEmpty else { throw AshexError.model("Usage: ashex memory search <query>") }
            for result in try store.search(query) {
                print("\(result.scope.rawValue) \(result.path):\(result.line): \(result.text)")
            }
        case "consolidate":
            print("Memory consolidation is not automatic yet; use replace/remove to curate entries explicitly.")
        default:
            throw AshexError.model("Usage: ashex memory <list|show|add|replace|remove|search|consolidate>")
        }
    }

    private static func handleSkills(_ arguments: [String], home: AgentHome) throws {
        guard let subcommand = arguments.first else {
            throw AshexError.model("Usage: ashex skills <list|search|show|install|audit|validate|route|enable|quarantine|create|export|remove|update>")
        }
        let store = AgentSkillStore(home: home)
        switch subcommand {
        case "list":
            for skill in try store.list() {
                print("\(skill.name) [\(skill.state.rawValue)] - \(skill.metadata.description)")
            }
        case "search":
            let query = arguments.dropFirst().joined(separator: " ").lowercased()
            for skill in try store.list() where query.isEmpty || skill.name.lowercased().contains(query) || skill.metadata.description.lowercased().contains(query) {
                print("\(skill.name) [\(skill.state.rawValue)] - \(skill.metadata.description)")
            }
        case "show":
            let name = try requiredArgument(arguments, index: 1, usage: "ashex skills show <name>")
            print(try store.show(name: name).content)
        case "install":
            let source = try requiredArgument(arguments, index: 1, usage: "ashex skills install <local-folder>")
            let record = try store.install(from: URL(fileURLWithPath: source, relativeTo: home.workspaceRoot))
            print("Installed \(record.name) into quarantine.")
        case "audit":
            let name = try requiredArgument(arguments, index: 1, usage: "ashex skills audit <name>")
            let audit = try store.audit(name: name)
            print(audit.findings.isEmpty ? "No prompt-injection warnings for \(name)." : audit.findings.joined(separator: "\n"))
        case "validate":
            let validations = try arguments.indices.contains(1) ? [store.validate(name: arguments[1])] : store.validateAll()
            for validation in validations {
                let status = validation.isValid ? "ok" : "invalid"
                print("\(validation.name) [\(validation.state.rawValue)] \(status)")
                for error in validation.errors {
                    print("error: \(error)")
                }
                for warning in validation.warnings {
                    print("warning: \(warning)")
                }
            }
        case "route":
            let task = arguments.dropFirst().joined(separator: " ")
            guard !task.isEmpty else { throw AshexError.model("Usage: ashex skills route <task>") }
            let router = SkillRouter(availableTools: ["filesystem", "shell", "git", "swift"])
            for score in router.rank(task: task, skills: try store.routeMetadata()) {
                print("\(score.metadata.name) score=\(String(format: "%.2f", score.score)) reasons=\(score.reasons.joined(separator: ","))")
            }
        case "enable":
            let name = try requiredArgument(arguments, index: 1, usage: "ashex skills enable <name>")
            try store.enable(name: name)
            print("Enabled \(name).")
        case "quarantine":
            let name = try requiredArgument(arguments, index: 1, usage: "ashex skills quarantine <name>")
            try quarantineSkill(name: name, store: store)
            print("Quarantined \(name).")
        case "create":
            let name = try requiredArgument(arguments, index: 1, usage: "ashex skills create <name>")
            try createGeneratedSkill(name: name, home: home)
            print("Created generated skill draft \(name).")
        case "export":
            let name = try requiredArgument(arguments, index: 1, usage: "ashex skills export <name>")
            print(try store.show(name: name).record.path)
        case "remove":
            let name = try requiredArgument(arguments, index: 1, usage: "ashex skills remove <name>")
            try store.remove(name: name)
            print("Removed \(name).")
        case "update":
            let name = try requiredArgument(arguments, index: 1, usage: "ashex skills update <name>")
            _ = try store.audit(name: name)
            print("Checked \(name). Network skill updates are not enabled silently; reinstall from an explicit local source to update.")
        default:
            throw AshexError.model("Usage: ashex skills <list|search|show|install|audit|validate|route|enable|quarantine|create|export|remove|update>")
        }
    }

    private static func handleMCP(_ arguments: [String], home: AgentHome, configuration: CLIConfiguration) async throws {
        guard let subcommand = arguments.first else {
            throw AshexError.model("Usage: ashex mcp <list|add|remove|reload|tools|resources|prompts|call|serve>")
        }
        let registry = AgentMCPRegistry(home: home)
        switch subcommand {
        case "list":
            for server in try registry.list() {
                print("\(server.name) [\(server.transport.rawValue)] \(server.enabled ? "enabled" : "disabled")")
            }
        case "add":
            let name = try requiredArgument(arguments, index: 1, usage: "ashex mcp add <name> --transport <stdio|http> [--command CMD|--url URL]")
            let options = parseOptions(Array(arguments.dropFirst(2)))
            let transport = AgentMCPTransport(rawValue: options["transport"] ?? "stdio") ?? .stdio
            try registry.upsert(.init(
                name: name,
                transport: transport,
                command: options["command"],
                args: options["args"]?.split(separator: ",").map(String.init) ?? [],
                url: options["url"],
                enabled: options["enabled"] != "false",
                allowTools: options["allow-tools"]?.split(separator: ",").map(String.init) ?? [],
                denyTools: options["deny-tools"]?.split(separator: ",").map(String.init) ?? []
            ))
            print("Saved MCP server \(name).")
        case "remove":
            try registry.remove(name: requiredArgument(arguments, index: 1, usage: "ashex mcp remove <server>"))
            print("Removed MCP server.")
        case "reload":
            let config = try registry.discoveryConfig()
            let enabledCount = config.servers.filter(\.enabled).count
            print("Reloaded MCP server config: \(config.servers.count) server(s), \(enabledCount) enabled for discovery.")
        case "tools", "resources", "prompts":
            let name = try requiredArgument(arguments, index: 1, usage: "ashex mcp \(subcommand) <server>")
            guard try registry.list().contains(where: { $0.name == name }) else {
                throw AshexError.model("No MCP server named \(name)")
            }
            let config = try registry.discoveryConfig()
            let server = try requireMCPServer(named: name, in: config)
            let kind = try mcpListKind(subcommand)
            let items = try await AgentMCPLiveDiscovery().listItems(for: server, kind: kind)
            if items.isEmpty {
                print("No MCP \(subcommand) reported by \(name).")
            } else {
                for item in items {
                    let detail = [item.title, item.description, item.uri, item.mimeType]
                        .compactMap { $0?.nilIfBlank }
                        .joined(separator: " - ")
                    print(detail.isEmpty ? item.name : "\(item.name) - \(detail)")
                }
            }
        case "call":
            let serverName = try requiredArgument(arguments, index: 1, usage: "ashex mcp call <server> <tool> [--json OBJECT]")
            let toolName = try requiredArgument(arguments, index: 2, usage: "ashex mcp call <server> <tool> [--json OBJECT]")
            let parsed = parseOptionValuesAndPositionals(Array(arguments.dropFirst(3)))
            let object = try parseJSONObject(parsed.options["json"])
            let server = try requireMCPServer(named: serverName, in: registry.discoveryConfig())
            let result = try await AgentMCPLiveToolCaller().callTool(server: server, toolName: toolName, arguments: object)
            print("\(result.serverID)/\(result.toolName) \(result.isError ? "error" : "ok")")
            print(JSONValue.object(result.result).prettyPrinted)
        case "serve":
            try await runMCPStdioServer(configuration: configuration)
        default:
            throw AshexError.model("Usage: ashex mcp <list|add|remove|reload|tools|resources|prompts|call|serve>")
        }
    }

    private static func handleKB(_ arguments: [String], home: AgentHome) throws {
        let subcommand = arguments.first ?? "status"
        let kb = AgentKnowledgeBase(home: home)
        switch subcommand {
        case "init":
            let report = try kb.initialize()
            print(report.createdPaths.isEmpty ? "Knowledge base already exists." : "Created:\n" + report.createdPaths.joined(separator: "\n"))
        case "add":
            let path = try requiredArgument(arguments, index: 1, usage: "ashex kb add <file-or-dir>")
            let report = try kb.add(URL(fileURLWithPath: path, relativeTo: home.workspaceRoot))
            print("Ingested \(report.ingestedCount) source page(s).")
        case "query":
            let query = arguments.dropFirst().joined(separator: " ")
            guard !query.isEmpty else { throw AshexError.model("Usage: ashex kb query <question>") }
            for result in try kb.query(query) {
                print("\(result.path): \(result.snippet)")
            }
        case "lint":
            let report = try kb.lint()
            print("Missing source pages: \(report.missingSourcePages.count)")
            print("Orphan pages: \(report.orphanPages.count)")
        case "list":
            for path in try listMarkdownFiles(home.paths.kbWikiDirectory, home: home) {
                print(path)
            }
        case "status":
            print("KB root: \(home.paths.kbRootDirectory.path)")
            print("Wiki pages: \(try listMarkdownFiles(home.paths.kbWikiDirectory, home: home).count)")
        case "save-exploration":
            let name = try requiredArgument(arguments, index: 1, usage: "ashex kb save-exploration <name> <text>")
            let text = arguments.dropFirst(2).joined(separator: " ")
            try saveExploration(name: name, text: text, home: home)
            print("Saved exploration \(name).")
        case "chat":
            let query = arguments.dropFirst().joined(separator: " ")
            guard !query.isEmpty else { throw AshexError.model("Usage: ashex kb chat <question>") }
            let results = try kb.query(query, limit: 5)
            if results.isEmpty {
                print("No KB matches for: \(query)")
            } else {
                print("KB retrieval answer for: \(query)")
                for result in results {
                    print("- \(result.path): \(result.snippet)")
                }
            }
        case "watch":
            let watch = try parseKBWatchArguments(Array(arguments.dropFirst()), workspaceRoot: home.workspaceRoot)
            repeat {
                let report = try kb.watch(watch.url)
                print("Scanned \(report.scannedCount) file(s), ingested \(report.ingestReport.ingestedCount) changed source page(s).")
                if watch.once { break }
                Thread.sleep(forTimeInterval: watch.interval)
            } while true
        default:
            throw AshexError.model("Usage: ashex kb <init|add|query|chat|watch|lint|list|status|save-exploration>")
        }
    }

    private static func handleSessions(_ arguments: [String], home: AgentHome, configuration: CLIConfiguration) throws {
        guard let subcommand = arguments.first else {
            throw AshexError.model("Usage: ashex sessions <search|summary|transcript>")
        }
        let transcriptStore = SessionTranscriptStore(directoryURL: home.paths.sessionsDirectory)
        switch subcommand {
        case "search":
            let parsed = parseOptionValuesAndPositionals(Array(arguments.dropFirst()))
            let query = parsed.positionals.joined(separator: " ")
            guard !query.isEmpty else { throw AshexError.model("Usage: ashex sessions search <query> [--limit N]") }
            let limit = Int(parsed.options["limit"] ?? "") ?? 20
            let threadID = parsed.options["thread"].flatMap(UUID.init(uuidString:))
            let runID = parsed.options["run"].flatMap(UUID.init(uuidString:))
            let request = SessionSearchRequest(query: query, limit: limit, threadID: threadID, runID: runID)
            _ = try configuration.makePersistenceStore()
            let search = SessionSearchStore(databaseURL: configuration.storageRoot.appendingPathComponent("ashex.sqlite"))
            try search.initialize()
            for result in try search.search(request) {
                print("\(result.kind.rawValue) \(result.createdAt): \(result.snippet)")
            }
            let transcriptRequest = SessionTranscriptSearchRequest(query: query, limit: limit, threadID: threadID, runID: runID)
            for result in try transcriptStore.search(transcriptRequest) {
                print("transcript \(result.entry.kind.rawValue) \(result.entry.createdAt): \(result.snippet)")
            }
        case "summary":
            let threadID = arguments.dropFirst().first.flatMap(UUID.init(uuidString:))
            let entries = try threadID.map { try transcriptStore.read(threadID: $0) } ?? transcriptStore.readAll()
            let summary = SessionSummarizer.summarize(entries: entries)
            print(summary.title)
            for bullet in summary.bullets {
                print("- \(bullet)")
            }
        case "transcript":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex sessions transcript <thread-id>")
            let threadID = try parseUUID(id, label: "thread-id")
            for entry in try transcriptStore.read(threadID: threadID) {
                switch entry.kind {
                case .message:
                    print("\(entry.createdAt) \(entry.message?.role.rawValue ?? "message"): \(entry.message?.content ?? "")")
                case .toolCall:
                    print("\(entry.createdAt) tool \(entry.toolCall?.toolName ?? "unknown"): \(entry.toolCall?.status ?? "")")
                }
            }
        default:
            throw AshexError.model("Usage: ashex sessions <search|summary|transcript>")
        }
    }

    private static func handleTasks(_ arguments: [String], home: AgentHome) throws {
        guard let subcommand = arguments.first else {
            throw AshexError.model("Usage: ashex tasks <new|list|claim|done|fail|retry|logs|heartbeat|requeue-stale>")
        }
        let queue = AgentTaskQueue(storageRoot: home.storageRoot)
        switch subcommand {
        case "new":
            let parsed = parseOptionValuesAndPositionals(Array(arguments.dropFirst()))
            let prompt = parsed.positionals.joined(separator: " ")
            guard !prompt.isEmpty else { throw AshexError.model("Usage: ashex tasks new [--id ID] [--plan TEXT] <prompt>") }
            let task = try queue.new(prompt: prompt, plan: parsed.options["plan"] ?? "", id: parsed.options["id"] ?? UUID().uuidString)
            print("\(task.id) \(task.status.rawValue)")
        case "list":
            for task in try queue.list() {
                print("\(task.id) \(task.status.rawValue) attempt=\(task.attempt) claimedBy=\(task.claimedBy ?? "-")")
            }
        case "claim":
            let workerID = arguments.dropFirst().first ?? "cli"
            if let task = try queue.claimNext(workerID: workerID) {
                print("\(task.id) claimed by \(workerID)")
            } else {
                print("No queued tasks.")
            }
        case "done":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex tasks done <id> [result]")
            let result = blankToNil(arguments.dropFirst(2).joined(separator: " "))
            let task = try queue.done(id: id, result: result)
            print("\(task.id) \(task.status.rawValue)")
        case "fail":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex tasks fail <id> [reason]")
            let reason = blankToNil(arguments.dropFirst(2).joined(separator: " "))
            let task = try queue.fail(id: id, reason: reason)
            print("\(task.id) \(task.status.rawValue)")
        case "retry":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex tasks retry <id>")
            let task = try queue.retry(id: id)
            print("\(task.id) \(task.status.rawValue) attempt=\(task.attempt)")
        case "logs":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex tasks logs <id>")
            for entry in try queue.logs(taskID: id) {
                print("\(entry.timestamp) [\(entry.level.rawValue)] \(entry.message)")
            }
        case "heartbeat":
            let heartbeat = AgentHeartbeatStore(storageRoot: home.storageRoot)
            for action in try heartbeat.actions(for: queue.list()) {
                switch action {
                case let .markTaskStale(taskID, lastHeartbeatAt, staleAfter):
                    print("\(taskID) staleAfter=\(staleAfter) lastHeartbeat=\(lastHeartbeatAt?.description ?? "missing")")
                }
            }
        case "requeue-stale":
            let heartbeat = AgentHeartbeatStore(storageRoot: home.storageRoot)
            for task in try heartbeat.requeueStaleRunningTasks(in: queue) {
                print("\(task.id) requeued attempt=\(task.attempt)")
            }
        default:
            throw AshexError.model("Usage: ashex tasks <new|list|claim|done|fail|retry|logs|heartbeat|requeue-stale>")
        }
    }

    private static func handleProcesses(_ arguments: [String], home: AgentHome) throws {
        guard let subcommand = arguments.first else {
            throw AshexError.model("Usage: ashex processes <register|list|poll|wait|kill|log|writes|write>")
        }
        let manager = AgentProcessManager(storageRoot: home.storageRoot)
        switch subcommand {
        case "register":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex processes register <id> <cwd> <command...>")
            let cwd = try requiredArgument(arguments, index: 2, usage: "ashex processes register <id> <cwd> <command...>")
            let command = Array(arguments.dropFirst(3))
            guard !command.isEmpty else { throw AshexError.model("Usage: ashex processes register <id> <cwd> <command...>") }
            let process = try manager.register(command: command, workingDirectory: cwd, id: id)
            print("\(process.id) \(process.status.rawValue)")
        case "list":
            for process in try manager.list() {
                print("\(process.id) \(process.status.rawValue) polls=\(process.pollCount) cwd=\(process.workingDirectory)")
            }
        case "poll":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex processes poll <id>")
            let process = try manager.poll(processID: id)
            printProcessStatus(process)
        case "wait":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex processes wait <id> [max-polls]")
            let maxPolls = Int(arguments.dropFirst(2).first ?? "") ?? 60
            let process = try manager.wait(processID: id, maxPolls: maxPolls)
            printProcessStatus(process)
        case "kill":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex processes kill <id>")
            let process = try manager.kill(processID: id)
            printProcessStatus(process)
        case "log":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex processes log <id>")
            for entry in try manager.log(processID: id) {
                print("\(entry.timestamp) [\(entry.stream.rawValue)] \(entry.text)")
            }
        case "writes":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex processes writes <id>")
            for entry in try manager.writes(processID: id) {
                print("\(entry.timestamp) \(entry.text)")
            }
        case "write":
            let id = try requiredArgument(arguments, index: 1, usage: "ashex processes write <id> <text>")
            let text = arguments.dropFirst(2).joined(separator: " ")
            guard !text.isEmpty else { throw AshexError.model("Usage: ashex processes write <id> <text>") }
            try manager.write(processID: id, text: text)
            print("Wrote stdin record for \(id).")
        default:
            throw AshexError.model("Usage: ashex processes <register|list|poll|wait|kill|log|writes|write>")
        }
    }

    private static func handleLearnings(_ arguments: [String], home: AgentHome) throws {
        let subcommand = arguments.first ?? "list"
        let store = ProjectLearningStore(workspaceRoot: home.workspaceRoot)
        switch subcommand {
        case "init":
            try store.initialize()
            print("Initialized learning logs.")
        case "list":
            let kind = try arguments.dropFirst().first.map(parseLearningKind)
            for entry in try store.list(kind: kind) {
                print("\(entry.kind.rawValue) \(entry.id): \(entry.summary)")
            }
        case "add":
            let kind = try parseLearningKind(try requiredArgument(arguments, index: 1, usage: "ashex learnings add <kind> <summary> [details]"))
            let summary = try requiredArgument(arguments, index: 2, usage: "ashex learnings add <kind> <summary> [details]")
            let details = arguments.dropFirst(3).joined(separator: " ")
            let entry = ProjectLearningEntry(
                id: UUID().uuidString,
                kind: kind,
                summary: summary,
                details: details.isEmpty ? summary : details,
                source: "ashex-cli"
            )
            try store.append(entry)
            print("Added \(kind.rawValue) \(entry.id).")
        default:
            throw AshexError.model("Usage: ashex learnings <init|list|add>")
        }
    }

    private static func handleRoutes(_ arguments: [String], configuration: CLIConfiguration) throws {
        let subcommand = arguments.first ?? "show"
        guard subcommand == "show" else {
            throw AshexError.model("Usage: ashex routes show")
        }
        let routing = defaultModelRoutingConfig(configuration: configuration)
        for purpose in ModelTaskPurpose.allCases {
            let slot = routing.slot(for: purpose)
            let route = routing.route(for: purpose)
            let endpoint = route.endpoint.map { " @ \($0.absoluteString)" } ?? ""
            print("\(purpose.rawValue): \(slot.rawValue) -> \(route.provider)/\(route.model)\(endpoint)")
        }
    }

    private static func handleRPC(_ arguments: [String], configuration: CLIConfiguration) async throws {
        guard let subcommand = arguments.first else {
            throw AshexError.model("Usage: ashex rpc <list-tools|call|serve>")
        }
        let server = try makeRPCServer(configuration: configuration)
        switch subcommand {
        case "list-tools":
            let response = try await server.handle(.listTools(id: "cli-list-tools"))
            for spec in response.result?.tools ?? [] {
                print("\(spec.name): \(spec.description)")
            }
        case "call":
            let toolName = try requiredArgument(arguments, index: 1, usage: "ashex rpc call <tool-name> [--json OBJECT]")
            let parsed = parseOptionValuesAndPositionals(Array(arguments.dropFirst(2)))
            let object = try parseJSONObject(parsed.options["json"])
            let response = try await server.handle(.callTool(id: "cli-call-tool", toolName: toolName, arguments: object))
            if let error = response.error {
                throw AshexError.model("\(error.code): \(error.message)")
            }
            guard let result = response.result?.toolCall else {
                throw AshexError.model("RPC call returned no tool result")
            }
            print("\(result.toolName) \(result.status.rawValue): \(result.policyDecision.reason)")
            if let content = result.content {
                print(content.displayText)
            }
        case "serve":
            try await runRPCStdioServer(server: server)
        default:
            throw AshexError.model("Usage: ashex rpc <list-tools|call|serve>")
        }
    }

    private static func handleDoctor(home: AgentHome, configuration: CLIConfiguration) throws {
        let context = try AgentContextLoader(home: home).loadContext()
        let skills = try AgentSkillStore(home: home).list()
        let mcpServers = try AgentMCPRegistry(home: home).list()
        let kbLint = try AgentKnowledgeBase(home: home).lint()
        print("ASHEX doctor")
        print("Workspace: \(configuration.workspaceRoot.path)")
        print("Storage: \(configuration.storageRoot.path)")
        print("Config: \(configuration.userConfigFile.path)")
        print("Context files: \(context.files.count)")
        print("Context warnings: \(context.warnings.count)")
        print("Skills: \(skills.count)")
        print("MCP servers: \(mcpServers.count)")
        print("KB missing sources: \(kbLint.missingSourcePages.count)")
        print("SQLite store: \(configuration.storageRoot.appendingPathComponent("ashex.sqlite").path)")
    }

    private static func makeRuntimeToolRegistry(configuration: CLIConfiguration) throws -> ToolRegistry {
        let persistence = try configuration.makePersistenceStore()
        let tools = try configuration.makeRuntimeTools(
            workspaceURL: configuration.workspaceRoot.standardizedFileURL,
            storageRoot: configuration.storageRoot,
            persistence: persistence,
            userConfig: configuration.userConfig,
            shellExecutionPolicy: configuration.makeShellExecutionPolicy()
        )
        return ToolRegistry(tools: tools)
    }

    private static func makeRPCServer(configuration: CLIConfiguration) throws -> AgentRPCServer {
        AgentRPCServer(registry: try makeRuntimeToolRegistry(configuration: configuration), policy: AgentRPCStaticPolicy())
    }

    private static func runRPCStdioServer(server: AgentRPCServer) async throws {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                let request = try JSONDecoder().decode(AgentRPCRequest.self, from: Data(trimmed.utf8))
                try printJSON(try await server.handle(request))
            } catch {
                try printJSON(AgentRPCResponse(
                    id: "unknown",
                    error: .init(code: "invalid_request", message: error.localizedDescription)
                ))
            }
        }
    }

    private static func runMCPStdioServer(configuration: CLIConfiguration) async throws {
        let registry = try makeRuntimeToolRegistry(configuration: configuration)
        let server = AgentRPCServer(registry: registry, policy: AgentRPCStaticPolicy())
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let object: JSONObject
            do {
                object = try decodeJSONObjectLine(trimmed)
            } catch {
                try printJSON(jsonRPCError(id: .null, code: -32700, message: error.localizedDescription))
                continue
            }

            guard let method = object["method"]?.stringValue else {
                try printJSON(jsonRPCError(id: object["id"] ?? .null, code: -32600, message: "Missing method"))
                continue
            }
            guard let id = object["id"] else {
                continue
            }

            do {
                switch method {
                case "initialize":
                    try printJSON(jsonRPCResponse(id: id, result: [
                        "protocolVersion": .string("2025-06-18"),
                        "capabilities": .object([
                            "tools": .object(["listChanged": .bool(false)]),
                        ]),
                        "serverInfo": .object([
                            "name": .string("ashex"),
                            "version": .string(AppBuildInfo.current.version),
                        ]),
                    ]))
                case "ping":
                    try printJSON(jsonRPCResponse(id: id, result: [:]))
                case "tools/list":
                    try printJSON(jsonRPCResponse(id: id, result: [
                        "tools": .array(registry.specs().map(mcpToolJSON)),
                    ]))
                case "tools/call":
                    let params = object["params"]?.objectValue ?? [:]
                    guard let name = params["name"]?.stringValue?.nilIfBlank else {
                        throw AshexError.model("tools/call requires params.name")
                    }
                    let arguments = params["arguments"]?.objectValue ?? [:]
                    let response = try await server.handle(.callTool(
                        id: jsonRPCIDString(id),
                        toolName: name,
                        arguments: arguments
                    ))
                    if let error = response.error {
                        try printJSON(jsonRPCError(id: id, code: -32000, message: error.message))
                    } else if let call = response.result?.toolCall {
                        try printJSON(jsonRPCResponse(id: id, result: mcpToolCallResult(call)))
                    } else {
                        try printJSON(jsonRPCError(id: id, code: -32000, message: "Tool call returned no result"))
                    }
                default:
                    try printJSON(jsonRPCError(id: id, code: -32601, message: "Unknown MCP method: \(method)"))
                }
            } catch {
                try printJSON(jsonRPCError(id: id, code: -32000, message: error.localizedDescription))
            }
        }
    }

    private static func parseMemoryScope(_ raw: String?) throws -> AgentMemoryScope {
        guard let raw else { throw AshexError.model("Missing memory scope") }
        if raw == "memory" { return .agent }
        guard let scope = AgentMemoryScope(rawValue: raw) else {
            throw AshexError.model("Unknown memory scope '\(raw)'. Supported: memory, \(AgentMemoryScope.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return scope
    }

    private static func requiredArgument(_ arguments: [String], index: Int, usage: String) throws -> String {
        guard arguments.indices.contains(index), !arguments[index].isEmpty else {
            throw AshexError.model("Usage: \(usage)")
        }
        return arguments[index]
    }

    private static func parseOptions(_ arguments: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            guard argument.hasPrefix("--") else { continue }
            let key = String(argument.dropFirst(2))
            result[key] = iterator.next() ?? "true"
        }
        return result
    }

    private static func parseOptionValuesAndPositionals(_ arguments: [String]) -> (options: [String: String], positionals: [String]) {
        var options: [String: String] = [:]
        var positionals: [String] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument.hasPrefix("--") {
                let key = String(argument.dropFirst(2))
                if let value = iterator.next() {
                    if value.hasPrefix("--") {
                        options[key] = "true"
                        positionals.append(value)
                    } else {
                        options[key] = value
                    }
                } else {
                    options[key] = "true"
                }
            } else {
                positionals.append(argument)
            }
        }
        return (options, positionals)
    }

    private static func parseUUID(_ raw: String, label: String) throws -> UUID {
        guard let uuid = UUID(uuidString: raw) else {
            throw AshexError.model("Invalid \(label): \(raw)")
        }
        return uuid
    }

    private static func parseLearningKind(_ raw: String) throws -> ProjectLearningKind {
        guard let kind = ProjectLearningKind(rawValue: raw) else {
            throw AshexError.model("Unknown learning kind '\(raw)'. Supported: \(ProjectLearningKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return kind
    }

    private static func parseJSONObject(_ raw: String?) throws -> JSONObject {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        guard case .object(let object) = value else {
            throw AshexError.model("--json must be a JSON object")
        }
        return object
    }

    private static func decodeJSONObjectLine(_ line: String) throws -> JSONObject {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        guard let object = value.objectValue else {
            throw AshexError.model("Expected a JSON object")
        }
        return object
    }

    private static func mcpListKind(_ raw: String) throws -> AgentMCPListKind {
        guard let kind = AgentMCPListKind(rawValue: raw) else {
            throw AshexError.model("Unknown MCP list kind: \(raw)")
        }
        return kind
    }

    private static func requireMCPServer(named name: String, in config: AgentMCPConfig) throws -> AgentMCPServerDescriptor {
        guard let server = config.servers.first(where: { $0.id == name }) else {
            throw AshexError.model("No MCP server named \(name)")
        }
        return server
    }

    private struct KBWatchArguments {
        let url: URL
        let once: Bool
        let interval: TimeInterval
    }

    private static func parseKBWatchArguments(_ arguments: [String], workspaceRoot: URL) throws -> KBWatchArguments {
        var once = false
        var interval: TimeInterval = 5
        var path: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--once":
                once = true
            case "--interval":
                index += 1
                guard index < arguments.count, let parsed = TimeInterval(arguments[index]), parsed > 0 else {
                    throw AshexError.model("Usage: ashex kb watch [file-or-dir] [--once] [--interval seconds]")
                }
                interval = parsed
            default:
                if argument.hasPrefix("--") {
                    throw AshexError.model("Unknown kb watch option: \(argument)")
                }
                path = argument
            }
            index += 1
        }
        return .init(
            url: URL(fileURLWithPath: path ?? workspaceRoot.path, relativeTo: workspaceRoot),
            once: once,
            interval: interval
        )
    }

    private static func mcpToolJSON(_ spec: ToolSpec) -> JSONValue {
        .object([
            "name": .string(spec.name),
            "description": .string(spec.description),
            "inputSchema": spec.inputSchema,
        ])
    }

    private static func mcpToolCallResult(_ call: AgentRPCToolCallResult) -> JSONObject {
        var result: JSONObject = [
            "isError": .bool(call.status == .denied),
        ]
        if let content = call.content {
            switch content {
            case .text(let text):
                result["content"] = .array([.object(["type": .string("text"), "text": .string(text)])])
            case .structured(let value):
                result["structuredContent"] = value
                result["content"] = .array([.object(["type": .string("text"), "text": .string(value.prettyPrinted)])])
            }
        } else {
            result["content"] = .array([
                .object([
                    "type": .string("text"),
                    "text": .string(call.policyDecision.reason),
                ]),
            ])
        }
        return result
    }

    private static func jsonRPCResponse(id: JSONValue, result: JSONObject) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "result": .object(result),
        ])
    }

    private static func jsonRPCError(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(Double(code)),
                "message": .string(message),
            ]),
        ])
    }

    private static func jsonRPCIDString(_ id: JSONValue) -> String {
        switch id {
        case .string(let value): return value
        case .number(let value): return String(Int(value))
        case .bool(let value): return String(value)
        default: return "request"
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func printProcessStatus(_ process: AgentManagedProcess) {
        let exit = process.exitCode.map { " exit=\($0)" } ?? ""
        let failure = process.failureReason.map { " failure=\($0)" } ?? ""
        print("\(process.id) \(process.status.rawValue)\(exit)\(failure)")
    }

    private static func defaultModelRoutingConfig(configuration: CLIConfiguration) -> ModelRoutingConfig {
        let audio = configuration.userConfig.audio.resolvedModel(chatProvider: configuration.provider, chatModel: configuration.model)
        return ModelRoutingConfig(
            fast: ModelRoute(provider: configuration.provider, model: configuration.model),
            reasoning: ModelRoute(provider: configuration.provider, model: configuration.model),
            local: ModelRoute(provider: "ollama", model: CLIConfiguration.defaultModel(for: "ollama")),
            vision: ModelRoute(provider: configuration.provider, model: configuration.model),
            audio: ModelRoute(provider: audio.provider, model: audio.model),
            purposeRoutes: [
                .skillAmendment: .local,
                .audioTranscription: .audio,
                .visionUnderstanding: .vision,
            ]
        )
    }

    private static func blankToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripGlobalOptions(_ arguments: [String]) -> [String] {
        let optionsWithValues: Set<String> = ["--workspace", "--storage", "--provider", "--model", "--max-iterations", "--approval-mode"]
        let flags: Set<String> = ["--select", "--onboarding", "--help", "-h", "--version", "-v"]
        var result: [String] = []
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if optionsWithValues.contains(argument) {
                _ = iterator.next()
                continue
            }
            if flags.contains(argument) {
                continue
            }
            result.append(argument)
        }
        return result
    }

    private static func quarantineSkill(name: String, store: AgentSkillStore) throws {
        let installed = store.directory(for: .installed).appendingPathComponent(name, isDirectory: true)
        let quarantined = store.directory(for: .quarantined).appendingPathComponent(name, isDirectory: true)
        guard FileManager.default.fileExists(atPath: installed.path) else {
            throw AshexError.fileSystem("No installed skill named \(name)")
        }
        if FileManager.default.fileExists(atPath: quarantined.path) {
            try FileManager.default.removeItem(at: quarantined)
        }
        try FileManager.default.moveItem(at: installed, to: quarantined)
    }

    private static func createGeneratedSkill(name: String, home: AgentHome) throws {
        let directory = home.paths.skillsGeneratedDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let skillFile = directory.appendingPathComponent("SKILL.md")
        guard !FileManager.default.fileExists(atPath: skillFile.path) else { return }
        try """
        ---
        name: \(name)
        description: Draft generated ASHEX skill
        version: 0.1.0
        tags: generated
        ---

        # \(name)

        Draft skill. Review and audit before enabling.
        """.write(to: skillFile, atomically: true, encoding: .utf8)
    }

    private static func listMarkdownFiles(_ root: URL, home: AgentHome) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        return enumerator.compactMap { entry -> String? in
            guard let url = entry as? URL,
                  url.pathExtension == "md",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return nil }
            return home.paths.displayPath(for: url)
        }
        .sorted()
    }

    private static func saveExploration(name: String, text: String, home: AgentHome) throws {
        try AgentKnowledgeBase(home: home).initialize()
        let safeName = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "-")
        let url = home.paths.kbWikiExplorationsDirectory.appendingPathComponent("\(safeName).md")
        try """
        # \(name)

        \(text)
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func openEditorOrPrintPath(_ url: URL) throws {
        guard let editor = ProcessInfo.processInfo.environment["EDITOR"], !editor.isEmpty else {
            print(url.path)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: editor)
        process.arguments = [url.path]
        try process.run()
        process.waitUntilExit()
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
