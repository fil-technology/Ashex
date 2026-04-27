import Foundation

public struct ComputerUseCommandParser: Sendable {
    public init() {}

    public func parse(_ input: String) throws -> ComputerUseAction {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ComputerUseCommandError.invalid("Enter a command like `state`, `screenshot`, `click 12`, `type hello`, or `quit`.")
        }

        if trimmed == "state" {
            return .refreshState
        }
        if trimmed == "screenshot" {
            return .captureScreenshot
        }
        if trimmed == "quit" {
            return .quit
        }

        if trimmed.hasPrefix("click ") {
            let id = String(trimmed.dropFirst("click ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw ComputerUseCommandError.invalid("`click` requires an element id, for example `click 12`.")
            }
            return .click(elementId: id)
        }

        if trimmed.hasPrefix("type ") {
            let text = String(trimmed.dropFirst("type ".count))
            guard !text.isEmpty else {
                throw ComputerUseCommandError.invalid("`type` requires text, for example `type hello`.")
            }
            return .typeText(text)
        }

        if trimmed.hasPrefix("scroll ") {
            let directionText = String(trimmed.dropFirst("scroll ".count)).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let direction = ScrollDirection(rawValue: directionText) else {
                throw ComputerUseCommandError.invalid("Unsupported scroll direction `\(directionText)`. Use `scroll up` or `scroll down`.")
            }
            return .scroll(direction: direction, amount: 1)
        }

        if trimmed.hasPrefix("press ") {
            return try parsePress(String(trimmed.dropFirst("press ".count)))
        }

        throw ComputerUseCommandError.unsupported("Unsupported command `\(trimmed)`. Supported commands: click, type, press, scroll, screenshot, state, quit.")
    }

    private func parsePress(_ rawValue: String) throws -> ComputerUseAction {
        let tokens = rawValue
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        guard !tokens.isEmpty else {
            throw ComputerUseCommandError.invalid("`press` requires a key, for example `press enter` or `press cmd l`.")
        }

        let knownModifiers = Set(["cmd", "shift", "ctrl", "alt", "option"])
        var modifiers: [String] = []
        var keyToken: String?

        for token in tokens {
            if knownModifiers.contains(token) {
                modifiers.append(token == "option" ? "alt" : token)
            } else if keyToken == nil {
                keyToken = token
            } else {
                throw ComputerUseCommandError.invalid("Only one key is supported in `press` commands.")
            }
        }

        guard let keyToken else {
            throw ComputerUseCommandError.invalid("`press` requires a non-modifier key, for example `press enter`.")
        }

        let key: String
        switch keyToken {
        case "enter": key = "Enter"
        case "escape", "esc": key = "Escape"
        case "tab": key = "Tab"
        default:
            guard keyToken.count == 1 else {
                throw ComputerUseCommandError.invalid("Unsupported key `\(keyToken)`. Start with enter, escape, tab, or a single letter shortcut.")
            }
            key = keyToken.uppercased()
        }

        return .pressKey(key: key, modifiers: modifiers)
    }
}
