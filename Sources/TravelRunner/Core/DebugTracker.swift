import Foundation
import CryptoKit

actor DebugTracker {

    // MARK: - Config types

    struct DebugTrackingConfig: Codable {
        /// A config without this key means on, like no config at all.
        let enabled: Bool?
        let autoCapture: AutoCaptureConfig?
        let logLines: LogLinesConfig?
        let dedupWindowSeconds: Int?
        /// Closed issues older than this are deleted. Zero or less keeps them all.
        let closedRetentionDays: Int?

        struct AutoCaptureConfig: Codable {
            let serviceCrash: Bool?
            let circuitBreaker: Bool?
            let dbSetupFailure: Bool?
            let preflightFailure: Bool?
            let probeTimeout: Bool?
            let uncleanExit: Bool?

            enum CodingKeys: String, CodingKey {
                case serviceCrash = "service_crash"
                case circuitBreaker = "circuit_breaker"
                case dbSetupFailure = "db_setup_failure"
                case preflightFailure = "preflight_failure"
                case probeTimeout = "probe_timeout"
                case uncleanExit = "unclean_exit"
            }
        }

        struct LogLinesConfig: Codable {
            let failingService: Int?
            let otherServices: Int?

            enum CodingKeys: String, CodingKey {
                case failingService = "failing_service"
                case otherServices = "other_services"
            }
        }

        enum CodingKeys: String, CodingKey {
            case enabled
            case autoCapture = "auto_capture"
            case logLines = "log_lines"
            case dedupWindowSeconds = "dedup_window_seconds"
            case closedRetentionDays = "closed_retention_days"
        }
    }

    // MARK: - Location

    /// Where the issues are. `isDesktop` marks the folder from before capture was
    /// on by default.
    struct Location: Equatable, Sendable {
        let path: String
        let isDesktop: Bool
    }

    /// A person who made a config in the Desktop folder keeps that folder. Everyone
    /// else gets a folder in Application Support, which needs no permission prompt.
    static func resolveLocation(
        flavor: Flavor = .current,
        home: String = NSHomeDirectory(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Location {
        let desktop = "\(home)/Desktop/\(flavor.debugTrackingFolder)"
        if fileExists("\(desktop)/config.json") {
            return Location(path: desktop, isDesktop: true)
        }
        return Location(
            path: "\(home)/Library/Application Support/\(flavor.displayName)/issues",
            isDesktop: false
        )
    }

    /// Resolved once for each launch, so the Desktop is looked at once.
    static let defaultLocation = resolveLocation()

    // MARK: - Limits

    /// An issue keeps the times of its newest recurrences. The count keeps them all.
    static let maxRecurrenceTimestamps = 20
    /// Closed issues older than this are deleted.
    static let closedRetentionDays = 30
    /// `events.jsonl` moves to `events.1.jsonl` at this size.
    static let maxEventsBytes = 1_000_000

    // MARK: - Event model

    /// One line of `events.jsonl`: something worth counting that files no issue.
    struct Event: Codable, Equatable {
        var at: String
        var kind: String
        var serviceId: String?
        var message: String
        var appVersion: String?

        enum CodingKeys: String, CodingKey {
            case at, kind, message
            case serviceId = "service_id"
            case appVersion = "app_version"
        }
    }

    // MARK: - Issue model

    struct Issue: Codable {
        var id: String
        var summary: String
        var status: String
        var severity: String
        var category: String
        var trigger: String
        var serviceId: String?
        var errorSignature: String
        var errorMessage: String
        /// The line of the service's output that best explains the failure. Issues
        /// from before this field have none.
        var likelyCause: String?
        /// The build of the app that filed the issue. Issues from before these
        /// fields have none.
        var appVersion: String?
        var appBuild: String?
        var appCommit: String?
        var appBuildKind: String?
        var appFlavor: String?
        /// The build of the app at the last recurrence. Nil until the issue recurs.
        var lastAppVersion: String?
        var lastAppBuild: String?
        var lastAppCommit: String?
        var createdAt: String
        var updatedAt: String
        var resolvedAt: String?
        var resolution: String?
        var recurrenceCount: Int
        var recurrenceTimestamps: [String]

        enum CodingKeys: String, CodingKey {
            case id, summary, status, severity, category, trigger
            case serviceId = "service_id"
            case errorSignature = "error_signature"
            case errorMessage = "error_message"
            case likelyCause = "likely_cause"
            case appVersion = "app_version"
            case appBuild = "app_build"
            case appCommit = "app_commit"
            case appBuildKind = "app_build_kind"
            case appFlavor = "app_flavor"
            case lastAppVersion = "last_app_version"
            case lastAppBuild = "last_app_build"
            case lastAppCommit = "last_app_commit"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case resolvedAt = "resolved_at"
            case resolution
            case recurrenceCount = "recurrence_count"
            case recurrenceTimestamps = "recurrence_timestamps"
        }
    }

    // MARK: - Run marker

    /// `running.marker`: this app runs. A clean quit deletes it, so a marker
    /// that is there at launch is a run that crashed, was force-quit or lost power.
    struct RunMarker: Codable, Equatable, Sendable {
        var pid: Int32
        var startedAt: String
        var appVersion: String?
        var appBuild: String?
        var appCommit: String?

        enum CodingKeys: String, CodingKey {
            case pid
            case startedAt = "started_at"
            case appVersion = "app_version"
            case appBuild = "app_build"
            case appCommit = "app_commit"
        }
    }

    // MARK: - Log entry

    struct LogEntry: Sendable {
        let timestamp: Date
        let serviceId: String
        let line: String
    }

    // MARK: - Paths

    private let baseDir: String
    private let configPath: String
    private let openDir: String
    private let closedDir: String
    private let eventsPath: String
    /// A clean quit deletes this file from outside the actor.
    nonisolated let runMarkerPath: String
    private let buildInfo: BuildInfo
    private let rateLimitSeconds: TimeInterval
    private let defaultRetentionDays: Int?
    private let now: @Sendable () -> Date
    /// True for every folder but the Desktop one: only the user reads the files.
    private let privateFiles: Bool
    /// The last capture of each signature, for the rate limit.
    private var lastCaptureAt: [String: Date] = [:]
    /// The repeats that the rate limit dropped, for each signature. The next
    /// write of the issue adds them to its count.
    private var droppedRepeats: [String: Int] = [:]

    private let fm = FileManager.default
    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let jsonDecoder = JSONDecoder()
    /// The `diagnostics.json` writes that run after their issue was filed.
    private var pendingDiagnostics: [Int: Task<Void, Never>] = [:]
    private var nextDiagnosticsID = 0

    // MARK: - Normalisation patterns

    private static let iso8601Regex = try! NSRegularExpression(
        pattern: #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})?"#
    )
    private static let pidRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:pid)\s*[=:]?\s*\d+"#
    )
    private static let uuidRegex = try! NSRegularExpression(
        pattern: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#
    )
    private static let hexAddrRegex = try! NSRegularExpression(
        pattern: #"0x[0-9a-fA-F]{6,}"#
    )
    // A cause is a raw log line, so it has more parts that vary from crash to crash.
    /// A date and time, with a `T` or a space: `2026-11-17 10:52:49.123 UTC`.
    private static let causeTimestampRegex = try! NSRegularExpression(
        pattern: #"\d{4}-\d{2}-\d{2}[T ]\d{1,2}:\d{2}:\d{2}(?:[.,]\d+)?(?:\s?(?:Z|[+-]\d{2}:?\d{2}|[A-Z]{3,4})\b)?"#
    )
    /// A time of day: `10:52:49` or `10:52:49.123`.
    private static let causeTimeRegex = try! NSRegularExpression(
        pattern: #"\b\d{1,2}:\d{2}:\d{2}(?:[.,]\d+)?\b"#
    )
    /// A random temp name after `tmp.` or `tmp-`, or a run of 8 or more letters
    /// and digits with a digit in it after `.`, `-` or `_`: `_buildManifest.js.tmp.o8dzt0rqxf`.
    private static let causeRandomNameRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:(?<=tmp[.\-_])[0-9a-z]{6,}|(?<=[.\-_])(?=[0-9a-z]*\d)[0-9a-z]{8,})\b"#
    )
    /// Any run of 3 or more digits, and any number in brackets: pids, ports,
    /// durations, counts. `postgres[61]` in a container has a short pid.
    private static let causeNumberRegex = try! NSRegularExpression(pattern: #"\d{3,}|(?<=[\[(])\d+(?=[\])])"#)

    // MARK: - Init

    /// - Parameters:
    ///   - baseDir: The issue folder. Without it, the folder of this app (`defaultLocation`).
    ///   - rateLimitSeconds: One automatic capture for each signature in this time.
    ///     The rest write nothing; the next write adds them to the count. A manual
    ///     capture has no limit.
    ///   - prunesClosedIssues: Without it, every folder but the Desktop one prunes.
    ///     The Desktop folder is a hand-kept archive: it prunes only when its config
    ///     has `closed_retention_days`.
    init(
        baseDir: String? = nil,
        buildInfo: BuildInfo = .current,
        rateLimitSeconds: TimeInterval = 60,
        prunesClosedIssues: Bool? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.buildInfo = buildInfo
        self.rateLimitSeconds = rateLimitSeconds
        self.now = now
        let location = baseDir.map { Location(path: $0, isDesktop: false) } ?? Self.defaultLocation
        self.defaultRetentionDays = (prunesClosedIssues ?? !location.isDesktop) ? Self.closedRetentionDays : nil
        self.privateFiles = !location.isDesktop
        let root = location.path
        self.baseDir = root
        self.configPath = (root as NSString).appendingPathComponent("config.json")
        self.openDir = (root as NSString).appendingPathComponent("open")
        self.closedDir = (root as NSString).appendingPathComponent("closed")
        self.eventsPath = (root as NSString).appendingPathComponent("events.jsonl")
        self.runMarkerPath = (root as NSString).appendingPathComponent("running.marker")
    }

    var folderPath: String { baseDir }
    var configFilePath: String { configPath }
    var eventsFilePath: String { eventsPath }

    // MARK: - Config

    func loadConfig() -> DebugTrackingConfig? {
        guard fm.fileExists(atPath: configPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? jsonDecoder.decode(DebugTrackingConfig.self, from: data)
        else { return nil }
        return config
    }

    /// Capture is on unless a config says no. A config that cannot be read counts
    /// as "no": it can be a hand-made opt-out with a typing error.
    func isEnabled() -> Bool {
        guard fm.fileExists(atPath: configPath) else { return true }
        guard let config = loadConfig() else { return false }
        return config.enabled ?? true
    }

    /// Writes the switch to the config and keeps the other keys. False when the
    /// file cannot be written.
    func setEnabled(_ enabled: Bool) -> Bool {
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        }
        config["enabled"] = enabled
        ensureDirectory(baseDir)
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func isAutoCaptureEnabled(trigger: String) -> Bool {
        guard isEnabled() else { return false }
        guard let auto = loadConfig()?.autoCapture else { return true }
        switch trigger {
        case "service_crash":     return auto.serviceCrash ?? true
        case "circuit_breaker":   return auto.circuitBreaker ?? true
        case "db_setup_failure":  return auto.dbSetupFailure ?? true
        case "preflight_failure": return auto.preflightFailure ?? true
        case "probe_timeout":     return auto.probeTimeout ?? true
        case "unclean_exit":      return auto.uncleanExit ?? true
        default:                  return true
        }
    }

    // MARK: - Capture

    func captureIssue(
        trigger: String,
        serviceId: String?,
        errorMessage: String,
        signatureText: String? = nil,
        severity: String = "error",
        category: String = "runtime",
        likelyCause: String? = nil,
        logEntries: [LogEntry] = [],
        stateSnapshots: [ServiceStateSnapshot] = [],
        redactor: Redactor = .patterns,
        diagnostics: (@Sendable () async -> DiagnosticsSnapshot?)? = nil
    ) async -> String? {
        guard isAutoCaptureEnabled(trigger: trigger) else { return nil }

        // Nothing goes into an issue before the redactor has seen it.
        let errorMessage = redactor.redact(errorMessage)
        let signatureText = signatureText.map(redactor.redact)
        let likelyCause = likelyCause.map(redactor.redact)

        let signature = Self.signature(
            trigger: trigger, serviceId: serviceId, message: signatureText ?? errorMessage, likelyCause: likelyCause
        )

        let config = loadConfig()
        // 7 days: recurring crashes (e.g. daily wake/network races) should bump
        // recurrence_count on the open issue, not file a new ticket each day.
        let dedupWindow = config?.dedupWindowSeconds ?? 604_800

        // Rate limit: a failure that repeats every few seconds is one write a
        // minute, not a write for each repeat. The repeats are still counted.
        // A report that a person files is never dropped.
        let now = self.now()
        let limited = trigger != "manual"
        if limited {
            lastCaptureAt = lastCaptureAt.filter { now.timeIntervalSince($0.value) < rateLimitSeconds }
            if lastCaptureAt[signature] != nil {
                droppedRepeats[signature, default: 0] += 1
                return nil
            }
        }
        let existing = findMatchingOpenIssue(signature: signature, dedupWindow: dedupWindow, now: now)
        if limited {
            // The app can start again inside the minute: the issue on disk has the time too.
            if let existing, now.timeIntervalSince(existing.updatedAt) < rateLimitSeconds {
                droppedRepeats[signature, default: 0] += 1
                return nil
            }
            lastCaptureAt[signature] = now
        }
        let dropped = droppedRepeats.removeValue(forKey: signature) ?? 0

        // Dedup check
        if let existing {
            updateRecurrence(issueId: existing.id, now: now, dropped: dropped)
            return nil
        }

        // Create issue folder
        let slug = makeSlug(trigger: trigger, serviceId: serviceId)
        let folderId = formatTimestamp(now) + "_" + slug
        let folderPath = (openDir as NSString).appendingPathComponent(folderId)

        ensureDirectory(folderPath)

        // Build issue
        let iso = isoString(now)
        let summary = buildSummary(
            trigger: trigger, serviceId: serviceId, errorMessage: errorMessage, likelyCause: likelyCause
        )
        let issue = Issue(
            id: folderId,
            summary: summary,
            status: "open",
            severity: severity,
            category: category,
            trigger: trigger,
            serviceId: serviceId,
            errorSignature: signature,
            errorMessage: errorMessage,
            likelyCause: likelyCause,
            appVersion: buildInfo.version,
            appBuild: buildInfo.build,
            appCommit: buildInfo.commit,
            appBuildKind: buildInfo.kind.rawValue,
            appFlavor: buildInfo.flavor.rawValue,
            createdAt: iso,
            updatedAt: iso,
            resolvedAt: nil,
            resolution: nil,
            // Repeats that were dropped after the last issue of this failure closed.
            recurrenceCount: dropped,
            recurrenceTimestamps: []
        )

        // Write issue.json
        writeJSON(issue, to: (folderPath as NSString).appendingPathComponent("issue.json"))

        // Write logs
        let maxFailingLines = config?.logLines?.failingService ?? 200
        let maxOtherLines = config?.logLines?.otherServices ?? 50
        writeServiceLogs(
            logEntries: logEntries,
            serviceId: serviceId,
            folderPath: folderPath,
            maxFailingLines: maxFailingLines,
            maxOtherLines: maxOtherLines,
            redactor: redactor
        )

        // Write state snapshot
        if !stateSnapshots.isEmpty {
            writeJSON(stateSnapshots, to: (folderPath as NSString).appendingPathComponent("state-snapshot.json"))
        }

        // Only a new issue reads this Mac: the tools take some seconds to answer.
        // The issue is on disk first, so a repeat that comes in the meantime finds
        // it, and the caller does not wait for the tools.
        if let diagnostics {
            let id = nextDiagnosticsID
            nextDiagnosticsID += 1
            // The task runs on this actor, so it starts after the line below.
            pendingDiagnostics[id] = Task {
                if let snapshot = await diagnostics() {
                    self.writeDiagnostics(snapshot.redacted(by: redactor), folderPath: folderPath)
                }
                self.pendingDiagnostics[id] = nil
            }
        }

        return folderId
    }

    /// Writes `diagnostics.json` when the issue is still open there. An issue
    /// closed meanwhile gets none: the write must not make its folder again.
    private func writeDiagnostics(_ snapshot: DiagnosticsSnapshot, folderPath: String) {
        guard fm.fileExists(atPath: (folderPath as NSString).appendingPathComponent("issue.json")) else { return }
        writeJSON(snapshot, to: (folderPath as NSString).appendingPathComponent("diagnostics.json"))
    }

    /// Waits for the `diagnostics.json` of the issues filed so far. Tests use it.
    func diagnosticsWritten() async {
        while let task = pendingDiagnostics.values.first {
            await task.value
        }
    }

    /// The key that makes two failures one issue: trigger, service, message and
    /// likely cause. The varying parts (times, pids, UUIDs, addresses) are taken
    /// out first. A failure without a cause keeps the key of the issues from
    /// before the cause was part of it.
    static func signature(trigger: String, serviceId: String?, message: String, likelyCause: String?) -> String {
        var input = "\(trigger):\(serviceId ?? "all"):\(normalizeError(message))"
        if let likelyCause, !likelyCause.isEmpty {
            input += ":\(normalizeCause(likelyCause))"
        }
        return sha256(input)
    }

    // MARK: - Run marker

    /// Writes the marker of this run and gives the marker of the last run when it
    /// is still there: that run did not quit cleanly. The marker is written also
    /// while capture is off. It holds no failure detail, and capture can be on at
    /// the next launch.
    func beginRun(pid: Int32) -> RunMarker? {
        let previous = (try? Data(contentsOf: URL(fileURLWithPath: runMarkerPath)))
            .flatMap { try? jsonDecoder.decode(RunMarker.self, from: $0) }
        let marker = RunMarker(
            pid: pid,
            startedAt: isoString(now()),
            appVersion: buildInfo.version,
            appBuild: buildInfo.build,
            appCommit: buildInfo.commit
        )
        ensureDirectory(baseDir)
        writeJSON(marker, to: runMarkerPath)
        return previous
    }

    /// A clean quit. `applicationWillTerminate` calls it and cannot wait for the actor.
    nonisolated func endRun() {
        try? FileManager.default.removeItem(atPath: runMarkerPath)
    }

    // MARK: - List / Read / Close

    func listOpenIssues() -> [[String: String]] {
        guard let entries = try? fm.contentsOfDirectory(atPath: openDir) else { return [] }
        var results: [[String: String]] = []
        for entry in entries.sorted() {
            let issuePath = (openDir as NSString)
                .appendingPathComponent(entry)
                .appending("/issue.json")
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: issuePath)),
                  let issue = try? jsonDecoder.decode(Issue.self, from: data)
            else { continue }
            results.append([
                "id": issue.id,
                "summary": issue.summary,
                "status": issue.status,
                "severity": issue.severity,
                "category": issue.category,
                "service_id": issue.serviceId ?? "",
                "created_at": issue.createdAt,
                "recurrence_count": String(issue.recurrenceCount)
            ])
        }
        return results
    }

    func getIssue(id: String) -> Issue? {
        let issuePath = (openDir as NSString)
            .appendingPathComponent(id)
            .appending("/issue.json")
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: issuePath)),
              let issue = try? jsonDecoder.decode(Issue.self, from: data)
        else { return nil }
        return issue
    }

    func closeIssue(id: String, resolution: String) -> Bool {
        let srcFolder = (openDir as NSString).appendingPathComponent(id)
        let dstFolder = (closedDir as NSString).appendingPathComponent(id)

        guard fm.fileExists(atPath: srcFolder) else { return false }

        // Update issue.json before moving
        let issuePath = (srcFolder as NSString).appendingPathComponent("issue.json")
        if var issue = readIssue(at: issuePath) {
            issue.recurrenceCount += droppedRepeats.removeValue(forKey: issue.errorSignature) ?? 0
            issue.status = "closed"
            issue.resolution = resolution
            issue.resolvedAt = isoString(now())
            issue.updatedAt = isoString(now())
            writeJSON(issue, to: issuePath)
        }

        ensureDirectory(closedDir)
        do {
            try fm.moveItem(atPath: srcFolder, toPath: dstFolder)
        } catch {
            return false
        }
        pruneClosedIssues()
        return true
    }

    /// Deletes the closed issues that are older than the retention time, and gives
    /// their number. A folder without a readable `issue.json` stays. So does an
    /// issue without `resolved_at`: someone moved it here by hand, and its age
    /// as a closed issue is not known.
    @discardableResult
    func pruneClosedIssues() -> Int {
        let days = loadConfig()?.closedRetentionDays ?? defaultRetentionDays
        guard let days, days > 0,
              let entries = try? fm.contentsOfDirectory(atPath: closedDir)
        else { return 0 }
        let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        for entry in entries {
            let folder = (closedDir as NSString).appendingPathComponent(entry)
            guard let issue = readIssue(at: (folder as NSString).appendingPathComponent("issue.json")),
                  let resolvedAt = issue.resolvedAt,
                  let closedAt = parseISO(resolvedAt),
                  closedAt < cutoff
            else { continue }
            if (try? fm.removeItem(atPath: folder)) != nil { removed += 1 }
        }
        return removed
    }

    // MARK: - Events

    /// Adds one line to `events.jsonl`. For what files no issue but is worth a
    /// count: a Stripe skip, a kill from outside, a breaker trip. Nothing is
    /// written while capture is off.
    func recordEvent(kind: String, serviceId: String?, message: String, redactor: Redactor = .patterns) {
        guard isEnabled() else { return }
        let event = Event(
            at: isoString(now()),
            kind: kind,
            serviceId: serviceId,
            message: redactor.redact(message),
            appVersion: buildInfo.version
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard var line = try? encoder.encode(event) else { return }
        line.append(0x0A)

        ensureDirectory(baseDir)
        let size = (try? fm.attributesOfItem(atPath: eventsPath)[.size] as? Int) ?? 0
        if size + line.count > Self.maxEventsBytes {
            let older = (baseDir as NSString).appendingPathComponent("events.1.jsonl")
            try? fm.removeItem(atPath: older)
            try? fm.moveItem(atPath: eventsPath, toPath: older)
        }
        if !fm.fileExists(atPath: eventsPath) {
            fm.createFile(atPath: eventsPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: eventsPath) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// The events of the current file, oldest first.
    func listEvents() -> [Event] {
        guard let text = try? String(contentsOfFile: eventsPath, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? jsonDecoder.decode(Event.self, from: Data($0.utf8)) }
    }

    func openIssueCount() -> Int {
        guard let entries = try? fm.contentsOfDirectory(atPath: openDir) else { return 0 }
        return entries.filter { entry in
            var isDir: ObjCBool = false
            let path = (openDir as NSString).appendingPathComponent(entry)
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }.count
    }

    func listIssues(status: String) -> [Issue] {
        let dir = status == "closed" ? closedDir : openDir
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var results: [Issue] = []
        for entry in entries.sorted(by: >) {
            let issuePath = (dir as NSString)
                .appendingPathComponent(entry)
                .appending("/issue.json")
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: issuePath)),
                  let issue = try? jsonDecoder.decode(Issue.self, from: data)
            else { continue }
            results.append(issue)
        }
        return results
    }

    /// Returns log file contents for an issue, keyed by filename.
    func issueLogContents(id: String, status: String = "open") -> [String: String] {
        let dir = status == "closed" ? closedDir : openDir
        let folder = (dir as NSString).appendingPathComponent(id)
        guard let files = try? fm.contentsOfDirectory(atPath: folder) else { return [:] }
        var results: [String: String] = [:]
        for file in files where file.hasPrefix("logs-") && file.hasSuffix(".txt") {
            let path = (folder as NSString).appendingPathComponent(file)
            if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                results[file] = content
            }
        }
        return results
    }

    func issueStateSnapshot(id: String, status: String = "open") -> String? {
        let dir = status == "closed" ? closedDir : openDir
        let path = (dir as NSString)
            .appendingPathComponent(id)
            .appending("/state-snapshot.json")
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    func issueFolderPath(id: String, status: String = "open") -> String {
        let dir = status == "closed" ? closedDir : openDir
        return (dir as NSString).appendingPathComponent(id)
    }

    // MARK: - Private helpers

    private static func normalizeError(_ message: String) -> String {
        var result = message
        let range = NSRange(result.startIndex..., in: result)

        result = Self.iso8601Regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<TS>")
        let r2 = NSRange(result.startIndex..., in: result)
        result = Self.pidRegex.stringByReplacingMatches(in: result, range: r2, withTemplate: "<PID>")
        let r3 = NSRange(result.startIndex..., in: result)
        result = Self.uuidRegex.stringByReplacingMatches(in: result, range: r3, withTemplate: "<UUID>")
        let r4 = NSRange(result.startIndex..., in: result)
        result = Self.hexAddrRegex.stringByReplacingMatches(in: result, range: r4, withTemplate: "<ADDR>")

        return result
    }

    /// The cause is a raw log line. Times, numbers and temp names in it vary from
    /// crash to crash; without them a crash loop is one issue, not one per crash.
    static func normalizeCause(_ cause: String) -> String {
        var result = normalizeError(cause)
        for (regex, template) in [
            (causeTimestampRegex, "<TS>"),
            (causeTimeRegex, "<TIME>"),
            (causeRandomNameRegex, "<RAND>"),
            (causeNumberRegex, "<N>"),
        ] {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func findMatchingOpenIssue(
        signature: String, dedupWindow: Int, now: Date
    ) -> (id: String, updatedAt: Date)? {
        guard let entries = try? fm.contentsOfDirectory(atPath: openDir) else { return nil }
        for entry in entries {
            let issuePath = (openDir as NSString)
                .appendingPathComponent(entry)
                .appending("/issue.json")
            guard let issue = readIssue(at: issuePath),
                  issue.errorSignature == signature
            else { continue }
            // Check dedup window against updatedAt
            if let updatedDate = parseISO(issue.updatedAt),
               now.timeIntervalSince(updatedDate) < Double(dedupWindow) {
                return (entry, updatedDate)
            }
        }
        return nil
    }

    private func updateRecurrence(issueId: String, now: Date, dropped: Int = 0) {
        let issuePath = (openDir as NSString)
            .appendingPathComponent(issueId)
            .appending("/issue.json")
        guard var issue = readIssue(at: issuePath) else { return }
        let stamp = isoString(now)
        issue.recurrenceCount += 1 + dropped
        issue.recurrenceTimestamps = Array((issue.recurrenceTimestamps + [stamp]).suffix(Self.maxRecurrenceTimestamps))
        issue.updatedAt = stamp
        // The `app_*` fields keep the build of the first capture.
        issue.lastAppVersion = buildInfo.version
        issue.lastAppBuild = buildInfo.build
        issue.lastAppCommit = buildInfo.commit
        writeJSON(issue, to: issuePath)
    }

    private func readIssue(at path: String) -> Issue? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? jsonDecoder.decode(Issue.self, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to path: String) {
        guard let data = try? jsonEncoder.encode(value) else { return }
        writeFile(data, to: path)
    }

    /// Writes a file of an issue. Outside the Desktop folder only the user can read it.
    private func writeFile(_ data: Data, to path: String) {
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        if privateFiles {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }

    private func writeServiceLogs(
        logEntries: [LogEntry],
        serviceId: String?,
        folderPath: String,
        maxFailingLines: Int,
        maxOtherLines: Int,
        redactor: Redactor
    ) {
        // Each line starts with its time of day: "09:14:03.412".
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss.SSS"
        time.locale = Locale(identifier: "en_US_POSIX")
        time.timeZone = TimeZone.current

        // Failing service logs
        if let sid = serviceId {
            let serviceEntries = logEntries
                .filter { $0.serviceId == sid }
                .suffix(maxFailingLines)
            let lines = serviceEntries.map { "\(time.string(from: $0.timestamp)) \(redactor.redact($0.line))" }
            let content = lines.joined(separator: "\n")
            let path = (folderPath as NSString).appendingPathComponent("logs-\(sid).txt")
            writeFile(Data(content.utf8), to: path)
        }

        // All-services combined log: the tail of every service, in time order.
        let grouped = Dictionary(grouping: logEntries, by: { $0.serviceId })
        var allLines: [(date: Date, order: Int, text: String)] = []
        for sid in grouped.keys.sorted() {
            for entry in grouped[sid, default: []].suffix(maxOtherLines) {
                let redacted = redactor.redact(entry.line)
                allLines.append((entry.timestamp, allLines.count, "\(time.string(from: entry.timestamp)) [\(sid)] \(redacted)"))
            }
        }
        allLines.sort { ($0.date, $0.order) < ($1.date, $1.order) }
        let combined = allLines.map(\.text).joined(separator: "\n")
        let allPath = (folderPath as NSString).appendingPathComponent("logs-all.txt")
        writeFile(Data(combined.utf8), to: allPath)
    }

    private func makeSlug(trigger: String, serviceId: String?) -> String {
        var parts = trigger.replacingOccurrences(of: "_", with: "-")
        if let sid = serviceId {
            parts += "-" + sid
        }
        return parts
    }

    private func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    private func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func parseISO(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: string)
    }

    private func buildSummary(trigger: String, serviceId: String?, errorMessage: String, likelyCause: String?) -> String {
        let svc = serviceId ?? "unknown"
        let truncated = errorMessage.prefix(120)
        guard let likelyCause, !likelyCause.isEmpty else { return "\(trigger) [\(svc)]: \(truncated)" }
        return "\(trigger) [\(svc)]: \(truncated) — \(likelyCause.prefix(160))"
    }

    private func ensureDirectory(_ path: String) {
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(
                atPath: path, withIntermediateDirectories: true,
                attributes: privateFiles ? [.posixPermissions: 0o700] : nil
            )
        }
    }
}
