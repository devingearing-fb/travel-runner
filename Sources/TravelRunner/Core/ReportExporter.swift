import Foundation

/// "Report a problem": one zip in Downloads that the owner of the runner can read
/// without the teammate's Mac, and a three-line summary for Slack.
///
/// The zip has one folder, `TravelRunner-report-<yyyyMMdd-HHmm>-v<version>`:
///
///     README.txt        what the files are
///     summary.txt       the Slack summary
///     diagnostics.json  this Mac and the stack (`DiagnosticsSnapshot`)
///     logs/<id>.log     the tail of each log, with times
///     issues/<status>/<id>/   the newest open issues, and the issue it was made from
///     events.jsonl      the events that file no issue
///
/// Every text goes through the redactor. Nothing is sent anywhere.
struct ReportExporter: Sendable {
    /// What the person pressed "Report" on. It decides the last line of the summary.
    enum Focus: Sendable, Equatable {
        case general
        case service(id: String)
        case dbStep(id: String)
        case issue(id: String, status: String)
    }

    /// What goes in the report. The supervisor reads it; tests make one.
    struct Input: Sendable {
        var snapshot: DiagnosticsSnapshot
        var redactor: Redactor
        var focus: Focus = .general
        /// One line about the failure the report is for: a cause, a step error,
        /// an issue summary. Nil when nothing is known.
        var focusText: String?
        /// The folder of the log files (`LogFileSink`). Nil when there are none.
        var logDirectory: URL?
        /// The logs in memory, by id. They fill in for an id without a file.
        var memoryLogs: [String: [LogEntry]] = [:]
        /// Issue folders to copy, each with its status ("open" or "closed").
        var issueFolders: [(status: String, folder: URL)] = []
        var eventsFile: URL?
    }

    struct Report: Sendable, Equatable {
        let zipURL: URL
        let summary: String
        /// True when macOS did not let the app write to Downloads and the zip
        /// went to `fallbackDestination`.
        var inFallback = false

        /// The toast for this report.
        var message: String { inFallback ? ReportExporter.fallbackSavedMessage : ReportExporter.savedMessage }
    }

    enum ExportError: Error, LocalizedError, Equatable {
        case alreadyRunning
        case stagingFailed(String)
        case zipFailed(String)
        /// macOS did not let the app write to Downloads, and no other folder worked.
        case notPermitted

        var errorDescription: String? {
            switch self {
            case .alreadyRunning:
                "a report is already being saved. Wait for it to finish, then try again."
            case .stagingFailed(let reason):
                "the report folder could not be written (\(reason)). Free some disk space, then press Report again."
            case .zipFailed(let reason):
                "the zip could not be made (\(reason)). Press Report again. If it fails again, use Copy Diagnostics Bundle under Diagnostics and paste that in Slack."
            case .notPermitted:
                ReportExporter.notPermittedMessage()
            }
        }
    }

    // MARK: - Text

    /// The toast after a report was saved.
    static let savedMessage = "Report saved to Downloads and summary copied. Attach the zip in Slack for Devin."
    /// The toast after a report was saved outside Downloads.
    static var fallbackSavedMessage: String { fallbackSavedMessage() }
    static func fallbackSavedMessage(appName: String = Flavor.current.displayName) -> String {
        "\(appName) may not save to Downloads, so the report is in Application Support (shown in Finder). Summary copied. Attach the zip in Slack for Devin."
    }
    /// The error when no folder worked. It names the app as Files and Folders lists it.
    static func notPermittedMessage(appName: String = Flavor.current.displayName) -> String {
        "\(appName) may not save to Downloads. Allow it in System Settings > Privacy & Security > Files and Folders, then press Report again."
    }
    /// The sheet before the first report.
    static let privacyNotice = "This report contains logs from your local services. Secrets are masked. Review the folder before sharing."

    // MARK: - Limits

    /// The last lines of each log that go in. A log file holds up to 5 MB.
    static let maxLogLines = 2000
    /// The newest open issues that go in.
    static let maxIssues = 10

    // MARK: - Setup

    /// Where the zip goes: Downloads.
    var destination: URL
    /// Where the zip goes when macOS does not let the app write to Downloads
    /// (a protected folder). It needs no permission prompt. Nil: no second try.
    var fallbackDestination: URL?
    /// Where the folder is put together before it is zipped.
    var temporaryDirectory: URL = FileManager.default.temporaryDirectory
    var timeZone: TimeZone = .current
    var now: @Sendable () -> Date = { Date() }
    /// Makes `archive` from `folder`, with the folder in it. Tests give a fake.
    var zip: @Sendable (_ folder: URL, _ archive: URL) async -> CommandResult = Self.ditto

