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

/// Reads the pipe of a step into one stream of lines, in order. When the process
/// ends it reads what is left in the pipe, so the last lines (often the
/// `##db:status:failed` line) are never lost.
private final class StepOutputReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let decoder = UTF8ChunkDecoder()
    private let lines = TerminalLineBuffer()
    private let continuation: AsyncStream<OutputLine>.Continuation
    private let onOutput: @Sendable () -> Void
    private var finished = false

    /// How long the stream waits for a child process that keeps the pipe open
    /// after the step has ended.
    private static let pipeGrace: DispatchTimeInterval = .seconds(1)

    init(
        handle: FileHandle, continuation: AsyncStream<OutputLine>.Continuation,
        onOutput: @escaping @Sendable () -> Void
    ) {
        self.handle = handle
        self.continuation = continuation
        self.onOutput = onOutput
        // A read of an empty pipe returns at once, so the end of the process can
        // read the rest without a wait.
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        handle.readabilityHandler = { [weak self] _ in self?.readAvailable() }
    }

    func readAvailable() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if drain() { close() }
    }

    /// The process ended. Reads the rest of the pipe, and ends the stream at the
    /// end of the pipe, or after a short grace.
    func processEnded() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if drain() {
            close()
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.pipeGrace) { [self] in
            finish()
        }
    }

    /// Ends the stream now.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        _ = drain()
        close()
    }

    /// Reads until the pipe is empty. True at the end of the stream.
    private func drain() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let fd = handle.fileDescriptor
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                onOutput()
                emit(decoder.decode(Data(buffer[0..<count])))
            } else if count == 0 {
                return true
            } else if errno != EINTR {
                return false
            }
        }
    }

    private func emit(_ text: String) {
        for line in lines.feed(text) {
            continuation.yield(OutputLine(text: line, stream: .stdout))
        }
    }

    private func close() {
        finished = true
        handle.readabilityHandler = nil
        emit(decoder.flush())
        if let rest = lines.flush() {
            continuation.yield(OutputLine(text: rest, stream: .stdout))
        }
        continuation.finish()
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
    /// SIGKILL), and the health check. It returns when they are gone.
    func cancel() async {
        cancelled = true
        if let pid = running.pid {
            await ProcessTree.terminate(ProcessTree.tree(of: pid))
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
            step.healthResult = nil
            step.healthFailures = []
            step.progress = nil
            step.progressLabel = nil
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
            }
            return false
        }

        if exitCode != 0 {
            let stepId = step.id
            let output = await MainActor.run { step.logEntries.map(\.text) }
            let (msg, guidance) = Self.parseError(stepId: stepId, output: output, exitCode: exitCode)
            await MainActor.run {
                step.status = .failed
                step.completedAt = .now
                if step.errorMessage == nil {
                    step.errorMessage = msg
                    step.recoveryGuidance = guidance
                }
            }
            return false
        }

        // Run health check if defined
        if let healthCmd = step.healthCheckCommand {
            await MainActor.run { step.status = .healthCheck }

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
                    }
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
        let reader = StepOutputReader(handle: pipe.fileHandleForReading, continuation: continuation) {
            watch.output(at: clock.uptime())
        }
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
        await logStore.markStart(serviceID: step.logKey, name: step.name, pid: pid)

        let logStore = self.logStore
        let consumer = Task.detached { await Self.record(lines, step: step, logStore: logStore) }
        let (idle, cap) = (step.idleTimeoutSeconds, step.hardCapSeconds)
        let watchdog = Task.detached {
            await Self.watch(pid: pid, watch: watch, idleSeconds: idle, capSeconds: cap, clock: clock)
        }

        let code = await exit.wait()
        watchdog.cancel()
        await consumer.value
        running.pid = nil
        return (code, watch.timeout)
    }

    /// Stops the step tree when it prints nothing for `idleSeconds` or runs past
    /// `capSeconds`. Ends when its task is cancelled.
    private static func watch(
        pid: pid_t, watch: StepWatch, idleSeconds: Int, capSeconds: Int, clock: RunnerClock
    ) async {
        while true {
            do { try await clock.wait(watchInterval) } catch { return }
            guard let timeout = StepTimeout.check(
                now: clock.uptime(), startedAt: watch.startedAt, lastOutputAt: watch.lastOutputAt,
                idleSeconds: idleSeconds, capSeconds: capSeconds
            ) else { continue }
            watch.timeout = timeout
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

    // MARK: - Error Diagnostics

    private nonisolated static func parseError(
        stepId: String, output: [String], exitCode: Int32
    ) -> (message: String, guidance: String) {
        let combined = output.joined(separator: "\n").lowercased()

        switch stepId {
        case "reset-database":
            if let migLine = output.first(where: {
                $0.contains("Applying migration") && $0.lowercased().contains("error")
            }) {
                let filename = migLine.split(separator: " ")
                    .first(where: { $0.hasSuffix(".sql") })
                    .map(String.init) ?? "unknown"
                if combined.contains("violates foreign key") {
                    return ("Migration \(filename): FK constraint violation",
                            "Pull the latest monorepo and fb-amateur-backend, then retry")
                }
                if combined.contains("already exists") {
                    return ("Migration \(filename): object already exists",
                            "Run pnpm db:stop && pnpm db:start at the monorepo root for a clean slate")
                }
                return ("Migration \(filename) failed",
                        "Check the migration file for errors (supabase/migrations or the backend baseline).")
            }
            if combined.contains("could not connect") {
                return ("Database connection refused",
                        "Re-run from Start Supabase step")
            }

        case "load-hotels":
            if combined.contains("no such file") {
                return ("Hotel dump file not found",
                        "Run full setup to fetch hotel data from remote")
            }

        case "copy-event-data":
            if combined.contains("urlerror") || combined.contains("connection refused") {
                return ("Cannot reach remote Supabase API",
                        "Check internet connection")
            }
            if combined.contains("401") || combined.contains("403") {
                return ("Authentication failed",
                        "Check the remote Supabase credentials used by copy-remote-data.py")
            }

        case "start-supabase":
            if combined.contains("port") && combined.contains("already in use") {
                return ("Port already in use",
                        "Another Supabase instance may be running. Stop it (old checkouts: npx supabase stop; monorepo: pnpm db:stop) first.")
            }

        default:
            break
        }

        let lastLine = output.last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) ?? "Unknown error"
        return ("Exit code \(exitCode): \(String(lastLine.prefix(100)))",
                "Check the full output for details")
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
