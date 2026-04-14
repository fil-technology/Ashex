import Foundation

public struct CronSchedule: Codable, Sendable, Equatable {
    public let expression: String
    public let timeZoneIdentifier: String

    public init(expression: String, timeZoneIdentifier: String) {
        self.expression = expression
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var timeZone: TimeZone? {
        TimeZone(identifier: timeZoneIdentifier)
    }

    public func nextRunDate(after date: Date) throws -> Date {
        guard let timeZone else {
            throw AshexError.model("Unknown timezone: \(timeZoneIdentifier)")
        }
        let parsed = try CronExpression(expression: expression)
        return try parsed.nextDate(after: date, timeZone: timeZone)
    }
}

public struct CronJobRecord: Codable, Sendable, Equatable {
    public let id: String
    public let prompt: String
    public let schedule: CronSchedule
    public let createdAt: Date
    public let isEnabled: Bool
    public let lastRunAt: Date?
    public let nextRunAt: Date
    public let threadID: UUID?

    public init(
        id: String,
        prompt: String,
        schedule: CronSchedule,
        createdAt: Date,
        isEnabled: Bool = true,
        lastRunAt: Date? = nil,
        nextRunAt: Date,
        threadID: UUID? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.schedule = schedule
        self.createdAt = createdAt
        self.isEnabled = isEnabled
        self.lastRunAt = lastRunAt
        self.nextRunAt = nextRunAt
        self.threadID = threadID
    }

    public func updatedForScheduling(lastRunAt: Date, nextRunAt: Date, threadID: UUID?) -> CronJobRecord {
        CronJobRecord(
            id: id,
            prompt: prompt,
            schedule: schedule,
            createdAt: createdAt,
            isEnabled: isEnabled,
            lastRunAt: lastRunAt,
            nextRunAt: nextRunAt,
            threadID: threadID
        )
    }

    public func settingValue() -> JSONValue {
        .object([
            "id": .string(id),
            "prompt": .string(prompt),
            "expression": .string(schedule.expression),
            "timezone": .string(schedule.timeZoneIdentifier),
            "created_at": .string(ISO8601DateFormatter().string(from: createdAt)),
            "is_enabled": .bool(isEnabled),
            "last_run_at": lastRunAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            "next_run_at": .string(ISO8601DateFormatter().string(from: nextRunAt)),
            "thread_id": threadID.map { .string($0.uuidString) } ?? .null,
        ])
    }

    public static func from(settingValue: JSONValue) throws -> CronJobRecord {
        guard let object = settingValue.objectValue else {
            throw AshexError.model("Cron job payload is not an object")
        }
        let formatter = ISO8601DateFormatter()

        guard
            let id = object["id"]?.stringValue,
            let prompt = object["prompt"]?.stringValue,
            let expression = object["expression"]?.stringValue,
            let timeZoneIdentifier = object["timezone"]?.stringValue,
            let createdAtString = object["created_at"]?.stringValue,
            let createdAt = formatter.date(from: createdAtString),
            let nextRunAtString = object["next_run_at"]?.stringValue,
            let nextRunAt = formatter.date(from: nextRunAtString)
        else {
            throw AshexError.model("Cron job payload is missing required fields")
        }

        let lastRunAt = object["last_run_at"]?.stringValue.flatMap(formatter.date(from:))
        let threadID = object["thread_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        return CronJobRecord(
            id: id,
            prompt: prompt,
            schedule: .init(expression: expression, timeZoneIdentifier: timeZoneIdentifier),
            createdAt: createdAt,
            isEnabled: object["is_enabled"]?.boolValue ?? true,
            lastRunAt: lastRunAt,
            nextRunAt: nextRunAt,
            threadID: threadID
        )
    }
}

public struct CronJobStore: Sendable {
    public static let namespace = "cron.jobs"

    private let persistence: PersistenceStore

    public init(persistence: PersistenceStore) {
        self.persistence = persistence
    }

