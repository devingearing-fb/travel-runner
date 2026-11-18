import Foundation

actor ProcessRunner {
    /// How one service process ended.
    struct Termination: Sendable, Equatable {
        let pid: Int32
        /// The exit code, or the signal number when `bySignal` is true.
        let status: Int32
        let bySignal: Bool
        /// True when `stop` or `stopAll` ended this process. The mark belongs to the
        /// launch, so it stays correct after the service has started again.
        let stoppedByRunner: Bool
    }

    /// Set by `stop` before the first signal. The termination handler of the same
    /// launch reads it on another thread.
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private struct Launch {
        let process: Process
        let pid: pid_t
        let stopFlag: StopFlag
        let service: ServiceDefinition
        let onStdout: @Sendable ([String]) -> Void
        let onStderr: @Sendable ([String]) -> Void
    }

    private var launches: [String: Launch] = [:]
    /// Exits by pid, so a caller that waits for one launch does not read another's exit.
    private var exits: [pid_t: Termination] = [:]
    private var exitOrder: [pid_t] = []
    private let exitHistoryLimit = 64
    /// The PATH of each service command.
    private let tools: ToolEnvironment
    /// Runs the stop command of a service. Tests give a fake.
    private let shell: any CommandRunning

    init(tools: ToolEnvironment = .shared, shell: (any CommandRunning)? = nil) {
        self.tools = tools
        self.shell = shell ?? LoginShell(tools: tools)
    }

    /// Starts the process of a service. It does not wait for anything before it
    /// writes `launches`, so a `stop` or a `stopAll` that comes later always sees
    /// the process. The caller waits for a read of the shell (`tools.settled()`)
    /// and then checks that the start is still wanted.
    func start(
        service: ServiceDefinition,
        onStdout: @escaping @Sendable ([String]) -> Void,
        onStderr: @escaping @Sendable ([String]) -> Void,
        onTermination: @escaping @Sendable (Termination) -> Void
    ) async throws -> Int32 {
        // Two processes of one service fight for its port. Callers stop the old
        // process first; this covers a caller that did not.
        if let running = launches[service.id], running.process.isRunning {
            running.stopFlag.set()
            for pid in ProcessTree.tree(of: running.pid) {
                kill(pid, SIGTERM)
            }
        }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        if let cwd = service.resolvedCwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", tools.wrap(ShellQuote.join(service.cmd), cwd: service.resolvedCwd)]

        var env = ProcessInfo.processInfo.environment
        if let overrides = service.env {
            for (key, value) in overrides {
                env[key] = value
            }
        }
        process.environment = env
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Each reader reads its pipe to the end when the process ends, so the last
        // lines of a crash (often the stack trace) come before the termination.
        let outputClosed = DispatchGroup()
        outputClosed.enter()
        outputClosed.enter()
        let stdoutReader = PipeLineReader(
            handle: stdoutPipe.fileHandleForReading,
            onLines: onStdout,
            onClose: { outputClosed.leave() }
        )
        let stderrReader = PipeLineReader(
            handle: stderrPipe.fileHandleForReading,
            onLines: onStderr,
            onClose: { outputClosed.leave() }
        )

        let stopFlag = StopFlag()
        let serviceID = service.id

        process.terminationHandler = { [weak self] proc in
            let termination = Termination(
                pid: proc.processIdentifier,
                status: proc.terminationStatus,
                bySignal: proc.terminationReason == .uncaughtSignal,
                stoppedByRunner: stopFlag.isSet
            )
            stdoutReader.processEnded()
            stderrReader.processEnded()
            outputClosed.notify(queue: .global()) {
                Task { await self?.recordExit(serviceID: serviceID, termination: termination) }
                onTermination(termination)
            }
        }

        try process.run()
        let pid = process.processIdentifier

        // The system can give a new process the pid of an old one.
        forgetExit(of: pid)
        launches[service.id] = Launch(
            process: process, pid: pid, stopFlag: stopFlag, service: service,
            onStdout: onStdout, onStderr: onStderr
        )
        return pid
    }

    /// Runs the stop command of the service, then sends SIGTERM, and SIGKILL after
    /// the grace of the service.
    func stop(serviceID: String) async {
        guard let launch = launches[serviceID] else { return }
        launch.stopFlag.set()

        // `tree` reads the whole tree before the first signal.
        let tree = ProcessTree.tree(of: launch.pid)
        await runStopCommand(of: launch)
        await ProcessTree.terminate(tree, grace: launch.service.resolvedStopGrace)

        if launches[serviceID]?.pid == launch.pid {
            launches.removeValue(forKey: serviceID)
        }
    }

    /// `stop` for every launch at once. Each one gets its own stop command and grace.
    func stopAll() async {
        let stopping = launches
        var trees: [(launch: Launch, pids: [pid_t])] = []
        for launch in stopping.values {
            launch.stopFlag.set()
            trees.append((launch, ProcessTree.tree(of: launch.pid)))
        }

        await withTaskGroup(of: Void.self) { group in
            for (launch, pids) in trees {
                group.addTask {
                    await self.runStopCommand(of: launch)
                    await ProcessTree.terminate(pids, grace: launch.service.resolvedStopGrace)
                }
            }
        }

        for (serviceID, launch) in stopping where launches[serviceID]?.pid == launch.pid {
            launches.removeValue(forKey: serviceID)
        }
    }

    /// Starts the stop command of the service and does not wait for it. The app
    /// uses it as it quits: the teardown goes on after the app has ended.
    @discardableResult
    nonisolated static func startStopCommandDetached(
        of service: ServiceDefinition, tools: ToolEnvironment = .shared
    ) -> pid_t? {
        guard let command = service.resolvedStopCmd else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", tools.wrap(ShellQuote.join(command), cwd: service.resolvedCwd)]
        if let cwd = service.resolvedCwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        process.environment = ProcessInfo.processInfo.environment.merging(service.env ?? [:]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        return process.processIdentifier
    }

    /// True while a process that this runner started still runs.
    func hasRunningProcess() -> Bool {
        launches.values.contains { $0.process.isRunning }
    }

    func isRunning(serviceID: String) -> Bool {
        launches[serviceID]?.process.isRunning ?? false
    }

    /// How the process with this pid ended, or nil while it runs.
    func exit(of pid: Int32) -> Termination? {
        exits[pid]
    }

    // MARK: - Private

    /// Runs the stop command and waits for it, at most for the grace of the service.
    /// Its output goes to the log of the service.
    private func runStopCommand(of launch: Launch) async {
        guard let command = launch.service.resolvedStopCmd else { return }
        let text = ShellQuote.join(command)
        let grace = launch.service.resolvedStopGrace
        launch.onStdout(["[travel-runner] Stopping: \(text)"])
        let onStdout = launch.onStdout
        let onStderr = launch.onStderr
        let result = await shell.run(
            text, cwd: launch.service.resolvedCwd, environment: launch.service.env ?? [:], timeout: grace,
            onLine: { line, stream in stream == .stderr ? onStderr([line]) : onStdout([line]) }
        )
        if result.timedOut {
            onStderr(["[travel-runner] \(text) did not finish in \(grace.components.seconds) s and was stopped."])
        } else if !result.succeeded {
            onStderr(["[travel-runner] \(text) failed (exit \(result.exitCode))."])
        }
    }

    private func recordExit(serviceID: String, termination: Termination) {
        if exits[termination.pid] == nil {
            exitOrder.append(termination.pid)
            if exitOrder.count > exitHistoryLimit {
                exits.removeValue(forKey: exitOrder.removeFirst())
            }
        }
        exits[termination.pid] = termination

        // A dead process has no tree to stop, and its pid can go to another process.
        if launches[serviceID]?.pid == termination.pid {
            launches.removeValue(forKey: serviceID)
        }
    }

    private func forgetExit(of pid: pid_t) {
        guard exits.removeValue(forKey: pid) != nil else { return }
        exitOrder.removeAll { $0 == pid }
    }
}
