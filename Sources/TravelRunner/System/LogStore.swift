import Foundation

enum LogLevel: String, Sendable, CaseIterable {
    case error = "ERR"
    case warning = "WRN"
    case info = "INF"
    case debug = "DBG"
}

struct LogEntry: Sendable, Identifiable {
    let id: UUID
    let timestamp: Date
    let stream: Stream
    let text: String
    let level: LogLevel?

    enum Stream: Sendable {
        case stdout, stderr
    }

    init(timestamp: Date = .now, stream: Stream, text: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.stream = stream
        self.text = text
        self.level = Self.classify(text: text, stream: stream)
    }

    private static func classify(text: String, stream: Stream) -> LogLevel? {
        let raw = text.trimmingCharacters(in: .whitespaces)

        if raw.hasPrefix("{"),
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let num = json["level"] as? Int {
            return switch num {
            case 50...: .error
            case 40..<50: .warning
            case 30..<40: .info
            default: .debug
            }
        }

        let lower = raw.lowercased()
        if raw.contains("\u{2A2F}") || lower.contains("module not found") { return .error }
        if raw.contains("\u{26A0}") || (stream == .stderr && lower.contains("warn")) { return .warning }
        if raw.hasPrefix("    at ") || raw.hasPrefix("          ") { return .debug }

        return nil
    }
}

struct LogCounts: Sendable {
    var error: Int = 0
    var warning: Int = 0
    var info: Int = 0
    var debug: Int = 0
}

/// The thing in Finder that "Show Log File" goes to.
enum LogRevealTarget: Equatable, Sendable {
    case file(URL)
    case folder(URL)
}

actor LogStore {
    private var buffers: [String: RingBuffer<LogEntry>] = [:]
    private var levelCounts: [String: LogCounts] = [:]
    private var versions: [String: Int] = [:]
    private let capacity = 500
    /// The files on disk. Nil keeps the log in memory only, as the tests do.
    private let sink: LogFileSink?

    init(sink: LogFileSink? = nil) {
        self.sink = sink
    }

    /// The log file of one id. Nil when the store writes no files.
    nonisolated func fileURL(for serviceID: String) -> URL? {
        sink?.fileURL(for: serviceID)
    }

    /// The last lines that an earlier run of the app wrote to the log of the id.
    /// Empty when the store writes no files.
    nonisolated func earlierRunTail(for serviceID: String, maxLines: Int) -> [LogEntry] {
        sink?.earlierRunTail(id: serviceID, maxLines: maxLines) ?? []
    }

    /// What "Show Log File" shows: the log file of the id, or the log folder
    /// when the file is not there (no line was written yet, or the cleanup
    /// removed it). Nil when the store writes no files.
    nonisolated func revealTarget(for serviceID: String) -> LogRevealTarget? {
        guard let sink else { return nil }
        let file = sink.fileURL(for: serviceID)
        if FileManager.default.fileExists(atPath: file.path) { return .file(file) }
        return .folder(file.deletingLastPathComponent())
    }

    /// Writes the separator of a process start to the log file. The view does
    /// not show it.
    func markStart(serviceID: String, name: String, pid: Int32) {
        sink?.writeStart(id: serviceID, name: name, pid: pid)
    }

    /// The `runner` log file gets its lines redacted with this redactor.
    func setRunnerRedactor(_ redactor: Redactor) {
        sink?.setRunnerRedactor(redactor)
    }

    func append(serviceID: String, entry: LogEntry) {
        sink?.write(id: serviceID, entries: [entry])
        if buffers[serviceID] == nil {
            buffers[serviceID] = RingBuffer(capacity: capacity)
        }
        buffers[serviceID]!.append(entry)
        versions[serviceID, default: 0] += 1
        incrementCounts(serviceID: serviceID, level: entry.level)
    }

    func appendBatch(serviceID: String, entries: [LogEntry]) {
        sink?.write(id: serviceID, entries: entries)
        if buffers[serviceID] == nil {
            buffers[serviceID] = RingBuffer(capacity: capacity)
        }
        for entry in entries {
            buffers[serviceID]!.append(entry)
            incrementCounts(serviceID: serviceID, level: entry.level)
        }
        versions[serviceID, default: 0] += 1
    }

    private func incrementCounts(serviceID: String, level: LogLevel?) {
        guard let level else { return }
        if levelCounts[serviceID] == nil { levelCounts[serviceID] = LogCounts() }
        switch level {
        case .error: levelCounts[serviceID]!.error += 1
        case .warning: levelCounts[serviceID]!.warning += 1
        case .info: levelCounts[serviceID]!.info += 1
        case .debug: levelCounts[serviceID]!.debug += 1
        }
    }

    func entries(for serviceID: String) -> [LogEntry] {
        buffers[serviceID]?.allElements ?? []
    }

    func version(for serviceID: String) -> Int {
        versions[serviceID] ?? 0
    }

    func counts(for serviceID: String) -> LogCounts {
        levelCounts[serviceID] ?? LogCounts()
    }

    /// Clears the view. The log file is kept.
    func clear(serviceID: String) {
        buffers[serviceID] = nil
        levelCounts[serviceID] = nil
        versions[serviceID] = 0
    }

    func clearAll() {
        buffers.removeAll()
        levelCounts.removeAll()
        versions.removeAll()
    }

    func allEntries() -> [LogEntry] {
        buffers.values
            .flatMap(\.allElements)
            .sorted { $0.timestamp < $1.timestamp }
    }

    func allVersion() -> Int {
        versions.values.reduce(0, +)
    }

    func serviceIDs() -> [String] {
        Array(buffers.keys)
    }
}

struct RingBuffer<Element: Sendable>: Sendable {
    private var storage: [Element] = []
    private var writeIndex: Int = 0
    private var isFull: Bool = false
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[writeIndex] = element
            isFull = true
        }
        writeIndex = (writeIndex + 1) % capacity
    }

    var allElements: [Element] {
        if !isFull { return storage }
        return Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
    }

    var count: Int {
        isFull ? capacity : storage.count
    }
}
