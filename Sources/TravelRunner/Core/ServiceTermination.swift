import Foundation

/// What the end of a service process means for the supervisor.
enum TerminationKind: Equatable, Sendable {
    /// The runner stopped it: a restart, a mode switch, wake recovery, or stop-all.
    case stoppedByRunner
    case cleanExit
    /// Something outside the runner ended it with a stop signal: `kill`, a script
    /// that frees the port, Ctrl-C. The process did not fail by itself.
    case killedExternally(signal: Int32)
    /// The shell could not run the command (exit 126 or 127). A restart cannot help.
    case commandNotRunnable(code: Int32)
    case crashed(code: Int32, bySignal: Bool)
}

enum ServiceTermination {
    /// Signals that mean "someone stopped it", not "it broke".
    static let stopSignals: Set<Int32> = [SIGHUP, SIGINT, SIGQUIT, SIGKILL, SIGTERM]

    static func classify(_ termination: ProcessRunner.Termination) -> TerminationKind {
        if termination.stoppedByRunner { return .stoppedByRunner }

        if termination.bySignal {
            return stopSignals.contains(termination.status)
                ? .killedExternally(signal: termination.status)
                : .crashed(code: termination.status, bySignal: true)
        }
        if termination.status == 0 { return .cleanExit }

        // The service runs under `zsh -c`. A shell reports a child that a signal
        // ended as 128 + the signal number (143 for SIGTERM).
        let signal = termination.status - 128
        if signal > 0, stopSignals.contains(signal) { return .killedExternally(signal: signal) }

        if termination.status == 126 || termination.status == 127 {
            return .commandNotRunnable(code: termination.status)
        }
        return .crashed(code: termination.status, bySignal: false)
    }

    static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        case SIGQUIT: "SIGQUIT"
        case SIGKILL: "SIGKILL"
        case SIGTERM: "SIGTERM"
        default: "signal \(signal)"
        }
    }

    /// The text for a crash, as the notification and the debug issue show it.
    static func describe(_ termination: ProcessRunner.Termination) -> String {
        termination.bySignal
            ? "ended by signal \(termination.status)"
            : "exited with code \(termination.status)"
    }
}

/// When the supervisor restarts a failed daemon by itself, and when it stops.
enum AutoRestart {
    /// Failures inside this window count toward the circuit breaker.
    static let failureWindow: TimeInterval = 60
    static let failuresToTrip = 3
    static let maxRestarts = 5
    /// A service that ran this long before it failed starts a new failure series.
    static let stableUptime: TimeInterval = 120

    enum Decision: Equatable {
        case restart(after: TimeInterval)
        /// `failuresToTrip` failures inside the window: a crash loop.
        case crashLoop
        /// `maxRestarts` restarts in one series did not bring the service back.
        case exhausted
    }

    static func recentFailures(_ timestamps: [Date], now: Date) -> [Date] {
        let cutoff = now.addingTimeInterval(-failureWindow)
        return timestamps.filter { $0 >= cutoff }
    }

    static func decide(recentFailureCount: Int, restartCount: Int) -> Decision {
        if recentFailureCount >= failuresToTrip { return .crashLoop }
        if restartCount >= maxRestarts { return .exhausted }
        return .restart(after: min(2.0 * pow(2.0, Double(restartCount)), 60.0))
    }

    /// True when a failure after this uptime starts a new series.
    static func startsNewSeries(uptime: TimeInterval?) -> Bool {
        (uptime ?? 0) >= stableUptime
    }
}

/// Finds the line in a service's output that best explains why it failed.
enum CrashCause {
    private static let window = 120
    private static let maxLength = 240

    static let containerRuntimeDown = "Cannot connect to the Docker daemon"

    private static let strongMarkers = [
        "Error:", "(RuntimeError)", "Failed to ", "FATAL", "panic:", "Unhandled",
        "command not found", "no such file or directory", "Cannot find module", "Module not found",
    ]

    private static let weakPattern = try! NSRegularExpression(
        pattern: #"\b(error|failed|cannot|refused|not found|denied|timed out|unexpectedly)\b"#,
        options: [.caseInsensitive]
    )

    private static let pidPattern = try! NSRegularExpression(pattern: #"PID:\s*(\d+)"#)

    static func likelyCause(in lines: [String]) -> String? {
        let tail = Array(lines.suffix(window))

        // Known failures first: they have one cause and one fix.
        if tail.contains(where: { $0.localizedCaseInsensitiveContains(containerRuntimeDown) }) {
            return "The container runtime is not running (\(containerRuntimeDown))"
        }
        // Node prints the port on the "address already in use" line; the lines after it
        // (stack frames, `code: 'EADDRINUSE'`) say less.
        if let line = tail.last(where: { $0.contains("EADDRINUSE") && $0.contains("address already in use") && isCandidate($0) })
            ?? tail.last(where: { $0.contains("EADDRINUSE") }) {
            return clean(line)
        }
        if let index = tail.lastIndex(where: { $0.contains("Another next dev server is already running") }) {
            let after = tail[index...].prefix(6).joined(separator: " ")
            let range = NSRange(after.startIndex..., in: after)
            if let match = pidPattern.firstMatch(in: after, range: range),
               let pidRange = Range(match.range(at: 1), in: after) {
                return "Another next dev server is already running in this folder (PID \(after[pidRange]))"
            }
            return "Another next dev server is already running in this folder"
        }

        let candidates = tail.filter(isCandidate)
        if let line = candidates.last(where: { line in strongMarkers.contains { line.contains($0) } }) {
            return clean(line)
        }
        if let line = candidates.last(where: { line in
            weakPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }) {
            return clean(line)
        }
        return nil
    }

    /// True when the last lines of a service's output show that the container
    /// runtime (Docker Desktop, OrbStack) was down.
    static func showsContainerRuntimeDown(_ lines: [String]) -> Bool {
        lines.suffix(40).contains { $0.localizedCaseInsensitiveContains(containerRuntimeDown) }
    }

    private static func isCandidate(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("[travel-runner]") || trimmed.hasPrefix("at ") { return false }
        if DebugTracker.isSecretLine(line) { return false }
        // Structured app logs: only the error level is a cause.
        if trimmed.hasPrefix("{"), let level = jsonLevel(trimmed) { return level >= 50 }
        return true
    }

    private static func jsonLevel(_ line: String) -> Int? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["level"] as? Int
    }

    private static func clean(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("{"),
           let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = json["msg"] as? String {
            text = message
        }
        return text.count > maxLength ? String(text.prefix(maxLength)) + "…" : text
    }
}
