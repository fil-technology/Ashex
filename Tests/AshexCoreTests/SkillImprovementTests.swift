@testable import AshexCore
import Foundation
import Testing

@Test func skillImprovementStoreDetectsRepeatedIssuesAndTracksPromotionRollback() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = SkillImprovementStore(rootDirectory: root)
    let observedAt = Date(timeIntervalSince1970: 1_800_000_100)

    let first = SkillRunObservation(
        id: "obs-1",
        skillName: "swift-testing",
        taskFingerprint: "compile-failure-a",
        outcome: .failure,
        issue: "forgot focused swift test filter",
        correction: nil,
        requiredTools: ["swift"],
        observedAt: observedAt
    )
    let second = SkillRunObservation(
        id: "obs-2",
        skillName: "swift-testing",
        taskFingerprint: "compile-failure-b",
        outcome: .correction,
        issue: "forgot focused swift test filter",
        correction: "Run swift test --filter before final.",
        requiredTools: ["swift"],
        observedAt: observedAt
    )
    try store.record(first)
    try store.record(second)

    let signals = try store.repeatedIssueSignals(skillName: "swift-testing", minimumCount: 2)
    #expect(signals == [
        .init(skillName: "swift-testing", issue: "forgot focused swift test filter", count: 2, observationIDs: ["obs-1", "obs-2"]),
    ])

    let proposal = try store.proposeAmendment(.init(
        id: "proposal-1",
        skillName: "swift-testing",
        reason: "Repeated missing focused test verification",
        proposedPatch: "Add a verification checklist item for swift test --filter.",
        sourceObservationIDs: ["obs-1", "obs-2"],
        status: .proposed,
        createdAt: observedAt
    ))
    let snapshot = try store.snapshot(skillName: "swift-testing", versionID: "v1", content: "original skill", createdAt: observedAt)
    let promoted = try store.promote(proposalID: proposal.id, snapshotID: snapshot.versionID, promotedAt: observedAt)
    let rolledBack = try store.rollback(proposalID: proposal.id, toSnapshotID: snapshot.versionID, rolledBackAt: observedAt)

    #expect(promoted.status == .promoted)
    #expect(promoted.promotedSnapshotID == "v1")
    #expect(rolledBack.status == .rolledBack)
    #expect(rolledBack.rollbackSnapshotID == "v1")
    #expect(try store.proposals(skillName: "swift-testing").map(\.id) == ["proposal-1"])
}

@Test func generatedSkillDraftsAreDisabledAndQuarantinedByDefault() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let draft = GeneratedSkillDraft.make(
        name: "repo-release-helper",
        taskDescription: "Coordinate a multi-step release with changelog, tests, and tagging.",
        triggerPhrases: ["release", "changelog", "tag"],
        requiredTools: ["git", "swift"],
        createdAt: Date(timeIntervalSince1970: 1_800_000_200)
    )

    #expect(draft.metadata.name == "repo-release-helper")
    #expect(draft.metadata.isEnabled == false)
    #expect(draft.metadata.isQuarantined == true)
    #expect(draft.markdown.contains("generated skill draft"))
    #expect(draft.markdown.contains("enabled: false"))
    #expect(draft.markdown.contains("quarantined: true"))

    let url = try draft.write(toGeneratedSkillsDirectory: root)
    #expect(url.lastPathComponent == "SKILL.md")
    #expect(url.path.contains("repo-release-helper"))
    #expect(try String(contentsOf: url, encoding: .utf8) == draft.markdown)
}
