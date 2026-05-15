import Foundation

final class TerminalLineBuffer: @unchecked Sendable {
    private var buffer: String = ""
    private let lock = NSLock()

    private static let ansiPattern = try! NSRegularExpression(
        pattern: "\u{1b}\\[[0-9;?]*[A-Za-z]|\u{1b}\\][^\u{07}]*\u{07}|\u{1b}[()][A-Z0-9]"
    )

    func feed(_ rawText: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        buffer += text
        var completedLines: [String] = []

        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let lineContent = String(buffer[buffer.startIndex..<newlineIndex])
            buffer = String(buffer[buffer.index(after: newlineIndex)...])

            let resolved = resolveCarriageReturns(lineContent)
            let stripped = Self.stripAnsiEscapes(resolved)
            if !stripped.isEmpty {
                completedLines.append(stripped)
            }
        }

        if let lastCR = buffer.lastIndex(of: "\r") {
            buffer = String(buffer[buffer.index(after: lastCR)...])
        }

        return completedLines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let resolved = resolveCarriageReturns(buffer)
        let stripped = Self.stripAnsiEscapes(resolved)
        buffer = ""
        return stripped.isEmpty ? nil : stripped
    }

    private func resolveCarriageReturns(_ text: String) -> String {
        guard text.contains("\r") else { return text }
        let segments = text.split(separator: "\r", omittingEmptySubsequences: false)
        return String(segments.last ?? "")
    }

    static func stripAnsiEscapes(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ansiPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
