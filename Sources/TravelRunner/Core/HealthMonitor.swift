import Foundation

/// Counts the failed liveness checks of the running daemons and says when a
/// service is unhealthy. The supervisor runs the checks; this type holds the
/// rules and the texts, so each has a test.
///
/// Rules (plan item L5):
/// - A running daemon is checked every 20 s, with a request limit of 5 s.
/// - Three failed checks in a row mark it unhealthy. The row offers Restart; the
///   runner does not restart it by itself.
/// - Only the zombie signature restarts by itself: a server that answers 404 on
///   every route, the health route and `/` alike. It is an orphaned dev server that
///   holds the port.
struct HealthMonitor {
    static let interval: Duration = .seconds(20)
    static let failuresToMark = 3
    /// The limit of one liveness request.
    static let requestTimeout: TimeInterval = 5
    /// How long a start may take while its process lives. The probe timeout of the
    /// service is the soft limit; at this cap the runner stops the process.
    static let startHardCap: Duration = .seconds(15 * 60)

    enum Verdict: Equatable, Sendable {
        /// The check passed. `recovered`: the service was marked unhealthy before.
        case answering(recovered: Bool)
        /// The check failed, fewer than three times in a row.
        case failing(count: Int)
        /// Three or more checks in a row failed, the first at `since`.
        case unhealthy(since: Date)
        /// Three checks in a row found the zombie signature. Restart it.
        case zombie
    }

    private struct Series {
        var count = 0
        var zombies = 0
        var since: Date
    }

    private var series: [String: Series] = [:]

    /// Records one check of a service and says what it means.
    mutating func record(_ serviceID: String, _ outcome: ProbeOutcome, at now: Date) -> Verdict {
        if outcome.isReady {
            let wasUnhealthy = (series[serviceID]?.count ?? 0) >= Self.failuresToMark
            series[serviceID] = nil
            return .answering(recovered: wasUnhealthy)
        }
        var current = series[serviceID] ?? Series(since: now)
        current.count += 1
        current.zombies = Self.isZombie(outcome) ? current.zombies + 1 : 0
        if current.zombies >= Self.failuresToMark {
            // The restart starts a new series.
            series[serviceID] = nil
            return .zombie
        }
        series[serviceID] = current
        return current.count >= Self.failuresToMark ? .unhealthy(since: current.since) : .failing(count: current.count)
    }

    /// The service no longer runs, or another operation owns it: its series ends.
    mutating func forget(_ serviceID: String) {
        series[serviceID] = nil
    }

    /// True for a server that answers 404 on its health route and on `/`. `HttpProbe`
    /// gives a plain 404 only then: a 404 on the health route with an answer at `/`
    /// counts as ready, and a 5xx at `/` is `notFoundThenRoot`.
    static func isZombie(_ outcome: ProbeOutcome) -> Bool {
        outcome == .http(status: 404)
    }

    /// True when the server answered with an HTTP error, a 500 for one. It runs, so a
    /// restart does not help: the row says so and offers Restart. The zombie
    /// signature is not one.
    static func isErrorAnswer(_ outcome: ProbeOutcome) -> Bool {
        switch outcome {
        case .http, .notFoundThenRoot: !isZombie(outcome)
        default: false
        }
    }

    /// "Booking Portal answers 500 on /api/health since 14:02."
    static func unhealthyHeadline(
        name: String, outcome: ProbeOutcome, path: String?, port: Int?, since: Date, timeZone: TimeZone = .current
    ) -> String {
        let time = clockTime(since, timeZone: timeZone)
        let portPlace = port.map { "on :\($0)" } ?? "to its check"
        switch outcome {
        case .http(let status):
            return "\(name) answers \(status) \(path.map { "on \($0)" } ?? portPlace) since \(time)."
        case .refused, .timedOut:
            return "\(name) does not answer \(portPlace) since \(time)."
        default:
            return "\(name) fails its health check since \(time) (\(outcome.summary))."
        }
    }

    /// "Booking Portal still starting (4m10s) — last check: no answer on :3002"
    static func slowStartHeadline(name: String, elapsed: Duration, lastProbe: ProbeOutcome?, port: Int?) -> String {
        "\(name) still starting (\(elapsedText(elapsed))) — last check: \(lastCheckText(lastProbe, port: port))"
    }

    /// "no answer on :3002", or what the last check found.
    static func lastCheckText(_ outcome: ProbeOutcome?, port: Int?) -> String {
        switch outcome {
        case nil, .refused?, .timedOut?:
            port.map { "no answer on :\($0)" } ?? "no answer"
        case let outcome?:
            outcome.summary
        }
    }

    /// "Booking Portal did not answer in 15 min and was stopped."
    static func hardCapText(name: String, limit: Duration) -> String {
        "\(name) did not answer in \(EnvironmentSupervisor.durationText(limit)) and was stopped."
    }

    /// "4m10s", "45s", "1h02m".
    static func elapsedText(_ duration: Duration) -> String {
        let seconds = max(0, Int(duration.components.seconds))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(String(format: "%02d", seconds % 60))s" }
        return "\(seconds / 3600)h\(String(format: "%02d", (seconds % 3600) / 60))m"
    }

    /// "[travel-runner] Wake check: 5 checked, 1 restarted (Stripe CLI)"
    static func wakeSummary(checked: Int, restarted: [String]) -> String {
        let names = restarted.isEmpty ? "" : " (\(restarted.joined(separator: ", ")))"
        return "[travel-runner] Wake check: \(checked) checked, \(restarted.count) restarted\(names)"
    }

    private static func clockTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