    /// The exporter of the app: the zip goes to Downloads.
    static func live() -> ReportExporter {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let reports = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/\(Flavor.current.displayName)/reports")
        return ReportExporter(destination: downloads, fallbackDestination: reports)
    }

    /// True when the zip step failed because macOS did not allow the write.
    static func isPermissionError(_ result: CommandResult) -> Bool {
        let text = (result.stderr + "\n" + result.stdout).lowercased()
        return text.contains("operation not permitted") || text.contains("permission denied")
    }

    /// `ditto` makes the zip that Finder makes. It is part of macOS.
    static let ditto: @Sendable (URL, URL) async -> CommandResult = { folder, archive in
        await Shell.execute(
            "/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, archive.path],
            timeout: .seconds(120)
        )
    }

    // MARK: - Names

    /// `TravelRunner-report-20261116-0914-v0.13.5`, without `.zip`.
    static func baseName(version: String?, date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let version = LogFileSink.fileName(for: version ?? "dev")
        return "TravelRunner-report-\(formatter.string(from: date))-v\(version)"
    }

    /// The zip name that is free in the folder: a second report in the same
    /// minute gets `-2`, then `-3`.
    static func freeName(_ base: String, in folder: URL, exists: (String) -> Bool) -> String {
        var name = base
        var index = 2
        while exists(folder.appendingPathComponent("\(name).zip").path) {
            name = "\(base)-\(index)"
            index += 1
        }
        return name
    }

    // MARK: - Summary

    /// Three lines for Slack: which runner and Mac, the state of the stack, and
    /// what failed.
    static func summary(_ input: Input, zipName: String) -> String {
        let snapshot = input.snapshot
        let version = snapshot.app.version.map { "v\($0)" } ?? "dev build"
        let commit = snapshot.app.commit.map { " (\($0))" } ?? ""
        let macOS = snapshot.machine.macOS.replacingOccurrences(of: "Version ", with: "")
        let first = "\(appName(snapshot)) \(version)\(commit) on macOS \(macOS), \(snapshot.machine.arch): \(zipName)"

        var failed = snapshot.services.filter { $0.phase == ServicePhase.failed.rawValue || $0.circuitBroken }.map(\.id)
        failed += (snapshot.dbPipeline?.steps ?? [])
            .filter { $0.status == DbStepStatus.failed.rawValue || $0.status == DbStepStatus.timedOut.rawValue }
            .map { "DB step \($0.id)" }
        let failedText = failed.isEmpty ? "nothing failed" : "failed: \(failed.joined(separator: ", "))"
        let second = "Health \(snapshot.health) · profile \(snapshot.profile) · DB \(snapshot.dbMode) · \(failedText)"

        let subject: String? = switch input.focus {
        case .general: nil
        case .service(let id): id
        case .dbStep(let id): "DB step \(id)"
        case .issue(let id, _): "issue \(id)"
        }
        let text = (input.focusText ?? snapshot.lastError).map { oneLine(input.redactor.redact($0)) }
        let third: String = switch (subject, text) {
        case (let subject?, let text?): "Problem: \(subject): \(text)"
        case (let subject?, nil): "Problem: \(subject)"
        case (nil, let text?): "Problem: \(text)"
        case (nil, nil): "Problem: (say what you saw)"
        }
        return [first, second, third].joined(separator: "\n")
    }

    private static func appName(_ snapshot: DiagnosticsSnapshot) -> String {
        (Flavor(rawValue: snapshot.app.flavor) ?? .standard).displayName
    }

