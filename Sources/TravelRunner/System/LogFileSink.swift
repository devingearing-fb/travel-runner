import Foundation

/// Writes the log of each service to a file, so the log outlives the 500-line
/// view and a quit of the app.
///
/// One file per log id: `~/Library/Logs/<app name>/<id>.log`. Each line is
/// `2026-11-16T09:14:03.412-0700 [out] text` (or `[err]`).
///
/// The files hold the raw output, readable by the owner only (mode 0600). Text
/// that leaves the app goes through `Redactor`. The log with the id `runner` is
/// the exception: its lines are redacted before they are written.
///
/// A file that reaches 5 MB becomes `<id>.1.log`, and three old files are kept.
/// Files with no write for 14 days are deleted.
///
/// A write that fails is dropped. The log file must never stop a service.
final class LogFileSink: @unchecked Sendable {
    /// The log of the runner itself. Its lines are redacted at write time.
    static let runnerLogID = "runner"

    let directory: URL
    private let maxBytes: Int
    private let keptFiles: Int
    private let maxAge: TimeInterval
    private let version: String
    private let now: @Sendable () -> Date
    private let formatter: DateFormatter

    private let lock = NSLock()
    private var files: [String: OpenFile] = [:]
    private var lastPrune: Date
    private var runnerRedactor: Redactor = .patterns

    private struct OpenFile {
        let descriptor: Int32
        var size: Int
    }

    /// The folder of the installed app: `~/Library/Logs/Travel Runner`.
    static func defaultDirectory(flavor: Flavor = .current) -> URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs").appendingPathComponent(flavor.displayName)
    }

    /// The sink of the app. Tests make their own, in a temporary folder.
    static func live() -> LogFileSink {
        LogFileSink(directory: defaultDirectory(), version: BuildInfo.current.version ?? "dev")
    }

    init(
        directory: URL,
        version: String,
        maxBytes: Int = 5 * 1024 * 1024,
        keptFiles: Int = 3,
        maxAgeDays: Int = 14,
        timeZone: TimeZone = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.version = version
        self.maxBytes = maxBytes
        self.keptFiles = max(0, keptFiles)
        self.maxAge = TimeInterval(maxAgeDays) * 86_400
        self.now = now
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        self.formatter = formatter
        self.lastPrune = now()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        deleteOldFiles()
    }

    deinit {
        for file in files.values { close(file.descriptor) }
    }

    // MARK: - Paths

    /// The file of one log id. An id is a file name here, so any character
    /// outside letters, digits, `.`, `_` and `-` becomes `_`.
    func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(Self.fileName(for: id)).log")
    }

    private func rotatedURL(for id: String, index: Int) -> URL {
        directory.appendingPathComponent("\(Self.fileName(for: id)).\(index).log")
    }

    static func fileName(for id: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let name = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "_" : trimmed
    }

    // MARK: - Writing

    /// The redactor for the `runner` log. The supervisor sets it when it knows
    /// the env files of the services.
    func setRunnerRedactor(_ redactor: Redactor) {
        lock.lock()
        defer { lock.unlock() }
        runnerRedactor = redactor
    }

    func write(id: String, entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var text = ""
        for entry in entries {
            text += line(id: id, timestamp: entry.timestamp, stream: entry.stream, text: entry.text)
        }
        append(text, id: id)
    }

    /// The separator at each start of a process. It opens the file again, so a
    /// file that someone deleted comes back at the next start.
    func writeStart(id: String, name: String, pid: Int32) {
        lock.lock()
        defer { lock.unlock() }
        closeFile(id)
        let text = "[travel-runner] ── started \(name) pid \(pid) (runner v\(version)) ──"
        append(line(id: id, timestamp: now(), stream: .stdout, text: text), id: id)
    }

    /// One line of the file for each line of the text.
    private func line(id: String, timestamp: Date, stream: LogEntry.Stream, text: String) -> String {
        let prefix = "\(formatter.string(from: timestamp)) [\(stream == .stdout ? "out" : "err")] "
        let body = id == Self.runnerLogID ? runnerRedactor.redact(text) : text
        return body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { prefix + $0 + "\n" }
            .joined()
    }

    private func append(_ text: String, id: String) {
        deleteOldFilesIfDue()
        let data = Array(text.utf8)
        guard !data.isEmpty, var file = files[id] ?? open(id) else { return }
        if file.size > 0, file.size + data.count > maxBytes {
            close(file.descriptor)
            files[id] = nil
            rotate(id)
            guard let fresh = open(id) else { return }
            file = fresh
        }
        var offset = 0
        while offset < data.count {
            let written = data[offset...].withUnsafeBytes { Darwin.write(file.descriptor, $0.baseAddress, $0.count) }
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { break }
            offset += written
        }
        file.size += offset
        files[id] = file
    }

    private func open(_ id: String) -> OpenFile? {
        let path = fileURL(for: id).path
        var descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if descriptor < 0, errno == ENOENT {
            // The folder is gone (someone deleted it). Make it again.
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { return nil }
        // An older file can have a wider mode.
        fchmod(descriptor, 0o600)
        var info = stat()
        let size = fstat(descriptor, &info) == 0 ? Int(info.st_size) : 0
        return OpenFile(descriptor: descriptor, size: size)
    }

    private func closeFile(_ id: String) {
        guard let file = files.removeValue(forKey: id) else { return }
        close(file.descriptor)
    }

    // MARK: - Rotation and age

    /// `<id>.log` becomes `<id>.1.log`, `.1` becomes `.2`, and the oldest goes.
    private func rotate(_ id: String) {
        let fm = FileManager.default
        guard keptFiles > 0 else {
            try? fm.removeItem(at: fileURL(for: id))
            return
        }
        try? fm.removeItem(at: rotatedURL(for: id, index: keptFiles))
        for index in stride(from: keptFiles - 1, through: 1, by: -1) {
            try? fm.moveItem(at: rotatedURL(for: id, index: index), to: rotatedURL(for: id, index: index + 1))
        }
        try? fm.moveItem(at: fileURL(for: id), to: rotatedURL(for: id, index: 1))
    }

    /// The app can run for weeks, so the check runs once an hour too.
    private func deleteOldFilesIfDue() {
        let current = now()
        guard current.timeIntervalSince(lastPrune) >= 3600 else { return }
        lastPrune = current
        deleteOldFiles()
    }

    /// Deletes the `.log` files with no write for 14 days. Other files stay.
    private func deleteOldFiles() {
        let fm = FileManager.default
        let cutoff = now().addingTimeInterval(-maxAge)
        let urls = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        )) ?? []
        var deleted = false
        for url in urls where url.pathExtension == "log" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified < cutoff else { continue }
            try? fm.removeItem(at: url)
            deleted = true
        }
        // An open file can be one of the deleted. The next write opens a new one.
        if deleted {
            for file in files.values { close(file.descriptor) }
            files.removeAll()
        }
    }
}
