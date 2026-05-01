@testable import AshexCore
import Foundation
import Testing

@Test func skillRouterRanksByTriggersLexicalSimilarityToolsAndHistory() {
    let router = SkillRouter(availableTools: ["git", "swift", "filesystem"])
    let skills = [
        SkillRouteMetadata(
            name: "generic-helper",
            description: "General development help",
            triggerPhrases: ["help"],
            requiredTools: [],
            isEnabled: true,
            isQuarantined: false,
            historicalSuccesses: 10,
            historicalFailures: 0
        ),
        SkillRouteMetadata(
            name: "swift-testing",
            description: "Swift package testing and compile failure triage",
            triggerPhrases: ["swift test", "compile failure"],
            requiredTools: ["swift"],
            isEnabled: true,
            isQuarantined: false,
            historicalSuccesses: 4,
            historicalFailures: 1
        ),
        SkillRouteMetadata(
            name: "release-quarantined",
            description: "Release automation",
            triggerPhrases: ["release"],
            requiredTools: ["git"],
            isEnabled: false,
            isQuarantined: true,
            historicalSuccesses: 99,
            historicalFailures: 0
        ),
    ]

    let ranked = router.rank(
        task: "Fix the Swift compile failure and run swift test for the package",
        skills: skills
    )

    #expect(ranked.map(\.metadata.name) == ["swift-testing", "generic-helper", "release-quarantined"])
    #expect(ranked[0].score > ranked[1].score)
    #expect(ranked[0].reasons.contains("trigger:swift test"))
    #expect(ranked[0].reasons.contains("tools:available"))
    #expect(ranked[2].reasons.contains("disabled"))
    #expect(ranked[2].reasons.contains("quarantined"))
}

@Test func skillRouterPenalizesMissingRequiredToolsButKeepsDeterministicOrdering() {
    let router = SkillRouter(availableTools: ["filesystem"])
    let skills = [
        SkillRouteMetadata(
            name: "z-shell",
            description: "Shell command workflows",
            triggerPhrases: ["shell"],
            requiredTools: ["shell"],
            isEnabled: true,
            isQuarantined: false,
            historicalSuccesses: 1,
            historicalFailures: 0
        ),
        SkillRouteMetadata(
            name: "a-shell",
            description: "Shell command workflows",
            triggerPhrases: ["shell"],
            requiredTools: ["shell"],
            isEnabled: true,
            isQuarantined: false,
            historicalSuccesses: 1,
            historicalFailures: 0
        ),
    ]

    let ranked = router.rank(task: "Run a shell command", skills: skills)

    #expect(ranked.map(\.metadata.name) == ["a-shell", "z-shell"])
    #expect(ranked.allSatisfy { $0.reasons.contains("tools:missing:shell") })
}

@Test func skillRouterKeepsCompatibilityWithoutCapabilitiesAndPenalizesMissingCapabilities() {
    let router = SkillRouter(availableTools: ["filesystem"], availableCapabilities: ["artifact_manifest"])
    let skills = [
        SkillRouteMetadata(
            name: "plain-skill",
            description: "Design system review",
            triggerPhrases: ["design system"],
            requiredTools: ["filesystem"]
        ),
        SkillRouteMetadata(
            name: "preview-skill",
            description: "Design system review with sandboxed preview",
            triggerPhrases: ["design system"],
            requiredTools: ["filesystem"],
            capabilitiesRequired: ["sandboxed_preview", "artifact_manifest"],
            openDesignMode: "review",
            openDesignInputs: ["design-system.md"]
        ),
    ]

    let ranked = router.rank(task: "Review the design system", skills: skills)

    #expect(ranked.map(\.metadata.name) == ["plain-skill", "preview-skill"])
    #expect(ranked[0].reasons.contains("capabilities:none"))
    #expect(ranked[1].reasons.contains("capabilities:missing:sandboxed_preview"))
    #expect(ranked[1].metadata.openDesignMode == "review")
    #expect(ranked[1].metadata.openDesignInputs == ["design-system.md"])
}
