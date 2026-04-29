import AshexCore
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public final class NativeMacOSComputerUseProvider: ComputerUseProvider, @unchecked Sendable {
    public init() {}

    public func bootstrap() async throws {
        try ensureReady()
    }

    public func permissionStatus() async -> ComputerUsePermissionStatus {
        ComputerUsePermissionChecker.current()
    }

    public func backendStatus() async throws -> ComputerUseBackendStatus {
        let permissions = ComputerUsePermissionChecker.current()
        if permissions.isReadyForComputerUse {
            return .init(state: .running, detail: "native macOS Accessibility/CoreGraphics")
        }
        return .init(state: .stopped, detail: "macOS permissions required")
    }

    public func listWindows() async throws -> [ComputerUseWindow] {
        try ensureReady()
        return NativeWindowSnapshot.visibleWindows().map {
            ComputerUseWindow(id: $0.id, title: $0.title, appName: $0.appName)
        }
    }

    public func getWindowState(windowId: String) async throws -> ComputerUseWindowState {
        try ensureAccessibility()
        let window = try findWindow(windowId: windowId)
        let elements = try NativeAXSnapshotter.windowElements(for: window)
        return ComputerUseWindowState(
            windowID: window.id,
            title: window.title,
            appName: window.appName,
            url: nil,
            elements: elements.map(\.element)
        )
    }

    public func click(elementId: String, windowId: String) async throws {
        try ensureAccessibility()
        let target = try findElement(elementId: elementId, windowId: windowId)
        if AXUIElementPerformAction(target.axElement, kAXPressAction as CFString) == .success {
            return
        }
        guard let point = target.frame?.center else {
            throw AshexError.model("Element \(elementId) could not be pressed and has no usable screen frame for fallback clicking.")
        }
        postMouseClick(at: point)
    }

    public func typeText(_ text: String, windowId _: String) async throws {
        try ensureAccessibility()
        for unit in text.utf16 {
            var value = UniChar(unit)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw AshexError.model("Unable to create keyboard events for text input.")
            }
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    public func pressKey(_ key: String, modifiers: [String], windowId _: String) async throws {
        try ensureAccessibility()
        guard let keyCode = NativeKeyCodes.keyCode(for: key) else {
            throw AshexError.model("Unsupported native key `\(key)`. Use enter, escape, tab, arrows, delete, space, letters, or numbers.")
        }
        let flags = NativeKeyCodes.flags(for: modifiers)
        postKey(keyCode, flags: flags)
    }

    public func scroll(direction: ScrollDirection, amount: Int, windowId _: String) async throws {
        try ensureAccessibility()
        let units = Int32(max(1, amount) * 6)
        let delta = direction == .up ? units : -units
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else {
            throw AshexError.model("Unable to create scroll event.")
        }
        event.post(tap: .cghidEventTap)
    }

    private func ensureReady() throws {
        let permissions = ComputerUsePermissionChecker.current()
        guard permissions.isReadyForComputerUse else {
            throw AshexError.model(permissions.guidance)
        }
    }

    private func ensureAccessibility() throws {
        let permissions = ComputerUsePermissionChecker.current()
        guard permissions.accessibility == .granted else {
            throw AshexError.model(permissions.guidance)
        }
    }

    private func findWindow(windowId: String) throws -> NativeWindowSnapshot {
        guard let window = NativeWindowSnapshot.visibleWindows().first(where: { $0.id == windowId }) else {
            throw AshexError.model("Window \(windowId) is no longer visible. Run `state` or restart the prototype to choose a current window.")
        }
        return window
    }

    private func findElement(elementId: String, windowId: String) throws -> NativeAXElementSnapshot {
        let window = try findWindow(windowId: windowId)
        let elements = try NativeAXSnapshotter.windowElements(for: window)
        guard let element = elements.first(where: { $0.element.id == elementId }) else {
            throw AshexError.model("Element \(elementId) was not found in the current accessibility tree for \(window.appName) - \(window.title).")
        }
        guard element.element.isEnabled else {
            throw AshexError.model("Element \(elementId) is disabled.")
        }
        return element
    }

    private func postMouseClick(at point: CGPoint) {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

private struct NativeWindowSnapshot: Equatable {
    let pid: pid_t
    let windowNumber: Int
    let title: String
    let appName: String

    var id: String {
        "native:\(pid):\(windowNumber)"
    }

    static func visibleWindows() -> [NativeWindowSnapshot] {
        guard let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return rawWindows.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let windowNumber = info[kCGWindowNumber as String] as? Int,
                  (info[kCGWindowLayer as String] as? Int) == 0 else {
                return nil
            }
            let title = (info[kCGWindowName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let owner = (info[kCGWindowOwnerName as String] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let appName = owner?.isEmpty == false
                ? owner!
                : NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Application \(pid)"
            return NativeWindowSnapshot(
                pid: pid,
                windowNumber: windowNumber,
                title: title.isEmpty ? "Untitled Window" : title,
                appName: appName
            )
        }
    }
}

private struct NativeAXElementSnapshot {
    let element: ComputerUseElement
    let axElement: AXUIElement
    let frame: CGRect?
}

private enum NativeAXSnapshotter {
    static func windowElements(for window: NativeWindowSnapshot) throws -> [NativeAXElementSnapshot] {
        let app = AXUIElementCreateApplication(window.pid)
        let axWindow = try findAXWindow(in: app, matching: window)
        var snapshots: [NativeAXElementSnapshot] = []
        collectElements(from: axWindow, into: &snapshots, maxDepth: 8, visited: [])
        return snapshots
    }

    private static func findAXWindow(in app: AXUIElement, matching window: NativeWindowSnapshot) throws -> AXUIElement {
        let windows = axElements(attribute: kAXWindowsAttribute, from: app)
        if let exact = windows.first(where: { title(of: $0) == window.title }) {
            return exact
        }
        if let first = windows.first {
            return first
        }
        throw AshexError.model("No accessibility window is available for \(window.appName). Check Accessibility permission and make sure the window is still open.")
    }

    private static func collectElements(
        from axElement: AXUIElement,
        into snapshots: inout [NativeAXElementSnapshot],
        maxDepth: Int,
        visited: Set<AXUIElement>
    ) {
        guard maxDepth >= 0, !visited.contains(axElement) else {
            return
        }
        var visited = visited
        visited.insert(axElement)

        let role = string(attribute: kAXRoleAttribute, from: axElement) ?? "AXElement"
        let title = string(attribute: kAXTitleAttribute, from: axElement)
        let value = string(attribute: kAXValueAttribute, from: axElement)
        let isEnabled = bool(attribute: kAXEnabledAttribute, from: axElement) ?? true
        let frame = frame(of: axElement)

        if shouldExpose(role: role, title: title, value: value, frame: frame) {
            snapshots.append(NativeAXElementSnapshot(
                element: ComputerUseElement(
                    id: "ax-\(snapshots.count + 1)",
                    role: role.replacingOccurrences(of: "AX", with: ""),
                    title: title,
                    value: value,
                    isEnabled: isEnabled
                ),
                axElement: axElement,
                frame: frame
            ))
        }

        for child in axElements(attribute: kAXChildrenAttribute, from: axElement) {
            collectElements(from: child, into: &snapshots, maxDepth: maxDepth - 1, visited: visited)
        }
    }

    private static func shouldExpose(role: String, title: String?, value: String?, frame: CGRect?) -> Bool {
        let hasName = [title, value].contains { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
        let actionableRoles = [
            kAXButtonRole,
            kAXCheckBoxRole,
            kAXComboBoxRole,
            "AXLink",
            kAXMenuButtonRole,
            kAXPopUpButtonRole,
            kAXRadioButtonRole,
            kAXSliderRole,
            kAXTextAreaRole,
            kAXTextFieldRole,
        ].map { $0 as String }
        return hasName || actionableRoles.contains(role) || frame != nil && role == (kAXStaticTextRole as String)
    }

    private static func title(of element: AXUIElement) -> String? {
        string(attribute: kAXTitleAttribute, from: element)?.nilIfBlank
    }

    private static func axElements(attribute: String, from element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else {
            return []
        }
        return elements
    }

    private static func string(attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let rawValue = value else {
            return nil
        }
        if let string = rawValue as? String {
            return string.nilIfBlank
        }
        return String(describing: rawValue).nilIfBlank
    }

    private static func bool(attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &point),
              AXValueGetValue(sizeAXValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }
}

private enum NativeKeyCodes {
    static func keyCode(for key: String) -> CGKeyCode? {
        let normalized = key.lowercased()
        if normalized.count == 1, let scalar = normalized.unicodeScalars.first {
            return letterKeyCodes[scalar]
        }
        return namedKeyCodes[normalized]
    }

    static func flags(for modifiers: [String]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            switch modifier.lowercased() {
            case "cmd", "command":
                flags.insert(.maskCommand)
            case "shift":
                flags.insert(.maskShift)
            case "ctrl", "control":
                flags.insert(.maskControl)
            case "alt", "option":
                flags.insert(.maskAlternate)
            default:
                break
            }
        }
    }

    private static let namedKeyCodes: [String: CGKeyCode] = [
        "enter": 36,
        "return": 36,
        "tab": 48,
        "space": 49,
        "delete": 51,
        "backspace": 51,
        "escape": 53,
        "esc": 53,
        "left": 123,
        "right": 124,
        "down": 125,
        "up": 126,
        "0": 29,
        "1": 18,
        "2": 19,
        "3": 20,
        "4": 21,
        "5": 23,
        "6": 22,
        "7": 26,
        "8": 28,
        "9": 25,
    ]

    private static let letterKeyCodes: [Unicode.Scalar: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46,
    ]
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
