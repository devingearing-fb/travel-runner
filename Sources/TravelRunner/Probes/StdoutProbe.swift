import Foundation

final class StdoutProbe: Probe, @unchecked Sendable {
    private let pattern: String
    private let regex: NSRegularExpression
    private var matched = false
    private let lock = NSLock()

    /// Throws `ProbeConfigError` when the pattern is empty or not a regular expression.
    init(pattern: String) throws {
        guard !pattern.isEmpty else { throw ProbeConfigError(reason: "probe type stdout_regex needs a pattern") }
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw ProbeConfigError(reason: "probe type stdout_regex needs a pattern that is a valid regular expression")
        }
        self.pattern = pattern
        self.regex = regex
    }

    func feed(line: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let range = NSRange(line.startIndex..., in: line)
        if let match = regex.firstMatch(in: line, range: range) {
            matched = true
            if let swiftRange = Range(match.range, in: line) {
                return String(line[swiftRange])
            }
            return line
        }
        return nil
    }

    func check() async -> Bool {
        lock.withLock { matched }
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        matched = false
    }
}
