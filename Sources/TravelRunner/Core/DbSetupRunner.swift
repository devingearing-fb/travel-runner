import Foundation

/// How a step command starts. The live one is a login shell (`zsh -l -c`). Tests
/// give `/bin/sh`, so they do not read the startup files of the person who runs them.
struct StepLauncher: Sendable {
    var executable: String
    var arguments: @Sendable (_ command: String) -> [String]

    static let loginShell = StepLauncher(executable: "/bin/zsh", arguments: { ["-l", "-c", $0] })
}

/// Why the runner stopped a step that still ran.
enum StepTimeout: Sendable, Equatable {
    /// The step printed nothing for this many seconds.
    case idle(seconds: Int)
    /// The step ran longer than its hard cap.
    case cap(seconds: Int)

    /// The limit that has passed at `now`, or nil. All times are of one clock.
    static func check(
        now: Duration, startedAt: Duration, lastOutputAt: Duration, idleSeconds: Int, capSeconds: Int
    ) -> StepTimeout? {
        if now - startedAt >= .seconds(capSeconds) { return .cap(seconds: capSeconds) }
        if now - lastOutputAt >= .seconds(idleSeconds) { return .idle(seconds: idleSeconds) }
        return nil
    }

    /// The error of the step. `progressLabel` is the last progress text of the step,
    /// `lastLine` its last line of output.
    func message(stepName: String, progressLabel: String?, lastLine: String?) -> String {
        switch self {
        case .idle(let seconds):
            let doing = progressLabel ?? stepName
            return "No output for \(seconds) s while: \(doing). Last line: \(lastLine ?? "none")."
        case .cap(let seconds):
            return "Timed out after \(seconds) s"
        }
    }

    var guidance: String {
        switch self {
        case .idle:
            return "The step stopped printing and was stopped. Check the log, then retry the step."
        case .cap:
            return "The step took too long and was stopped. Check the log, then retry the step."
        }
    }
}

/// The time stamps of one step, shared by its output reader and its watchdog.
private final class StepWatch: @unchecked Sendable {
    private let lock = NSLock()
    let startedAt: Duration
    private var lastOutput: Duration
    private var expired: StepTimeout?

    init(now: Duration) {
        startedAt = now
        lastOutput = now
    }

    var lastOutputAt: Duration {
        lock.lock()
        defer { lock.unlock() }
        return lastOutput
    }

    func output(at now: Duration) {
        lock.lock()
        lastOutput = now
        lock.unlock()
    }

    var timeout: StepTimeout? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return expired
        }
        set {
            lock.lock()
            expired = newValue
            lock.unlock()
        }
    }
}

/// One line of a step or of its health check.
private struct OutputLine: Sendable {
    let text: String
    let stream: LogEntry.Stream
}

