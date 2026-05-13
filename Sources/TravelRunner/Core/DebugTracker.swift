import Foundation
import CryptoKit

actor DebugTracker {

    // MARK: - Config types

    struct DebugTrackingConfig: Codable {
        let enabled: Bool
        let autoCapture: AutoCaptureConfig?
        let logLines: LogLinesConfig?
        let dedupWindowSeconds: Int?

        struct AutoCaptureConfig: Codable {
            let serviceCrash: Bool?
            let circuitBreaker: Bool?
            let dbSetupFailure: Bool?
            let preflightFailure: Bool?
            let probeTimeout: Bool?

            enum CodingKeys: String, CodingKey {
                case serviceCrash = "service_crash"
                case circuitBreaker = "circuit_breaker"
                case dbSetupFailure = "db_setup_failure"
                case preflightFailure = "preflight_failure"
                case probeTimeout = "probe_timeout"
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
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case resolvedAt = "resolved_at"
            case resolution
            case recurrenceCount = "recurrence_count"
            case recurrenceTimestamps = "recurrence_timestamps"
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

    private let fm = FileManager.default
    private let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let jsonDecoder = JSONDecoder()

    // MARK: - Redaction patterns

    private static let secretPatterns: [String] = [
        "SECRET", "KEY", "TOKEN", "PASSWORD"
    ]

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

    // MARK: - Init

    init(baseDir: String? = nil) {
        let root = baseDir ?? NSString(string: "~/Desktop/debug-tracking").expandingTildeInPath
        self.baseDir = root
        self.configPath = (root as NSString).appendingPathComponent("config.json")
        self.openDir = (root as NSString).appendingPathComponent("open")
        self.closedDir = (root as NSString).appendingPathComponent("closed")
    }

    // MARK: - Config

    func loadConfig() -> DebugTrackingConfig? {
        guard fm.fileExists(atPath: configPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? jsonDecoder.decode(DebugTrackingConfig.self, from: data)
        else { return nil }
        return config
    }

    func isEnabled() -> Bool {
        loadConfig()?.enabled ?? false
    }

    func isAutoCaptureEnabled(trigger: String) -> Bool {
        guard let config = loadConfig(), config.enabled else { return false }
        guard let auto = config.autoCapture else { return true }
        switch trigger {
        case "service_crash":     return auto.serviceCrash ?? true
        case "circuit_breaker":   return auto.circuitBreaker ?? true
        case "db_setup_failure":  return auto.dbSetupFailure ?? true
        case "preflight_failure": return auto.preflightFailure ?? true
        case "probe_timeout":     return auto.probeTimeout ?? true
        default:                  return true
        }
    }

    // MARK: - Capture

    func captureIssue(
        trigger: String,
        serviceId: String?,
        errorMessage: String,
        severity: String = "error",
        category: String = "runtime",
        logEntries: [LogEntry] = [],
        stateSnapshots: [ServiceStateSnapshot] = []
    ) -> String? {
        guard isAutoCaptureEnabled(trigger: trigger) else { return nil }

        let normalized = normalizeError(errorMessage)
        let signatureInput = "\(trigger):\(serviceId ?? "all"):\(normalized)"
        let signature = sha256(signatureInput)

        let config = loadConfig()
        let dedupWindow = config?.dedupWindowSeconds ?? 300

        // Dedup check
        if let existingId = findMatchingOpenIssue(signature: signature, dedupWindow: dedupWindow) {
            updateRecurrence(issueId: existingId)
            return nil
        }

        // Create issue folder
        let now = Date()
        let slug = makeSlug(trigger: trigger, serviceId: serviceId)
        let folderId = formatTimestamp(now) + "_" + slug
        let folderPath = (openDir as NSString).appendingPathComponent(folderId)

        ensureDirectory(folderPath)

        // Build issue
        let iso = isoString(now)
        let summary = buildSummary(trigger: trigger, serviceId: serviceId, errorMessage: errorMessage)
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
            createdAt: iso,
            updatedAt: iso,
            resolvedAt: nil,
            resolution: nil,
            recurrenceCount: 0,
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
            maxOtherLines: maxOtherLines
        )

        // Write state snapshot
        if !stateSnapshots.isEmpty {
            writeJSON(stateSnapshots, to: (folderPath as NSString).appendingPathComponent("state-snapshot.json"))
        }

        return folderId
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
            issue.status = "closed"
            issue.resolution = resolution
            issue.resolvedAt = isoString(Date())
            issue.updatedAt = isoString(Date())
            writeJSON(issue, to: issuePath)
        }

        ensureDirectory(closedDir)
        do {
            try fm.moveItem(atPath: srcFolder, toPath: dstFolder)
            return true
        } catch {
            return false
        }
    }

    func openIssueCount() -> Int {
        guard let entries = try? fm.contentsOfDirectory(atPath: openDir) else { return 0 }
        return entries.filter { entry in
            var isDir: ObjCBool = false
            let path = (openDir as NSString).appendingPathComponent(entry)
            return fm.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }.count
    }

    // MARK: - Private helpers

    private func normalizeError(_ message: String) -> String {
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

    private func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func findMatchingOpenIssue(signature: String, dedupWindow: Int) -> String? {
        guard let entries = try? fm.contentsOfDirectory(atPath: openDir) else { return nil }
        let now = Date()
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
                return entry
            }
        }
        return nil
    }

    private func updateRecurrence(issueId: String) {
        let issuePath = (openDir as NSString)
            .appendingPathComponent(issueId)
            .appending("/issue.json")
        guard var issue = readIssue(at: issuePath) else { return }
        let now = isoString(Date())
        issue.recurrenceCount += 1
        issue.recurrenceTimestamps.append(now)
        issue.updatedAt = now
        writeJSON(issue, to: issuePath)
    }

    private func readIssue(at path: String) -> Issue? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? jsonDecoder.decode(Issue.self, from: data)
    }

    private func writeJSON<T: Encodable>(_ value: T, to path: String) {
        guard let data = try? jsonEncoder.encode(value) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private func writeServiceLogs(
        logEntries: [LogEntry],
        serviceId: String?,
        folderPath: String,
        maxFailingLines: Int,
        maxOtherLines: Int
    ) {
        // Failing service logs
        if let sid = serviceId {
            let serviceEntries = logEntries
                .filter { $0.serviceId == sid }
                .suffix(maxFailingLines)
            let lines = serviceEntries.map { redactLine($0.line) }
            let content = lines.joined(separator: "\n")
            let path = (folderPath as NSString).appendingPathComponent("logs-\(sid).txt")
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }

        // All-services combined log
        let grouped = Dictionary(grouping: logEntries, by: { $0.serviceId })
        var allLines: [(Date, String)] = []
        for (sid, entries) in grouped {
            let tail = entries.suffix(maxOtherLines)
            for entry in tail {
                let redacted = redactLine(entry.line)
                allLines.append((entry.timestamp, "[\(sid)] \(redacted)"))
            }
        }
        allLines.sort { $0.0 < $1.0 }
        let combined = allLines.map { $0.1 }.joined(separator: "\n")
        let allPath = (folderPath as NSString).appendingPathComponent("logs-all.txt")
        try? combined.write(toFile: allPath, atomically: true, encoding: .utf8)
    }

    private func redactLine(_ line: String) -> String {
        let upper = line.uppercased()
        for pattern in Self.secretPatterns {
            if upper.contains(pattern) {
                return "[REDACTED]"
            }
        }
        return line
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

    private func buildSummary(trigger: String, serviceId: String?, errorMessage: String) -> String {
        let svc = serviceId ?? "unknown"
        let truncated = errorMessage.prefix(120)
        return "\(trigger) [\(svc)]: \(truncated)"
    }

    private func ensureDirectory(_ path: String) {
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }
}
