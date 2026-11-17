import Foundation

/// Turns a failure of a service into a condition: what is wrong, in words, and the
/// button that fixes it. It is pure, so each row of its table has a test.
enum FailureAdvisor {
    /// How the service failed.
    enum Kind: Equatable, Sendable {
        /// The process did not pass its startup probe in time.
        case probeTimeout(seconds: Int, processAlive: Bool, lastProbe: ProbeOutcome?)
        /// The process ended by itself with this code (a crash, or a oneshot that failed).
        case exited(code: Int32?)
        /// A daemon ended with code 0 and was not restarted.
        case cleanExit
        /// Something outside the runner stopped it with this signal.
        case killed(signal: Int32)
        /// The circuit breaker tripped: `AutoRestart.failuresToTrip` failures in a minute.
        case crashLoop
        /// `restarts` automatic restarts did not bring it back.
        case exhausted(restarts: Int)
        /// The container runtime did not come up, so the restart stopped.
        case runtimeDown
        /// The probe after a wake failed.
        case wakeCheck(lastProbe: ProbeOutcome?)
        /// The shell could not run the command (exit 126 or 127); `CommandDiagnosis` says what is missing.
        case cannotRun(CommandDiagnosis.Finding)
        /// A failure that already has its own sentence (a `ServiceError`).
        case message(String)
    }

    struct Context: Sendable {
        let name: String
        var port: Int? = nil
        /// The path of an HTTP probe (`/api/health`), or nil.
        var probePath: String? = nil
        /// The last lines of the service's log, oldest first.
        var logTail: [String] = []
        /// The line of the log that says why, from `CrashCause.likelyCause`.
        var likelyCause: String? = nil
        /// The service is a Next app with a `.next` cache.
        var canClearCache = false
        /// The display name of the container runtime of this Mac.
        var runtime = "Docker Desktop"
        /// The command of the service and its folder: a run of pnpm can say that a
        /// script or the packages are missing.
        var command: [String] = []
        var cwd: String? = nil
    }

    /// How many log lines the advisor reads, and the "No clear cause" text names.
    static let logWindow = 120

    static func advise(_ kind: Kind, _ context: Context, now: Date) -> ServiceCondition {
        let name = context.name
        // The log of the launch explains an exit, a probe that timed out, and the
        // stop of the restarts. The other kinds return before they read it.
        let cause = logCause(context)

        func condition(
            _ headline: String, _ detail: String?, _ actions: [RecoveryAction],
            kind conditionKind: ServiceCondition.Kind = .failed
        ) -> ServiceCondition {
            ServiceCondition(kind: conditionKind, headline: headline, detail: detail, actions: actions, since: now)
        }

        switch kind {
        case .crashLoop:
            let because = cause?.headline ?? context.likelyCause ?? "not clear from the log"
            return condition(
                "Stopped retrying after \(AutoRestart.failuresToTrip) crashes in a minute.", "Cause: \(sentence(because))",
                haltedActions(cause), kind: .halted(reason: "crash loop")
            )
        case .exhausted(let restarts):
            let because = cause?.headline ?? context.likelyCause ?? "not clear from the log"
            return condition(
                "\(name) did not come back after \(restarts) restarts.", "Cause: \(sentence(because))",
                haltedActions(cause), kind: .halted(reason: "exhausted")
            )
        case .runtimeDown:
            return condition(
                "\(context.runtime) is not running.", nil, [.openContainerRuntime], kind: .halted(reason: "runtime down")
            )
        case .cannotRun(let finding):
            return condition(CommandDiagnosis.message(finding, name: name), nil, CommandDiagnosis.actions(finding))
        case .message(let text):
            return condition(text, nil, [.openLog, .restart])
        case .cleanExit:
            return condition("\(name) exited (code 0) — not restarted.", nil, [.restart, .openLog])
        // A kill or a failed wake check has its own cause. A line of the log from
        // earlier in the launch (a page that did not compile) does not explain it.
        case .killed(let signal):
            return condition(
                "\(name) was stopped from outside Travel Runner (\(ServiceTermination.signalName(signal))).", nil,
                [.restart, .openLog]
            )
        case .wakeCheck(let lastProbe):
            let detail = lastProbe.map { "Last check: \($0.summary)." }
            return condition("\(name) did not answer after the Mac woke up.", detail, [.restart, .openLog])
        default:
            break
        }

        // The log names a cause with one fix.
        if let cause { return condition(cause.headline, cause.detail, cause.actions) }

        switch kind {
        case .probeTimeout(let seconds, true, let lastProbe):
            if case .http(let status) = lastProbe, status == 404, let path = context.probePath {
                return condition(
                    "\(name) answers with HTTP 404 at \(path).", "Does this branch have that route?", [.openLog]
                )
            }
            if case .notFoundThenRoot(let root) = lastProbe, let path = context.probePath {
                return condition(
                    "\(name) answers with HTTP 404 at \(path) and \(root.summary) at /.", "See its log for the error.",
                    context.canClearCache ? [.openLog, .clearCacheAndRestart] : [.openLog, .restart]
                )
            }
            let place = context.port.map { "on port \($0)" } ?? "its ready check"
            var detail = "The process is still running — it may still be compiling."
            if let lastProbe, !lastProbe.isReady { detail += " Last check: \(lastProbe.summary)." }
            return condition(
                "\(name) did not answer \(place) within \(seconds)s.", detail,
                context.canClearCache ? [.openLog, .clearCacheAndRestart] : [.openLog, .restart]
            )
        case .probeTimeout(let seconds, false, _):
            return exitedCondition("\(name) stopped before it answered in \(seconds)s.", context, now: now)
        case .exited(let code):
            let what = code.map { "\(name) exited with code \($0)." } ?? "\(name) exited."
            return exitedCondition(what, context, now: now)
        default:
            return condition("\(name) failed.", nil, [.openLog])
        }
    }

