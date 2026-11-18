import Foundation

/// What "Copy Diagnostics Bundle" copies: the snapshot of this Mac and the stack,
/// and the last lines of the log of each service and DB step that failed. A
/// teammate pastes it in Slack, so it has what is needed to find the cause.
///
/// Every text goes through the redactor.
struct DiagnosticsBundle: Codable, Sendable, Equatable {
    /// The last lines of each failed log that go in.
    static let maxLogLines = 200

    var snapshot: DiagnosticsSnapshot
    /// The stack-level cause, when the runner knows one.
    var rootCause: String?
    var controlAPIError: String?
    var configIssues: [String]
    /// By log id: a service id, or `db-setup-<step>` for a DB step. Each line is
    /// `HH:mm:ss.SSS [out|err] text`.
    var logs: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case snapshot, logs
        case rootCause = "root_cause"
        case controlAPIError = "control_api_error"
        case configIssues = "config_issues"
    }

    /// The logs that go in: each service that failed or whose breaker tripped,
    /// and each DB step that failed or timed out, in the order of the snapshot.
    static func failedLogIDs(in snapshot: DiagnosticsSnapshot) -> [String] {
        let services = snapshot.services
            .filter { $0.phase == ServicePhase.failed.rawValue || $0.circuitBroken }
            .map(\.id)
        let steps = (snapshot.dbPipeline?.steps ?? [])
            .filter { $0.status == DbStepStatus.failed.rawValue || $0.status == DbStepStatus.timedOut.rawValue }
            .map { DbSetupStep.logKeyPrefix + $0.id }
        return services + steps
    }

    /// The bundle with the snapshot and the logs redacted. `logs` holds the lines
    /// of each id in `failedLogIDs`; an id without lines is left out.
    static func make(
        snapshot: DiagnosticsSnapshot,
        redactor: Redactor,
        logs: [String: [LogEntry]],
        rootCause: String? = nil,
        controlAPIError: String? = nil,
        configIssues: [String] = [],
        timeZone: TimeZone = .current
    ) -> DiagnosticsBundle {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss.SSS"

        var tails: [String: [String]] = [:]
        for id in failedLogIDs(in: snapshot) {
            guard let entries = logs[id], !entries.isEmpty else { continue }
            tails[id] = entries.suffix(maxLogLines).map { entry in
                "\(formatter.string(from: entry.timestamp)) [\(entry.stream == .stdout ? "out" : "err")] \(redactor.redact(entry.text))"
            }
        }
        return DiagnosticsBundle(
            snapshot: snapshot.redacted(by: redactor),
            rootCause: rootCause.map(redactor.redact),
            controlAPIError: controlAPIError.map(redactor.redact),
            configIssues: configIssues.map(redactor.redact),
            logs: tails
        )
    }

    /// The bundle as pretty JSON with sorted keys.
    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
