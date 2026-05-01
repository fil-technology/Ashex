import AshexCore
import Foundation

public struct ComputerUseSafetyDecision: Sendable, Equatable {
    public let isAllowed: Bool
    public let requiresConfirmation: Bool
    public let reason: String?

    public init(isAllowed: Bool, requiresConfirmation: Bool, reason: String?) {
        self.isAllowed = isAllowed
        self.requiresConfirmation = requiresConfirmation
        self.reason = reason
    }

    public static func allow(requiresConfirmation: Bool = false, reason: String? = nil) -> Self {
        .init(isAllowed: true, requiresConfirmation: requiresConfirmation, reason: reason)
    }

    public static func block(_ reason: String) -> Self {
        .init(isAllowed: false, requiresConfirmation: false, reason: reason)
    }
}

public struct ComputerUseSafetyPolicy: Sendable {
    public let mode: ComputerUseSafetyMode

    public init(mode: ComputerUseSafetyMode) {
        self.mode = mode
    }

    public func evaluate(_ action: ComputerUseAction, state: ComputerUseWindowState) -> ComputerUseSafetyDecision {
        if mode != .dev, isSensitive(state: state) {
            return .block("This window looks sensitive, so computer use is blocked outside dev mode.")
        }

        switch action {
        case .refreshState, .captureScreenshot, .quit:
            return .allow()
        case .scroll, .moveMouse, .wait:
            return .allow()
        case .openURL:
            return .allow(requiresConfirmation: mode == .strict, reason: "Opening URLs can navigate to external sites.")
        case .openApp:
            return .allow(requiresConfirmation: mode == .strict, reason: "Opening apps can change the desktop state.")
        case .click, .clickAt, .doubleClick, .rightClick, .drag:
            return .allow(requiresConfirmation: mode != .dev, reason: "Clicks can change app state.")
        case .typeText:
            return .allow(requiresConfirmation: mode != .dev, reason: "Typing can submit or overwrite data.")
        case .pressKey(let key, let modifiers):
            if key == "Enter" || !modifiers.isEmpty {
                return .allow(requiresConfirmation: mode != .dev, reason: "Keyboard shortcuts can trigger destructive actions.")
            }
            return .allow(requiresConfirmation: mode == .strict, reason: "Key presses can change focus or trigger actions.")
        }
    }

    private func isSensitive(state: ComputerUseWindowState) -> Bool {
        let haystack = [
            state.title,
            state.appName,
            state.url ?? "",
        ].joined(separator: " ").lowercased()

        let sensitiveTerms = [
            "1password",
            "bitwarden",
            "lastpass",
            "password",
            "payment",
            "checkout",
            "bank",
            "wallet",
            "system settings",
        ]
        return sensitiveTerms.contains { haystack.contains($0) }
    }
}
