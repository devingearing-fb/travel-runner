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
    }

    private var launches: [String: Launch] = [:]
    /// Exits by pid, so a caller that waits for one launch does not read another's exit.
    private var exits: [pid_t: Termination] = [:]
    private var exitOrder: [pid_t] = []
    private let exitHistoryLimit = 64

    func start(
        service: ServiceDefinition,
        onStdout: @escaping @Sendable ([String]) -> Void,
        onStderr: @escaping @Sendable ([String]) -> Void,
        onTermination: @escaping @Sendable (Termination) -> Void
    ) throws -> Int32 {
        // Two processes of one service fight for its port. Callers stop the old
        // process first; this covers a caller that did not.
        if let running = launches[service.id], running.process.isRunning {
            running.stopFlag.set()
            for pid in collectAllDescendants(of: running.pid) + [running.pid] {
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
        process.arguments = ["-l", "-c", ShellQuote.join(service.cmd)]

        var env = ProcessInfo.processInfo.environment
        if let overrides = service.env {
            for (key, value) in overrides {
                env[key] = value
            }
        }
        process.environment = env
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutBuffer = TerminalLineBuffer()
        let stderrBuffer = TerminalLineBuffer()

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = stdoutBuffer.feed(text)
            guard !lines.isEmpty else { return }
            onStdout(lines)
        }

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = stderrBuffer.feed(text)
            guard !lines.isEmpty else { return }
            onStderr(lines)
        }

        let stopFlag = StopFlag()
        let serviceID = service.id

        process.terminationHandler = { [weak self] proc in
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            if let remaining = stdoutBuffer.flush() { onStdout([remaining]) }
            if let remaining = stderrBuffer.flush() { onStderr([remaining]) }
            let termination = Termination(
                pid: proc.processIdentifier,
                status: proc.terminationStatus,
                bySignal: proc.terminationReason == .uncaughtSignal,
                stoppedByRunner: stopFlag.isSet
            )
            Task { await self?.recordExit(serviceID: serviceID, termination: termination) }
            onTermination(termination)
        }

        try process.run()
        let pid = process.processIdentifier

        // The system can give a new process the pid of an old one.
        forgetExit(of: pid)
        launches[service.id] = Launch(process: process, pid: pid, stopFlag: stopFlag)
        return pid
    }

    func stop(serviceID: String) async {
        guard let launch = launches[serviceID] else { return }
        launch.stopFlag.set()

        // Collect the full descendant tree BEFORE sending any signals.
        // Once the parent receives SIGTERM and dies, its children are
        // reparented to launchd (PID 1) and pgrep -P can't find them.
        let tree = collectAllDescendants(of: launch.pid) + [launch.pid]
        await terminate(tree)

        if launches[serviceID]?.pid == launch.pid {
            launches.removeValue(forKey: serviceID)
        }
    }

    func stopAll() async {
        let stopping = launches
        var tree: [pid_t] = []
        for launch in stopping.values {
            launch.stopFlag.set()
            tree.append(contentsOf: collectAllDescendants(of: launch.pid))
            tree.append(launch.pid)
        }

        await terminate(tree)

        for (serviceID, launch) in stopping where launches[serviceID]?.pid == launch.pid {
            launches.removeValue(forKey: serviceID)
        }
    }

    func isRunning(serviceID: String) -> Bool {
        launches[serviceID]?.process.isRunning ?? false
    }

    /// How the process with this pid ended, or nil while it runs.
    func exit(of pid: Int32) -> Termination? {
        exits[pid]
    }

    // MARK: - Private

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

    /// Sends SIGTERM, then SIGKILL to what is still alive after `grace`. It returns
    /// when the processes are gone, so the caller can start the service again.
    private func terminate(_ pids: [pid_t], grace: Duration = .seconds(2)) async {
        guard !pids.isEmpty else { return }

        for pid in pids {
            kill(pid, SIGTERM)
        }
        if await waitUntilGone(pids, timeout: grace) { return }

        for pid in pids where Self.isAlive(pid) {
            kill(pid, SIGKILL)
        }
        _ = await waitUntilGone(pids, timeout: .seconds(1))
    }

    private func waitUntilGone(_ pids: [pid_t], timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if !pids.contains(where: Self.isAlive) { return true }
            if ContinuousClock.now >= deadline { return false }
            await Self.pause(milliseconds: 50)
        }
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// A wait that a cancelled task does not cut short: a stop must finish.
    private static func pause(milliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }

    private func collectAllDescendants(of rootPid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [rootPid]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = directChildren(of: current)
            result.append(contentsOf: children)
            queue.append(contentsOf: children)
        }

        return result
    }

    private func directChildren(of pid: pid_t) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                pid_t($0.trimmingCharacters(in: .whitespaces))
            }
        } catch {
            return []
        }
    }
}
