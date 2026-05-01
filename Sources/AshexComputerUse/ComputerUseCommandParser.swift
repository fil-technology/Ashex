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

        if trimmed.hasPrefix("open url ") {
            let url = String(trimmed.dropFirst("open url ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else {
                throw ComputerUseCommandError.invalid("`open url` requires a URL.")
            }
            return .openURL(url)
        }

        if trimmed.hasPrefix("open app ") {
            let name = String(trimmed.dropFirst("open app ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw ComputerUseCommandError.invalid("`open app` requires an app name.")
            }
            return .openApp(name)
        }

        if trimmed.hasPrefix("move ") {
            let point = try parsePoint(String(trimmed.dropFirst("move ".count)), command: "move")
            return .moveMouse(x: point.x, y: point.y)
        }

        if trimmed.hasPrefix("double click ") {
            let point = try parsePoint(String(trimmed.dropFirst("double click ".count)), command: "double click")
            return .doubleClick(x: point.x, y: point.y)
        }

        if trimmed.hasPrefix("right click ") {
            let point = try parsePoint(String(trimmed.dropFirst("right click ".count)), command: "right click")
            return .rightClick(x: point.x, y: point.y)
        }

        if trimmed.hasPrefix("click at ") {
            let point = try parsePoint(String(trimmed.dropFirst("click at ".count)), command: "click at")
            return .clickAt(x: point.x, y: point.y, button: .left, clickCount: 1)
        }

        if trimmed.hasPrefix("drag ") {
            let values = try parseNumbers(String(trimmed.dropFirst("drag ".count)), expected: 4, command: "drag")
            return .drag(fromX: values[0], fromY: values[1], toX: values[2], toY: values[3])
        }

        if trimmed.hasPrefix("wait ") {
            let rawSeconds = String(trimmed.dropFirst("wait ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let seconds = Double(rawSeconds), seconds >= 0 else {
                throw ComputerUseCommandError.invalid("`wait` requires non-negative seconds.")
            }
            return .wait(seconds: seconds)
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
            let tokens = String(trimmed.dropFirst("scroll ".count))
                .split(whereSeparator: \.isWhitespace)
                .map { String($0).lowercased() }
            let directionText = tokens.first ?? ""
            guard let direction = ScrollDirection(rawValue: directionText) else {
                throw ComputerUseCommandError.invalid("Unsupported scroll direction `\(directionText)`. Use `scroll up` or `scroll down`.")
            }
            let amount = tokens.dropFirst().first.flatMap(Int.init) ?? 1
            guard amount > 0 else {
                throw ComputerUseCommandError.invalid("Scroll amount must be greater than zero.")
            }
            return .scroll(direction: direction, amount: amount)
        }

        if trimmed.hasPrefix("press ") {
            return try parsePress(String(trimmed.dropFirst("press ".count)))
        }

        throw ComputerUseCommandError.unsupported("Unsupported command `\(trimmed)`. Supported commands: open app, open url, move, click, double click, right click, drag, type, press, scroll, screenshot, state, wait, quit.")
    }

    private func parsePoint(_ rawValue: String, command: String) throws -> (x: Double, y: Double) {
        let values = try parseNumbers(rawValue, expected: 2, command: command)
        return (values[0], values[1])
    }

    private func parseNumbers(_ rawValue: String, expected: Int, command: String) throws -> [Double] {
        let values = rawValue
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard values.count == expected else {
            throw ComputerUseCommandError.invalid("`\(command)` expects \(expected) numeric value(s).")
        }
        let parsed = values.compactMap(Double.init)
        guard parsed.count == expected else {
            throw ComputerUseCommandError.invalid("`\(command)` values must be numbers.")
        }
        return parsed
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
        case "space": key = "Space"
        case "delete", "backspace": key = "Delete"
        case "up": key = "Up"
        case "down": key = "Down"
        case "left": key = "Left"
        case "right": key = "Right"
        default:
            guard keyToken.count == 1 else {
                throw ComputerUseCommandError.invalid("Unsupported key `\(keyToken)`. Start with enter, escape, tab, arrows, delete, space, or a single key shortcut.")
            }
            key = keyToken.uppercased()
        }

        return .pressKey(key: key, modifiers: modifiers)
    }
}