/// The exit code of a step process, given once by its termination handler.
private final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?
    private var waiter: CheckedContinuation<Int32, Never>?

    func resolve(_ value: Int32) {
        lock.lock()
        guard code == nil else {
            lock.unlock()
            return
        }
        code = value
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let code {
                lock.unlock()
                continuation.resume(returning: code)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// The pid of the step process that runs now. The app reads it as it quits,
/// outside the actor.
private final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var value: pid_t?

    var pid: pid_t? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

actor DbSetupRunner {
    private let portalCwd: String
    private let logStore: LogStore
    private let seedScenarioID: String
    /// The profile of the pipeline. The prerequisites step reads it: a profile
    /// with a hotel step checks the hotel source before anything is reset.
    private let profile: String?
    /// Set by `cancel()`. A runner serves one run, so a cancel before the run
    /// starts still stops it.
    private var cancelled = false
    /// The step process that runs now.
    private let running = RunningProcess()
    /// The output of the step process that runs now. A stop holds it open.
    private var runningOutput: PipeLineReader?
    /// The stop that `cancel()` started. The step ends only after it.
    private var stop: Task<Void, Never>?
    /// The health check that runs now.
    private var healthCheck: Task<CommandResult, Never>?
    /// The PATH of the step commands.
    private let tools: ToolEnvironment
    /// Runs the health checks of the steps.
    private let shell: any CommandRunning
    private let launcher: StepLauncher
    /// The clock of the step limits. It stops while the Mac sleeps.
    private let clock: RunnerClock

    /// A health check that hangs fails after this time.
    static let healthCheckTimeout: Duration = .seconds(30)
    /// How often the watchdog of a step looks at its limits.
    static let watchInterval: Duration = .seconds(1)

    init(
        portalCwd: String, logStore: LogStore, seedScenarioID: String, profile: String? = nil,
        tools: ToolEnvironment = .shared, shell: (any CommandRunning)? = nil,
        launcher: StepLauncher = .loginShell, clock: RunnerClock = .awake
    ) {
        self.portalCwd = portalCwd
        self.logStore = logStore
        self.seedScenarioID = seedScenarioID
        self.profile = profile
        self.tools = tools
        self.shell = shell ?? LoginShell(tools: tools)
        self.launcher = launcher
        self.clock = clock
    }

    /// The pid of the step process that runs now, or nil. The app stops its tree
    /// as it quits.
    nonisolated var runningProcessID: pid_t? { running.pid }

    /// What every step and every health check gets from the runner. The scripts
    /// of the checkout read these names (`scripts/db`):
    /// - `TRAVEL_SEED_SCENARIO`: the seed scenario of the reset.
    /// - `TRAVEL_DB_PROFILE`: the profile of the pipeline.
    /// - `TRAVEL_HOTEL_DUMP`: where the hotel dump is kept (`hotelDumpPath`).
    /// - `TRAVEL_RUNNER_FLAVOR`: which app built the database. A packaged app has
    ///   its flavor in Info.plist only, so the scripts cannot read it there.
    ///
    /// `GIT_TERMINAL_PROMPT=0`: a reset can clone or fetch the backend baseline, and
    /// git must fail then, not wait for a password nobody can type.
    nonisolated static func environment(
        parent: [String: String],
        seedScenarioID: String,
        profile: String? = nil,
        flavor: Flavor = .current,
        home: String = NSHomeDirectory()
    ) -> [String: String] {
        var environment = parent
        environment["TRAVEL_SEED_SCENARIO"] = seedScenarioID
        if let profile { environment["TRAVEL_DB_PROFILE"] = profile }
        environment["TRAVEL_HOTEL_DUMP"] = hotelDumpPath(flavor: flavor, home: home)
        environment[Flavor.environmentKey] = flavor.rawValue
        environment.merge(BackendBaseline.noPromptEnvironment) { _, new in new }
        return environment
    }

    /// The hotel dump (about 285 MB) lives outside the checkout, so a worktree or a
    /// second checkout does not download it again. It is not under `~/Library/Caches`,
    /// which macOS may empty. The fetch script moves a valid dump from the checkout
    /// (`data/travel_organizations.sql`) here once.
    nonisolated static func hotelDumpPath(flavor: Flavor = .current, home: String = NSHomeDirectory()) -> String {
        "\(home)/Library/Application Support/\(flavor.displayName)/hotels/travel_organizations.sql"
    }

    /// Where the dump was before `TRAVEL_HOTEL_DUMP`. A valid dump here still counts.
    nonisolated static func checkoutHotelDumpPath(root: String) -> String {
        (root as NSString).appendingPathComponent("data/travel_organizations.sql")
    }

    func run(pipeline: DbSetupPipeline, from startStepId: String? = nil) async {
        await MainActor.run {
            pipeline.isRunning = true
            pipeline.startedAt = .now
            pipeline.completedAt = nil
        }

        let steps = await MainActor.run { pipeline.steps }
        let startIndex: Int
        if let startId = startStepId {
            startIndex = steps.firstIndex(where: { $0.id == startId }) ?? 0
        } else {
            startIndex = 0
        }

        // Mark steps before startIndex as skipped (preserve already-passed ones)
        for i in 0..<startIndex {
            let step = steps[i]
            await MainActor.run {
                if step.status != .passed { step.status = .skipped }
            }
        }

        // If retrying from reset-database, force re-run of subsequent data steps
        if let startId = startStepId, startId == "reset-database" {
            let resetDependents: Set<String> = ["load-hotels", "copy-event-data", "verify-data"]
            for step in steps where resetDependents.contains(step.id) {
                await MainActor.run { step.status = .pending }
            }
        }

        for i in startIndex..<steps.count {
            if cancelled { break }
            let step = steps[i]
            let status = await MainActor.run { step.status }
            if status == .skipped { continue }

            let success = await executeStep(step)

            if !success && !step.isOptional {
                break
            }
        }

        await MainActor.run {
            pipeline.isRunning = false
            pipeline.completedAt = .now
        }
    }

    /// True after `cancel()`: the developer stopped the run, so its failed step is not a fault.
    var wasCancelled: Bool { cancelled }

    /// Stops the run: the step process and every process below it (SIGTERM, then
    /// SIGKILL), and the health check. It returns when they are gone. The step
    /// does not end before the stop: `runCommand` waits for it too.
    func cancel() async {
        cancelled = true
        if let stop {
            await stop.value
        } else if let pid = running.pid {
            runningOutput?.hold()
            let tree = ProcessTree.tree(of: pid)
            let stop = Task.detached { await ProcessTree.terminate(tree) }
            self.stop = stop
            await stop.value
        }
        if let healthCheck {
            healthCheck.cancel()
            _ = await healthCheck.value
        }
    }

    // MARK: - Step Execution

    func executeStepPublic(_ step: DbSetupStep) async -> Bool {
        await executeStep(step)
    }

    private func executeStep(_ step: DbSetupStep) async -> Bool {
        // The stored log holds this run only, so a failure issue shows no older run.
        await logStore.clear(serviceID: step.logKey)
        await MainActor.run {
            step.status = .running
            step.startedAt = .now
            step.logEntries = []
            step.errorMessage = nil
            step.recoveryGuidance = nil
            step.recoveryAction = nil
            step.healthResult = nil
            step.healthFailures = []
            step.progress = nil
            step.progressLabel = nil
            step.exitCode = nil
        }

        // A step that starts during a resolve waits for the new PATH.
        await tools.settled()
        // A cancel during the wait finds no process to end, so the step ends here.
        if cancelled {
            await Self.markCancelled(step)
            return false
        }

        let (exitCode, timeout) = await runCommand(of: step)

        if cancelled {
            await Self.markCancelled(step)
            return false
        }

        if let timeout {
            await MainActor.run {
                step.status = .timedOut
                step.completedAt = .now
                step.errorMessage = timeout.message(
                    stepName: step.name, progressLabel: step.progressLabel,
                    lastLine: step.logEntries.last?.text
                )
                step.recoveryGuidance = timeout.guidance
                step.recoveryAction = .retryFromStep
            }
            return false
        }

        if exitCode != 0 {
            await MainActor.run {
                // The script's own message stays; the table adds the guidance and the action.
                let diagnosis = DbSetupDiagnostics.diagnose(
                    stepID: step.id, output: step.logEntries.map(\.text), exitCode: exitCode,
                    scriptMessage: step.errorMessage
                )
                step.status = .failed
                step.completedAt = .now
                step.exitCode = exitCode
                step.errorMessage = diagnosis.message
                step.recoveryGuidance = diagnosis.guidance
                step.recoveryAction = diagnosis.action
            }
            return false
        }

        // Run health check if defined
        if let healthCmd = step.healthCheckCommand {
            await MainActor.run { step.status = .healthCheck }
            // A cancel during the hop found no check to end, so the check does not start.
            if cancelled {
                await Self.markCancelled(step)
                return false
            }

            let health = await runHealthCheck(healthCmd, step: step)

            if cancelled {
                await Self.markCancelled(step)
                return false
            }

            if !health.succeeded {
                await MainActor.run {
                    step.status = .failed
                    step.completedAt = .now
                    if health.timedOut {
                        step.errorMessage = "Health check timed out after \(Self.healthCheckTimeout.components.seconds)s"
                        step.recoveryGuidance = "The step ran, but its check did not answer. Retry the step."
                    } else if step.errorMessage == nil {
                        step.errorMessage = "Health check failed after successful execution"
                        step.recoveryGuidance = "The step ran but the expected result was not found. Check the output."
                    } else {
                        step.recoveryGuidance = "The step ran, but its check found a problem. Read the log, then retry the step."
                    }
                    step.recoveryAction = .retryFromStep
                }
                return false
            }
        }

        await MainActor.run {
            step.status = .passed
            step.completedAt = .now
        }
        return true
    }

    /// A cancel is not a fault: the step has no error, and no issue is filed.
    private static func markCancelled(_ step: DbSetupStep) async {
        await MainActor.run {
            step.status = .cancelled
            step.completedAt = .now
            step.errorMessage = nil
            step.recoveryGuidance = nil
            step.recoveryAction = nil
        }
    }

    /// Runs the command of a step to its end. It returns once every line of the
    /// step is in the step's log, so the caller reads the whole output.
    /// - Returns: the exit code (128 plus the signal for a kill, -1 when the
    ///   command did not start), and the limit that stopped the step, if any.
    private func runCommand(of step: DbSetupStep) async -> (exitCode: Int32, timeout: StepTimeout?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launcher.executable)
        process.arguments = launcher.arguments(tools.wrap(step.command, cwd: portalCwd))
        process.currentDirectoryURL = URL(fileURLWithPath: portalCwd)
        process.environment = Self.environment(
            parent: ProcessInfo.processInfo.environment,
            seedScenarioID: seedScenarioID, profile: profile
        )
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let clock = self.clock
        let watch = StepWatch(now: clock.uptime())
        let (lines, continuation) = AsyncStream<OutputLine>.makeStream()
        let reader = PipeLineReader(
            handle: pipe.fileHandleForReading,
            onData: { watch.output(at: clock.uptime()) },
            onLines: { for line in $0 { continuation.yield(OutputLine(text: line, stream: .stdout)) } },
            onClose: { continuation.finish() }
        )
        let exit = ExitSignal()
        process.terminationHandler = { ended in
            reader.processEnded()
            exit.resolve(ended.terminationReason == .uncaughtSignal
                ? 128 + ended.terminationStatus
                : ended.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            reader.finish()
            await Self.record(lines, step: step, logStore: logStore)
            let entry = LogEntry(stream: .stderr, text: "The step did not start: \(error.localizedDescription)")
            await MainActor.run { step.logEntries.append(entry) }
            return (-1, nil)
        }
        let pid = process.processIdentifier
        running.pid = pid
        runningOutput = reader
        await logStore.markStart(serviceID: step.logKey, name: step.name, pid: pid)

        let logStore = self.logStore
        let consumer = Task.detached { await Self.record(lines, step: step, logStore: logStore) }
        let (idle, cap) = (step.idleTimeoutSeconds, step.hardCapSeconds)
        let watchdog = Task.detached {
            await Self.watch(
                pid: pid, watch: watch, output: reader, idleSeconds: idle, capSeconds: cap, clock: clock
            )
        }

        let code = await exit.wait()
        // The root can end while a child still handles its SIGTERM. A stop owns the
        // end of the step: the step ends when the stop has ended the whole tree.
        watchdog.cancel()
        await watchdog.value
        if let stop { await stop.value }
        if watch.timeout != nil || stop != nil { reader.finish() }
        await consumer.value
        running.pid = nil
        runningOutput = nil
        // A cancel that came while the last lines were read.
        if let stop { await stop.value }
        stop = nil
        return (code, watch.timeout)
    }

    /// Stops the step tree when it prints nothing for `idleSeconds` or runs past
    /// `capSeconds`. Ends when its task is cancelled, but a stop that has begun
    /// runs to its end.
    private static func watch(
        pid: pid_t, watch: StepWatch, output: PipeLineReader, idleSeconds: Int, capSeconds: Int,
        clock: RunnerClock
    ) async {
        while true {
            do { try await clock.wait(watchInterval) } catch { return }
            guard let timeout = StepTimeout.check(
                now: clock.uptime(), startedAt: watch.startedAt, lastOutputAt: watch.lastOutputAt,
                idleSeconds: idleSeconds, capSeconds: capSeconds
            ) else { continue }
            watch.timeout = timeout
            output.hold()
            await ProcessTree.terminate(ProcessTree.tree(of: pid))
            return
        }
    }

    /// The one consumer of the lines of a step: `##db:` lines go to the step, the
    /// rest to its log, in the order the step printed them.
    private static func record(_ lines: AsyncStream<OutputLine>, step: DbSetupStep, logStore: LogStore) async {
        for await line in lines {
            if line.text.hasPrefix("##db:") {
                let payload = String(line.text.dropFirst(5))
                await MainActor.run { parseProtocolLine(payload, step: step) }
            } else {
                let entry = LogEntry(stream: line.stream, text: line.text)
                await MainActor.run { step.logEntries.append(entry) }
                await logStore.append(serviceID: step.logKey, entry: entry)
            }
        }
    }

    // MARK: - Protocol Line Parser

    /// The scripts report progress as a fraction from 0 to 1.
    /// `step.progress` keeps that scale; the view and the status API read it.
    @MainActor
    static func parseProtocolLine(_ payload: String, step: DbSetupStep) {
        let parts = payload.split(separator: ":", maxSplits: 2).map(String.init)
        guard let type = parts.first else { return }

        switch type {
        case "status":
            let value = parts.count > 1 ? parts[1] : ""
            if value.hasPrefix("failed") {
                let message = parts.count > 2
                    ? parts[2]
                    : (value.count > 7 ? String(value.dropFirst(7)) : "Unknown error")
                // The script's summary can be only a count ("2 prerequisite(s) missing").
                // Keep the details that the health lines gave.
                let details = step.healthFailures.filter { !message.contains($0) }
                step.errorMessage = details.isEmpty
                    ? message
                    : "\(message): \(details.joined(separator: "; "))"
            }

        case "progress":
            if parts.count > 1, let fraction = Double(parts[1]), fraction.isFinite {
                step.progress = min(max(fraction, 0), 1)
                if parts.count > 2 {
                    step.progressLabel = parts[2]
                }
            }

        case "health":
            let result = parts.count > 1 ? parts[1] : ""
            let detail = parts.count > 2 ? parts[2] : ""
            if result == "pass" {
                step.healthResult = detail
            } else {
                step.healthResult = nil
                if !detail.isEmpty { step.healthFailures.append(detail) }
                step.errorMessage = "Health check: \(step.healthFailures.joined(separator: "; "))"
            }

        default:
            break
        }
    }

    // MARK: - Health Check

    /// `cancel()` is the only stop of a pipeline. Stop All cancels the task of the
    /// start, and an automatic reset runs inside that task. The shell of the health
    /// check ends a command at once when its task is cancelled, so the check runs in
    /// its own task, which `cancel()` cancels. Without this own task the step in
    /// flight would pass, its check would fail as "Cancelled", and the pipeline
    /// would break: a database that is reset and has no hotels.
    ///
    /// The output of the check goes to the log of the step, and its `##db:` lines
    /// to the step.
    private func runHealthCheck(_ command: String, step: DbSetupStep) async -> CommandResult {
        let (shell, cwd, logStore) = (shell, portalCwd, logStore)
        let environment = Self.environment(parent: [:], seedScenarioID: seedScenarioID, profile: profile)
        let task = Task {
            let (lines, continuation) = AsyncStream<OutputLine>.makeStream()
            let consumer = Task { await Self.record(lines, step: step, logStore: logStore) }
            let result = await shell.run(
                command, cwd: cwd, environment: environment, timeout: Self.healthCheckTimeout
            ) { text, stream in
                continuation.yield(OutputLine(text: text, stream: stream))
            }
            continuation.finish()
            await consumer.value
            return result
        }
        healthCheck = task
        let result = await task.value
        healthCheck = nil
        return result
    }
}
