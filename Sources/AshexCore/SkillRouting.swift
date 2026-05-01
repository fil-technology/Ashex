import Foundation

public struct SkillRouteMetadata: Codable, Equatable, Sendable {
    public let name: String
    public let description: String
    public let triggerPhrases: [String]
    public let requiredTools: [String]
    public let isEnabled: Bool
    public let isQuarantined: Bool
    public let historicalSuccesses: Int
    public let historicalFailures: Int
    public let capabilitiesRequired: [String]
    public let openDesignMode: String?
    public let openDesignInputs: [String]

    public init(
        name: String,
        description: String,
        triggerPhrases: [String],
        requiredTools: [String] = [],
        capabilitiesRequired: [String] = [],
        openDesignMode: String? = nil,
        openDesignInputs: [String] = [],
        isEnabled: Bool = true,
        isQuarantined: Bool = false,
        historicalSuccesses: Int = 0,
        historicalFailures: Int = 0
    ) {
        self.name = name
        self.description = description
        self.triggerPhrases = triggerPhrases
        self.requiredTools = requiredTools
        self.isEnabled = isEnabled
        self.isQuarantined = isQuarantined
        self.historicalSuccesses = historicalSuccesses
        self.historicalFailures = historicalFailures
        self.capabilitiesRequired = capabilitiesRequired
        self.openDesignMode = openDesignMode
        self.openDesignInputs = openDesignInputs
    }
}

public struct SkillRouteScore: Equatable, Sendable {
    public let metadata: SkillRouteMetadata
    public let score: Double
    public let reasons: [String]

    public init(metadata: SkillRouteMetadata, score: Double, reasons: [String]) {
        self.metadata = metadata
        self.score = score
        self.reasons = reasons
    }
}

public struct SkillRouter: Sendable {
    public let availableTools: Set<String>
    public let availableCapabilities: Set<String>

    public init(availableTools: Set<String>, availableCapabilities: Set<String> = []) {
        self.availableTools = Set(availableTools.map { $0.lowercased() })
        self.availableCapabilities = Set(availableCapabilities.map { $0.lowercased() })
    }

    public init(availableTools: [String], availableCapabilities: [String] = []) {
        self.init(availableTools: Set(availableTools), availableCapabilities: Set(availableCapabilities))
    }

    public func rank(task: String, skills: [SkillRouteMetadata]) -> [SkillRouteScore] {
        let taskTokens = SkillRouter.tokens(in: task)
        let normalizedTask = task.lowercased()
        return skills.map { skill in
            score(skill: skill, normalizedTask: normalizedTask, taskTokens: taskTokens)
        }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.metadata.name < rhs.metadata.name
        }
    }

    private func score(
        skill: SkillRouteMetadata,
        normalizedTask: String,
        taskTokens: Set<String>
    ) -> SkillRouteScore {
        var score = 0.0
        var reasons: [String] = []

        for phrase in skill.triggerPhrases {
            let normalizedPhrase = phrase.lowercased()
            if normalizedTask.contains(normalizedPhrase) {
                score += 40
                reasons.append("trigger:\(phrase)")
            }
        }

        let skillText = ([skill.name, skill.description] + skill.triggerPhrases).joined(separator: " ")
        let skillTokens = SkillRouter.tokens(in: skillText)
        if !skillTokens.isEmpty {
            let overlap = taskTokens.intersection(skillTokens).count
            let union = taskTokens.union(skillTokens).count
            if union > 0 {
                let similarity = Double(overlap) / Double(union)
                score += similarity * 30
                if overlap > 0 {
                    reasons.append("lexical:\(String(format: "%.2f", similarity))")
                }
            }
        }

        let required = skill.requiredTools.map { $0.lowercased() }
        let missing = required.filter { !availableTools.contains($0) }.sorted()
        if required.isEmpty {
            score += 5
            reasons.append("tools:none")
        } else if missing.isEmpty {
            score += 20
            reasons.append("tools:available")
        } else {
            score -= Double(missing.count) * 20
            for tool in missing {
                reasons.append("tools:missing:\(tool)")
            }
        }

        let capabilities = skill.capabilitiesRequired.map { $0.lowercased() }
        let missingCapabilities = capabilities.filter { !availableCapabilities.contains($0) }.sorted()
        if capabilities.isEmpty {
            score += 2
            reasons.append("capabilities:none")
        } else if missingCapabilities.isEmpty {
            score += 10
            reasons.append("capabilities:available")
        } else {
            score -= Double(missingCapabilities.count) * 15
            for capability in missingCapabilities {
                reasons.append("capabilities:missing:\(capability)")
            }
        }

        let attempts = skill.historicalSuccesses + skill.historicalFailures
        if attempts > 0 {
            let successRate = Double(skill.historicalSuccesses) / Double(attempts)
            score += successRate * 15
            reasons.append("history:\(String(format: "%.2f", successRate))")
        }

        if !skill.isEnabled {
            score -= 100
            reasons.append("disabled")
        }
        if skill.isQuarantined {
            score -= 100
            reasons.append("quarantined")
        }

        return SkillRouteScore(metadata: skill, score: score, reasons: reasons)
    }

    static func tokens(in text: String) -> Set<String> {
        let pieces = text.lowercased().split { character in
            !character.isLetter && !character.isNumber
        }
        return Set(pieces.map(String.init).filter { $0.count > 1 })
    }
}

public struct RuntimeSkillRoutingConfig: Sendable {
    public let skills: [SkillRouteMetadata]
    public let availableCapabilities: Set<String>
    public let minimumScore: Double
    public let limit: Int

    public init(
        skills: [SkillRouteMetadata],
        availableCapabilities: Set<String> = [],
        minimumScore: Double = 20,
        limit: Int = 3
    ) {
        self.skills = skills
        self.availableCapabilities = availableCapabilities
        self.minimumScore = minimumScore
        self.limit = max(limit, 0)
    }

    public func select(task: String, availableTools: [String]) -> [SkillRouteScore] {
        guard limit > 0, !skills.isEmpty else { return [] }
        return SkillRouter(
            availableTools: availableTools,
            availableCapabilities: Array(availableCapabilities)
        )
        .rank(task: task, skills: skills)
        .filter { $0.score >= minimumScore }
        .prefix(limit)
        .map { $0 }
    }
}
