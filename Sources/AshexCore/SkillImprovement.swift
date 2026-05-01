import Foundation

public enum SkillRunOutcome: String, Codable, Sendable {
    case success
    case failure
    case correction
}

public struct SkillRunObservation: Codable, Equatable, Sendable {
    public let id: String
    public let skillName: String
    public let taskFingerprint: String
    public let outcome: SkillRunOutcome
    public let issue: String?
    public let correction: String?
    public let requiredTools: [String]
    public let observedAt: Date

    public init(
        id: String,
        skillName: String,
        taskFingerprint: String,
        outcome: SkillRunOutcome,
        issue: String? = nil,
        correction: String? = nil,
        requiredTools: [String] = [],
        observedAt: Date = Date()
    ) {
        self.id = id
        self.skillName = skillName
        self.taskFingerprint = taskFingerprint
        self.outcome = outcome
        self.issue = issue
        self.correction = correction
        self.requiredTools = requiredTools
        self.observedAt = observedAt
    }
}

public struct SkillImprovementSignal: Equatable, Sendable {
    public let skillName: String
    public let issue: String
    public let count: Int
    public let observationIDs: [String]

    public init(skillName: String, issue: String, count: Int, observationIDs: [String]) {
        self.skillName = skillName
        self.issue = issue
        self.count = count
        self.observationIDs = observationIDs
    }
}

public enum SkillAmendmentStatus: String, Codable, Sendable {
    case proposed
    case promoted
    case rolledBack
    case rejected
}

public struct SkillAmendmentProposal: Codable, Equatable, Sendable {
    public let id: String
    public let skillName: String
    public let reason: String
    public let proposedPatch: String
    public let sourceObservationIDs: [String]
    public let status: SkillAmendmentStatus
    public let createdAt: Date
    public let promotedAt: Date?
    public let promotedSnapshotID: String?
    public let rolledBackAt: Date?
    public let rollbackSnapshotID: String?

    public init(
        id: String,
        skillName: String,
        reason: String,
        proposedPatch: String,
        sourceObservationIDs: [String] = [],
        status: SkillAmendmentStatus = .proposed,
        createdAt: Date = Date(),
        promotedAt: Date? = nil,
        promotedSnapshotID: String? = nil,
        rolledBackAt: Date? = nil,
        rollbackSnapshotID: String? = nil
    ) {
        self.id = id
        self.skillName = skillName
        self.reason = reason
        self.proposedPatch = proposedPatch
        self.sourceObservationIDs = sourceObservationIDs
        self.status = status
        self.createdAt = createdAt
        self.promotedAt = promotedAt
        self.promotedSnapshotID = promotedSnapshotID
        self.rolledBackAt = rolledBackAt
        self.rollbackSnapshotID = rollbackSnapshotID
    }

    func withPromotion(snapshotID: String, promotedAt: Date) -> SkillAmendmentProposal {
        SkillAmendmentProposal(
            id: id,
            skillName: skillName,
            reason: reason,
            proposedPatch: proposedPatch,
            sourceObservationIDs: sourceObservationIDs,
            status: .promoted,
            createdAt: createdAt,
            promotedAt: promotedAt,
            promotedSnapshotID: snapshotID,
            rolledBackAt: rolledBackAt,
            rollbackSnapshotID: rollbackSnapshotID
        )
    }

    func withRollback(snapshotID: String, rolledBackAt: Date) -> SkillAmendmentProposal {
        SkillAmendmentProposal(
            id: id,
            skillName: skillName,
            reason: reason,
            proposedPatch: proposedPatch,
            sourceObservationIDs: sourceObservationIDs,
            status: .rolledBack,
            createdAt: createdAt,
            promotedAt: promotedAt,
            promotedSnapshotID: promotedSnapshotID,
            rolledBackAt: rolledBackAt,
            rollbackSnapshotID: snapshotID
        )
    }
}

public struct SkillVersionSnapshot: Codable, Equatable, Sendable {
    public let skillName: String
    public let versionID: String
    public let contentHash: String
    public let content: String
    public let createdAt: Date

    public init(skillName: String, versionID: String, contentHash: String, content: String, createdAt: Date = Date()) {
        self.skillName = skillName
        self.versionID = versionID
        self.contentHash = contentHash
        self.content = content
        self.createdAt = createdAt
    }
}

