import Foundation

/// What the system says about one process.
struct ProcessFacts: Equatable, Sendable {
    let pid: pid_t
    /// When the process started, in microseconds since 1970. With the pid it names
    /// one process: the system gives the pid of a dead process to a new one.
    let startTime: Int64
    /// The working directory, or nil when the system does not give it.
    var cwd: String? = nil
    var arguments: [String] = []
}

/// The processes that Travel Runner started, on disk, so that the next launch knows
/// them after a crash or a relaunch for an update.
///
/// The file is `~/.config/<storage name>/launches.json`. It holds no environment:
/// the command is the command of the service, and a key such as `STRIPE_API_KEY`
/// goes to the process environment only.
final class LaunchLedger: @unchecked Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let serviceID: String
        let pid: Int32
        let startTime: Int64
        let cwd: String?
        let command: [String]
    }

    private struct File: Codable {
        var launches: [Entry]
    }

    /// Nil keeps the entries in memory only (tests, and a supervisor that the app did not give a file).
    let path: String?
    private let lock = NSLock()
    private var stored: [Entry]
    /// The pids that this run of the app started.
    private var session: Set<pid_t> = []

    init(path: String?) {
        self.path = path
        stored = path.flatMap(Self.read) ?? []
    }

    static func live() -> LaunchLedger {
        LaunchLedger(path: livePath)
    }

    static var livePath: String {
        (LaunchEnvironment.configDir() as NSString).appendingPathComponent("launches.json")
    }

    var entries: [Entry] {
        lock.withLock { stored }
    }

    var sessionPIDs: Set<pid_t> {
        lock.withLock { session }
    }

    /// Records a process that this run started. Without its start time (the
    /// process is already gone) there is nothing to record.
    func record(serviceID: String, pid: pid_t, cwd: String?, command: [String], facts: (pid_t) -> ProcessFacts?) {
        guard let startTime = facts(pid)?.startTime else { return }
        let entry = Entry(serviceID: serviceID, pid: pid, startTime: startTime, cwd: cwd, command: command)
        change {
            session.insert(pid)
            stored.removeAll { $0.pid == pid }
            stored.append(entry)
        }
    }

    func remove(pids: some Sequence<pid_t>) {
        let pids = Set(pids)
        guard !pids.isEmpty else { return }
        change {
            session.subtract(pids)
            stored.removeAll { pids.contains($0.pid) }
        }
    }

    /// The entries whose process still runs: the same pid with the same start time.
    func live(facts: (pid_t) -> ProcessFacts?) -> [Entry] {
        entries.filter { facts($0.pid)?.startTime == $0.startTime }
    }

    /// The live entries of an earlier run of the app.
    func leftovers(facts: (pid_t) -> ProcessFacts?) -> [Entry] {
        let session = sessionPIDs
        return live(facts: facts).filter { !session.contains($0.pid) }
    }

    /// Forgets the entries whose process is gone.
    func prune(facts: (pid_t) -> ProcessFacts?) {
        let gone = entries.filter { facts($0.pid)?.startTime != $0.startTime }.map(\.pid)
        remove(pids: gone)
    }

    private func change(_ body: () -> Void) {
        lock.withLock {
            body()
            if let path { Self.write(stored, to: path) }
        }
    }

    private static func read(_ path: String) -> [Entry]? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONDecoder().decode(File.self, from: data))?.launches
    }

    /// Only this user can read the file: it names the folders and the commands.
    private static func write(_ entries: [Entry], to path: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(launches: entries)) else { return }
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        guard (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
