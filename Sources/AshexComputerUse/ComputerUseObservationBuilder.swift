import Foundation

public struct ComputerUseObservationBuilder: Sendable {
    public init() {}

    public func makeObservation(_ state: ComputerUseWindowState, screenshot: ComputerUseScreenshot? = nil) -> ComputerUseObservation {
        ComputerUseObservation(
            text: makeCompactObservation(state),
            screenshots: screenshot.map { [$0] } ?? []
        )
    }

    public func makeCompactObservation(_ state: ComputerUseWindowState) -> String {
        var lines = [
            "Window: \(state.appName) - \(state.title)",
        ]
        if let url = state.url, !url.isEmpty {
            lines.append("URL: \(url)")
        }

        if state.elements.isEmpty {
            lines.append("Elements: none reported")
            return lines.joined(separator: "\n")
        }

        lines.append("Elements:")
        for element in state.elements.prefix(20) {
            let name = [element.title, element.value]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "untitled"
            let enabled = element.isEnabled ? "" : " disabled"
            lines.append("- [\(element.id)] \(element.role) \(name)\(enabled)")
        }
        if state.elements.count > 20 {
            lines.append("- ... \(state.elements.count - 20) more")
        }
        return lines.joined(separator: "\n")
    }
}
