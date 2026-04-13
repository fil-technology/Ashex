import Foundation

enum TelegramMessageFormatter {
    static let parseMode = "HTML"

    static func format(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return renderCodeBlocks(in: trimmed)
    }

    private static func renderCodeBlocks(in text: String) -> String {
        let segments = text.components(separatedBy: "```")
        guard segments.count > 1 else {
            return renderInlineMarkup(in: text)
        }

        var rendered: [String] = []
        for (index, segment) in segments.enumerated() {
            if index.isMultiple(of: 2) {
                rendered.append(renderInlineMarkup(in: segment))
                continue
            }

            let code = stripOptionalLanguageHint(from: segment)
            rendered.append("<pre><code>\(escapeHTML(code))</code></pre>")
        }
        return rendered.joined()
    }

    private static func renderInlineMarkup(in text: String) -> String {
        let segments = text.components(separatedBy: "`")
        guard segments.count > 1 else {
            return renderBold(in: escapeHTML(text))
        }

        var rendered: [String] = []
        for (index, segment) in segments.enumerated() {
            if index.isMultiple(of: 2) {
                rendered.append(renderBold(in: escapeHTML(segment)))
            } else {
                rendered.append("<code>\(escapeHTML(segment))</code>")
            }
        }
        return rendered.joined()
    }

    private static func renderBold(in text: String) -> String {
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard let openRange = text[index...].range(of: "**") else {
                result.append(contentsOf: text[index...])
                break
            }

            result.append(contentsOf: text[index..<openRange.lowerBound])
            let contentStart = openRange.upperBound
            guard let closeRange = text[contentStart...].range(of: "**") else {
                result.append(contentsOf: text[openRange.lowerBound...])
                break
            }

            let content = text[contentStart..<closeRange.lowerBound]
            if content.isEmpty {
                result.append("**")
            } else {
                result.append("<b>\(content)</b>")
            }
            index = closeRange.upperBound
        }

        return result
    }

    private static func stripOptionalLanguageHint(from text: String) -> String {
        guard let newline = text.firstIndex(of: "\n") else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let firstLine = text[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = text[text.index(after: newline)...]
        if isLikelyLanguageHint(firstLine) {
            return String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLikelyLanguageHint(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        return line.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "+" || $0 == "." }
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