    public func listJobs() throws -> [CronJobRecord] {
        try persistence.listSettings(namespace: Self.namespace)
            .compactMap { setting in
                try? CronJobRecord.from(settingValue: setting.value)
            }
            .sorted { lhs, rhs in
                if lhs.nextRunAt == rhs.nextRunAt {
                    return lhs.id < rhs.id
                }
                return lhs.nextRunAt < rhs.nextRunAt
            }
    }

    public func job(id: String) throws -> CronJobRecord? {
        guard let setting = try persistence.fetchSetting(namespace: Self.namespace, key: id) else {
            return nil
        }
        return try CronJobRecord.from(settingValue: setting.value)
    }

    public func save(_ job: CronJobRecord, now: Date = Date()) throws {
        try persistence.upsertSetting(namespace: Self.namespace, key: job.id, value: job.settingValue(), now: now)
    }

    public func remove(id: String) throws {
        try persistence.upsertSetting(namespace: Self.namespace, key: id, value: .null, now: Date())
    }

    public func delete(id: String) throws {
        try persistence.upsertSetting(namespace: Self.namespace, key: id, value: .null, now: Date())
    }
}

private struct CronExpression: Sendable, Equatable {
    private let minutes: Set<Int>
    private let hours: Set<Int>
    private let daysOfMonth: Set<Int>
    private let months: Set<Int>
    private let weekdays: Set<Int>

    init(expression: String) throws {
        let parts = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard parts.count == 5 else {
            throw AshexError.model("Cron expression must have 5 fields: minute hour day month weekday")
        }
        minutes = try Self.parseField(parts[0], min: 0, max: 59)
        hours = try Self.parseField(parts[1], min: 0, max: 23)
        daysOfMonth = try Self.parseField(parts[2], min: 1, max: 31)
        months = try Self.parseField(parts[3], min: 1, max: 12)
        weekdays = Set(try Self.parseField(parts[4], min: 0, max: 7).map { $0 == 7 ? 0 : $0 })
    }

    func nextDate(after date: Date, timeZone: TimeZone) throws -> Date {
        var candidate = Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / 60) + 1) * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        for _ in 0..<(366 * 24 * 60) {
            let components = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
            guard
                let minute = components.minute,
                let hour = components.hour,
                let day = components.day,
                let month = components.month,
                let weekday = components.weekday
            else {
                candidate = candidate.addingTimeInterval(60)
                continue
            }

            let cronWeekday = (weekday + 6) % 7
            if minutes.contains(minute),
               hours.contains(hour),
               daysOfMonth.contains(day),
               months.contains(month),
               weekdays.contains(cronWeekday) {
                return candidate
            }
            candidate = candidate.addingTimeInterval(60)
        }

        throw AshexError.model("Unable to compute next cron run within one year for expression")
    }

    private static func parseField(_ field: String, min: Int, max: Int) throws -> Set<Int> {
        if field == "*" {
            return Set(min...max)
        }

        var values: Set<Int> = []
        for rawSegment in field.split(separator: ",") {
            let segment = String(rawSegment)
            let stepParts = segment.split(separator: "/", maxSplits: 1).map(String.init)
            let base = stepParts[0]
            let step = stepParts.count == 2 ? Int(stepParts[1]) ?? -1 : 1
            guard step > 0 else {
                throw AshexError.model("Invalid cron step in field: \(field)")
            }

            let range: ClosedRange<Int>
            if base == "*" {
                range = min...max
            } else if let dashIndex = base.firstIndex(of: "-") {
                let startString = String(base[..<dashIndex])
                let endString = String(base[base.index(after: dashIndex)...])
                guard let start = Int(startString), let end = Int(endString), start <= end else {
                    throw AshexError.model("Invalid cron range in field: \(field)")
                }
                range = start...end
            } else {
                guard let exact = Int(base) else {
                    throw AshexError.model("Invalid cron value in field: \(field)")
                }
                range = exact...exact
            }

            for value in range where ((value - range.lowerBound) % step == 0) {
                guard value >= min && value <= max else {
                    throw AshexError.model("Cron field value out of range: \(value)")
                }
                values.insert(value)
            }
        }

        guard !values.isEmpty else {
            throw AshexError.model("Cron field produced no values: \(field)")
        }
        return values
    }
}
