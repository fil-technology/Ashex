import Foundation

public struct ModelRoute: Codable, Sendable, Equatable {
    public let provider: String
    public let model: String
    public let endpoint: URL?

    public init(provider: String, model: String, endpoint: URL? = nil) {
        self.provider = provider
        self.model = model
        self.endpoint = endpoint
    }
}

public enum ModelRouteSlot: String, Codable, Sendable, Equatable, Hashable {
    case fast
    case reasoning
    case local
    case vision
    case audio
}

public enum ModelTaskPurpose: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case planning
    case summarization
    case verification
    case skillAmendment
    case coding
    case toolCalling
    case conversation
    case visionUnderstanding
    case audioTranscription
}

public struct ModelRoutingConfig: Codable, Sendable, Equatable {
    public let fast: ModelRoute
    public let reasoning: ModelRoute
    public let local: ModelRoute
    public let vision: ModelRoute
    public let audio: ModelRoute
    public let purposeRoutes: [ModelTaskPurpose: ModelRouteSlot]

    public init(
        fast: ModelRoute,
        reasoning: ModelRoute,
        local: ModelRoute,
        vision: ModelRoute,
        audio: ModelRoute,
        purposeRoutes: [ModelTaskPurpose: ModelRouteSlot] = [:]
    ) {
        self.fast = fast
        self.reasoning = reasoning
        self.local = local
        self.vision = vision
        self.audio = audio
        self.purposeRoutes = purposeRoutes
    }

    public func slot(for purpose: ModelTaskPurpose) -> ModelRouteSlot {
        if let explicit = purposeRoutes[purpose] {
            return explicit
        }

        switch purpose {
        case .planning, .verification, .coding:
            return .reasoning
        case .summarization, .toolCalling, .conversation:
            return .fast
        case .skillAmendment:
            return .local
        case .visionUnderstanding:
            return .vision
        case .audioTranscription:
            return .audio
        }
    }

    public func route(for purpose: ModelTaskPurpose) -> ModelRoute {
        route(for: slot(for: purpose))
    }

    public func route(for slot: ModelRouteSlot) -> ModelRoute {
        switch slot {
        case .fast:
            return fast
        case .reasoning:
            return reasoning
        case .local:
            return local
        case .vision:
            return vision
        case .audio:
            return audio
        }
    }
}

public struct RuntimeModelRouter: Sendable {
    private let primary: any ModelAdapter
    private let purposeAdapters: [ModelTaskPurpose: any ModelAdapter]

    public init(
        primary: any ModelAdapter,
        purposeAdapters: [ModelTaskPurpose: any ModelAdapter] = [:]
    ) {
        self.primary = primary
        self.purposeAdapters = purposeAdapters
    }

    public func adapter(for purpose: ModelTaskPurpose) -> any ModelAdapter {
        purposeAdapters[purpose] ?? primary
    }

    public func routeLabel(for purpose: ModelTaskPurpose) -> String {
        let adapter = adapter(for: purpose)
        return "\(purpose.rawValue):\(adapter.providerID)/\(adapter.modelID)"
    }
}