    /// A process that ended: the cause line from the log, or "No clear cause".
    private static func exitedCondition(_ headline: String, _ context: Context, now: Date) -> ServiceCondition {
        if let likely = context.likelyCause {
            return ServiceCondition(
                kind: .failed, headline: headline, detail: "Cause: \(sentence(likely))", actions: [.openLog, .restart], since: now
            )
        }
        return ServiceCondition(
            kind: .failed, headline: headline, detail: "No clear cause in the last \(logWindow) lines.",
            actions: [.openLog], since: now
        )
    }

    private struct Cause {
        let headline: String
        var detail: String? = nil
        let actions: [RecoveryAction]
    }

    /// The causes that the log shows and that have one fix.
    private static func logCause(_ context: Context) -> Cause? {
        let tail = context.logTail.suffix(logWindow)
        if CrashCause.showsContainerRuntimeDown(Array(tail)) {
            return Cause(headline: "\(context.runtime) is not running.", actions: [.openContainerRuntime])
        }
        if tail.contains(where: { $0.contains("EADDRINUSE") }) {
            // The line names the port that is taken; it can be another port of the app.
            let port = addressInUsePort(tail) ?? context.port
            let headline = port.map { "Port \($0) is already in use by another process." }
                ?? "The port is already in use by another process."
            return Cause(headline: headline, actions: [.stopForeignAndRetry(port: port)])
        }
        if let finding = commandFinding(context) {
            return Cause(
                headline: CommandDiagnosis.message(finding, name: context.name), actions: CommandDiagnosis.actions(finding)
            )
        }
        let missingModule = ["Cannot find module", "Module not found", "ERR_MODULE_NOT_FOUND", "Cannot find package"]
        if tail.contains(where: { line in missingModule.contains { line.contains($0) } }) {
            return Cause(
                headline: "A package is missing — dependencies are out of date.", actions: [.installDependencies]
            )
        }
        return nil
    }

    /// What `CommandDiagnosis` finds in the log, when it is the cause that the
    /// advisor names. pnpm ends with 1, not 127, when the packages or the script
    /// are missing. A down container runtime and a taken port come first.
    static func commandFinding(_ context: Context) -> CommandDiagnosis.Finding? {
        let tail = Array(context.logTail.suffix(logWindow))
        if CrashCause.showsContainerRuntimeDown(tail) || tail.contains(where: { $0.contains("EADDRINUSE") }) { return nil }
        return CommandDiagnosis.diagnoseFailedRun(command: context.command, cwd: context.cwd, logTail: tail)
    }

    /// The buttons of a service that stopped retrying: the fix of the cause first.
    /// A restart alone fails the same way when the cause has its own fix.
    private static func haltedActions(_ cause: Cause?) -> [RecoveryAction] {
        var actions = cause?.actions ?? []
        for action in [RecoveryAction.restart, .openLog] where !actions.contains(action) { actions.append(action) }
        return actions
    }

    private static let portPattern = try! NSRegularExpression(pattern: #":(\d{2,5})\b"#)

    /// The port of the last `EADDRINUSE` line (`address already in use :::3002`):
    /// the last ":<digits>" of the line, after any time stamp.
    static func addressInUsePort<S: BidirectionalCollection>(_ lines: S) -> Int? where S.Element == String {
        for line in lines.reversed() where line.contains("EADDRINUSE") {
            let matches = portPattern.matches(in: line, range: NSRange(line.startIndex..., in: line))
            if let last = matches.last, let range = Range(last.range(at: 1), in: line),
               let port = Int(line[range]), ProbeConfig.validPorts.contains(port) {
                return port
            }
        }
        return nil
    }

    /// Ends a cause with a full stop, unless it has one.
    private static func sentence(_ text: String) -> String {
        guard let last = text.last else { return text }
        return ".!?…".contains(last) ? text : text + "."
    }
}