    /// One line, at most 200 characters.
    private static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return flat.count > 200 ? String(flat.prefix(199)) + "…" : flat
    }

    // MARK: - Export

    /// Builds the folder, zips it into Downloads and deletes the folder. A zip
    /// that failed half way is deleted too. When macOS does not let the app
    /// write to Downloads, the zip goes to `fallbackDestination`.
    func export(_ input: Input) async throws -> Report {
        let date = now()
        do {
            return try await export(input, into: destination, date: date)
        } catch ExportError.notPermitted {
            guard let fallbackDestination else { throw ExportError.notPermitted }
            var report = try await export(input, into: fallbackDestination, date: date)
            report.inFallback = true
            return report
        }
    }

    private func export(_ input: Input, into destination: URL, date: Date) async throws -> Report {
        let fm = FileManager.default
        let base = Self.baseName(version: input.snapshot.app.version, date: date, timeZone: timeZone)
        let name = Self.freeName(base, in: destination) { fm.fileExists(atPath: $0) }
        let zipURL = destination.appendingPathComponent("\(name).zip")
        let summary = Self.summary(input, zipName: zipURL.lastPathComponent)

        let staging = temporaryDirectory.appendingPathComponent("travel-runner-report-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        let folder = staging.appendingPathComponent(name)
        do {
            try stage(input, summary: summary, into: folder)
        } catch {
            throw ExportError.stagingFailed(error.localizedDescription)
        }

        try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = await zip(folder, zipURL)
        guard result.succeeded, fm.fileExists(atPath: zipURL.path) else {
            try? fm.removeItem(at: zipURL)
            if Self.isPermissionError(result) { throw ExportError.notPermitted }
            let reason = result.timedOut ? "ditto did not finish in time"
                : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isNewline).last
                    .map(String.init) ?? "ditto exit code \(result.exitCode)"
            throw ExportError.zipFailed(reason)
        }
        // Only this user reads the logs in it.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: zipURL.path)
        return Report(zipURL: zipURL, summary: summary)
    }

    /// Writes the report folder. Tests read it before it is zipped.
    func stage(_ input: Input, summary: String, into folder: URL) throws {
        let fm = FileManager.default
        let redactor = input.redactor
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        try write(Self.readme, to: folder.appendingPathComponent("README.txt"))
        try write(summary + "\n", to: folder.appendingPathComponent("summary.txt"))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let diagnostics = try encoder.encode(input.snapshot.redacted(by: redactor))
        try write(String(decoding: diagnostics, as: UTF8.self) + "\n", to: folder.appendingPathComponent("diagnostics.json"))

        let logs = folder.appendingPathComponent("logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        var written: Set<String> = []
        if let directory = input.logDirectory {
            for file in currentLogFiles(in: directory) {
                guard let data = try? Data(contentsOf: file) else { continue }
                var tail = Self.lines(data).suffix(Self.maxLogLines)
                // Just after the sink rotated the file, its earlier lines are in `<id>.1.log`.
                if tail.count < Self.maxLogLines,
                   let rotated = try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("1.log")) {
                    tail = Self.lines(rotated).suffix(Self.maxLogLines - tail.count) + tail
                }
                let lines = tail.map { redactor.redact(String($0)) }
                try write(lines.joined(separator: "\n") + "\n", to: logs.appendingPathComponent(file.lastPathComponent))
                written.insert(file.lastPathComponent)
            }
        }
        // An id without a file (no sink, or a write that failed) has its lines in memory.
        let formatter = Self.lineFormatter(timeZone)
        for id in input.memoryLogs.keys.sorted() {
            let fileName = "\(LogFileSink.fileName(for: id)).log"
            guard !written.contains(fileName), let entries = input.memoryLogs[id], !entries.isEmpty else { continue }
            let lines = entries.suffix(Self.maxLogLines).map { entry in
                "\(formatter.string(from: entry.timestamp)) [\(entry.stream == .stdout ? "out" : "err")] \(redactor.redact(entry.text))"
            }
            try write(lines.joined(separator: "\n") + "\n", to: logs.appendingPathComponent(fileName))
        }

        for (status, source) in input.issueFolders {
            guard let files = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey])
            else { continue }
            let target = folder.appendingPathComponent("issues").appendingPathComponent(status)
                .appendingPathComponent(source.lastPathComponent)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for file in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                guard let data = try? Data(contentsOf: file) else { continue }
                // The files were redacted when they were written; an older folder may not be.
                try write(redactor.redact(String(decoding: data, as: UTF8.self)), to: target.appendingPathComponent(file.lastPathComponent))
            }
        }

        if let events = input.eventsFile, let data = try? Data(contentsOf: events) {
            try write(redactor.redact(String(decoding: data, as: UTF8.self)), to: folder.appendingPathComponent("events.jsonl"))
        }
    }

    /// The `.log` files of the folder, without the rotated ones (`<id>.1.log`).
    private func currentLogFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "log" }
            .filter { url in
                let stem = url.deletingPathExtension().pathExtension
                return stem.isEmpty || !stem.allSatisfy(\.isNumber)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func lines(_ data: Data) -> [Substring] {
        String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The time format of the log files.
    private static func lineFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }

    static let readme = """
        Travel Runner problem report

        summary.txt       The three lines that were copied for Slack.
        diagnostics.json  The app version, macOS, the tools and their PATH, the profile,
                          the database mode, the start checks, the DB setup steps,
                          pending migrations, the repo paths and each service.
        logs/             The last \(maxLogLines) lines of each log, with times.
        issues/           The newest open issues that the runner saved on this Mac.
        events.jsonl      Events that file no issue: Stripe skips, outside kills, breaker trips.

        Secret values are replaced with ‹redacted:kind›. Read the files before you share them.

        """
}
