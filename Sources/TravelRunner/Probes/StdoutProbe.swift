import Foundation

final class StdoutProbe: Probe, @unchecked Sendable {
    private let pattern: String
    private let regex: NSRegularExpression
    private var matched = false
    private let lock = NSLock()

    init(pattern: String) {
        self.pattern = pattern
        self.regex = try! NSRegularExpression(pattern: pattern)
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