public struct SkillImprovementStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public func record(_ observation: SkillRunObservation) throws {
        try appendJSONLine(observation, to: observationsURL)
    }

    public func observations(skillName: String? = nil) throws -> [SkillRunObservation] {
        try readJSONLines(SkillRunObservation.self, from: observationsURL)
            .filter { skillName == nil || $0.skillName == skillName }
            .sorted { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt }
    }

    public func repeatedIssueSignals(skillName: String? = nil, minimumCount: Int = 2) throws -> [SkillImprovementSignal] {
        let candidates = try observations(skillName: skillName).filter { $0.outcome == .failure || $0.outcome == .correction }
        let grouped = Dictionary(grouping: candidates) { observation in
            "\(observation.skillName)\u{1F}\(observation.issue ?? observation.correction ?? "")"
        }
        return grouped.compactMap { _, observations in
            guard
                observations.count >= minimumCount,
                let first = observations.first,
                let issue = first.issue ?? first.correction,
                !issue.isEmpty
            else {
                return nil
            }
            return SkillImprovementSignal(
                skillName: first.skillName,
                issue: issue,
                count: observations.count,
                observationIDs: observations.map(\.id).sorted()
            )
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs.skillName != rhs.skillName { return lhs.skillName < rhs.skillName }
            return lhs.issue < rhs.issue
        }
    }

    @discardableResult
    public func proposeAmendment(_ proposal: SkillAmendmentProposal) throws -> SkillAmendmentProposal {
        var proposals = try self.proposals()
        proposals.removeAll { $0.id == proposal.id }
        proposals.append(proposal)
        try writeJSON(proposals.sorted { $0.id < $1.id }, to: proposalsURL)
        return proposal
    }

    public func proposals(skillName: String? = nil) throws -> [SkillAmendmentProposal] {
        try readJSON([SkillAmendmentProposal].self, from: proposalsURL, default: [])
            .filter { skillName == nil || $0.skillName == skillName }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func snapshot(
        skillName: String,
        versionID: String,
        content: String,
        createdAt: Date = Date()
    ) throws -> SkillVersionSnapshot {
        let snapshot = SkillVersionSnapshot(
            skillName: skillName,
            versionID: versionID,
            contentHash: StableHash.fnv1a64Hex(content),
            content: content,
            createdAt: createdAt
        )
        try appendJSONLine(snapshot, to: snapshotsURL)
        return snapshot
    }

    public func snapshots(skillName: String? = nil) throws -> [SkillVersionSnapshot] {
        try readJSONLines(SkillVersionSnapshot.self, from: snapshotsURL)
            .filter { skillName == nil || $0.skillName == skillName }
            .sorted { $0.createdAt == $1.createdAt ? $0.versionID < $1.versionID : $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func promote(proposalID: String, snapshotID: String, promotedAt: Date = Date()) throws -> SkillAmendmentProposal {
        try updateProposal(id: proposalID) { $0.withPromotion(snapshotID: snapshotID, promotedAt: promotedAt) }
    }

    @discardableResult
    public func rollback(proposalID: String, toSnapshotID snapshotID: String, rolledBackAt: Date = Date()) throws -> SkillAmendmentProposal {
        try updateProposal(id: proposalID) { $0.withRollback(snapshotID: snapshotID, rolledBackAt: rolledBackAt) }
    }

    private var observationsURL: URL { rootDirectory.appendingPathComponent("observations.jsonl") }
    private var proposalsURL: URL { rootDirectory.appendingPathComponent("amendment_proposals.json") }
    private var snapshotsURL: URL { rootDirectory.appendingPathComponent("version_snapshots.jsonl") }

    private func updateProposal(
        id: String,
        transform: (SkillAmendmentProposal) -> SkillAmendmentProposal
    ) throws -> SkillAmendmentProposal {
        var proposals = try self.proposals()
        guard let index = proposals.firstIndex(where: { $0.id == id }) else {
            throw SkillImprovementError.proposalNotFound(id)
        }
        let updated = transform(proposals[index])
        proposals[index] = updated
        try writeJSON(proposals.sorted { $0.id < $1.id }, to: proposalsURL)
        return updated
    }

    private func appendJSONLine<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = String(decoding: try LearningJSON.encoder.encode(value), as: UTF8.self) + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func readJSONLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try LearningJSON.decoder.decode(type, from: Data($0.utf8)) }
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL, default defaultValue: T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return defaultValue }
        return try LearningJSON.decoder.decode(type, from: Data(contentsOf: url))
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LearningJSON.encoder.encode(value).write(to: url, options: .atomic)
    }
}

public enum SkillImprovementError: Error, Equatable, Sendable {
    case proposalNotFound(String)
}

public struct GeneratedSkillDraft: Equatable, Sendable {
    public let metadata: SkillRouteMetadata
    public let markdown: String

    @discardableResult
    public func write(toGeneratedSkillsDirectory directory: URL) throws -> URL {
        let skillDirectory = directory
            .standardizedFileURL
            .appendingPathComponent(metadata.name, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        let skillFile = skillDirectory.appendingPathComponent("SKILL.md")
        try markdown.write(to: skillFile, atomically: true, encoding: .utf8)
        return skillFile
    }

    public static func make(
        name: String,
        taskDescription: String,
        triggerPhrases: [String],
        requiredTools: [String],
        createdAt: Date = Date()
    ) -> GeneratedSkillDraft {
        let metadata = SkillRouteMetadata(
            name: name,
            description: taskDescription,
            triggerPhrases: triggerPhrases,
            requiredTools: requiredTools,
            isEnabled: false,
            isQuarantined: true,
            historicalSuccesses: 0,
            historicalFailures: 0
        )
        let markdown = """
        ---
        name: \(name)
        description: \(taskDescription)
        trigger_phrases: \(triggerPhrases.joined(separator: ", "))
        required_tools: \(requiredTools.joined(separator: ", "))
        enabled: false
        quarantined: true
        generated_at: \(LearningJSON.iso8601.string(from: createdAt))
        ---

        # \(name)

        This generated skill draft is disabled and quarantined until reviewed.

        ## Task Shape

        \(taskDescription)
        """
        return GeneratedSkillDraft(metadata: metadata, markdown: markdown)
    }
}

enum StableHash {
    static func fnv1a64Hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
