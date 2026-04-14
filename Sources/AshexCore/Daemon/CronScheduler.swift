import Foundation

public actor CronScheduler {
    private let store: CronJobStore
    private let dispatcher: RunDispatcher
    private let persistence: PersistenceStore
    private let logger: DaemonLogger?
    private let maxIterations: Int
    private var loopTask: Task<Void, Never>?
    private var activeJobIDs: Set<String> = []

    public init(
        store: CronJobStore,
        dispatcher: RunDispatcher,
        persistence: PersistenceStore,
        logger: DaemonLogger? = nil,
        maxIterations: Int = 8
    ) {
        self.store = store
        self.dispatcher = dispatcher
        self.persistence = persistence
        self.logger = logger
        self.maxIterations = maxIterations
    }

    public func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            do {
                try await runDueJobs(now: Date())
                try await Task.sleep(nanoseconds: 15_000_000_000)
            } catch is CancellationError {
                return
            } catch {
                await logger?.log(.error, subsystem: "cron", message: "Cron scheduler loop failed", metadata: [
                    "error": .string(error.localizedDescription),
                ])
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func runDueJobs(now: Date) async throws {
        let jobs = try store.listJobs()
        for job in jobs where job.isEnabled && job.nextRunAt <= now {
            guard !activeJobIDs.contains(job.id) else { continue }
            activeJobIDs.insert(job.id)
            Task {
                await self.execute(jobID: job.id)
            }
        }
    }

    private func execute(jobID: String) async {
        defer { activeJobIDs.remove(jobID) }
        do {
            guard let job = try store.job(id: jobID), job.isEnabled else { return }
            let threadID = try job.threadID ?? persistence.createThread(now: Date()).id
            let nextRunAt = try job.schedule.nextRunDate(after: Date())
            try store.save(job.updatedForScheduling(lastRunAt: Date(), nextRunAt: nextRunAt, threadID: threadID))
            await logger?.log(.info, subsystem: "cron", message: "Running cron job", metadata: [
                "job_id": .string(job.id),
                "timezone": .string(job.schedule.timeZoneIdentifier),
                "next_run_at": .string(ISO8601DateFormatter().string(from: nextRunAt)),
            ])
            _ = try await dispatcher.dispatch(
                prompt: job.prompt,
                threadID: threadID,
                maxIterations: maxIterations,
                mode: .agent
            )
        } catch {
            await logger?.log(.error, subsystem: "cron", message: "Cron job failed", metadata: [
                "job_id": .string(jobID),
                "error": .string(error.localizedDescription),
            ])
        }
    }
}
