import Foundation

/// How one command ended.
struct CommandResult: Sendable, Equatable {
    /// The exit code. 128 plus the signal number when a signal ended the command,
    /// and -1 when it did not start, timed out or was cancelled.
    var exitCode: Int32
    var stdout: String
    var stderr: String
    /// True when the command ran longer than its timeout and was killed.
    var timedOut: Bool = false

    var succeeded: Bool { exitCode == 0 && !timedOut }

    /// The standard output without the white space around it.
    var trimmedOutput: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Runs one shell command to its end. `LoginShell` is the live type. Tests use
/// `FakeCommandRunner`, so they do not depend on the tools of the machine.
protocol CommandRunning: Sendable {
    /// - Parameters:
    ///   - cwd: The folder of the command. Nil keeps the folder of the app.
    ///   - environment: Values to add to the environment of the app.
    ///   - timeout: The command and its child processes are killed after this time.
    ///   - onLine: Gets each full line while the command runs, in order, off the main thread.
    func run(
        _ command: String,
        cwd: String?,
        environment: [String: String],
        timeout: Duration,
        onLine: (@Sendable (_ line: String, _ stream: LogEntry.Stream) -> Void)?
    ) async -> CommandResult
}

extension CommandRunning {
    func run(
        _ command: String,
        cwd: String? = nil,
        environment: [String: String] = [:],
        timeout: Duration = Shell.defaultTimeout
    ) async -> CommandResult {
        await run(command, cwd: cwd, environment: environment, timeout: timeout, onLine: nil)
    }
}

/// Runs each command with the runner that `current` gives at that moment, so a
/// long-lived checker follows a runner that tests replace.
struct CurrentShell: CommandRunning {
    let current: @Sendable () async -> any CommandRunning

    func run(
        _ command: String,
        cwd: String?,
        environment: [String: String],
        timeout: Duration,
        onLine: (@Sendable (_ line: String, _ stream: LogEntry.Stream) -> Void)?
    ) async -> CommandResult {
        await current().run(command, cwd: cwd, environment: environment, timeout: timeout, onLine: onLine)
    }
}

/// A command in a login shell (`zsh -l -c`) with the PATH of `ToolEnvironment`.
struct LoginShell: CommandRunning {
    var tools: ToolEnvironment = .shared

    func run(
        _ command: String,
        cwd: String?,
        environment: [String: String],
        timeout: Duration,
        onLine: (@Sendable (_ line: String, _ stream: LogEntry.Stream) -> Void)?
    ) async -> CommandResult {
        // A command that starts during a resolve waits for the new PATH.
        await tools.settled()
        return await Shell.execute(
            Self.executable, Self.arguments(command, cwd: cwd, tools: tools),
            cwd: cwd, environment: environment, timeout: timeout, onLine: onLine
        )
    }

    static let executable = "/bin/zsh"

    /// The arguments of `zsh` that run `command` with the PATH of `tools`.
    static func arguments(_ command: String, cwd: String?, tools: ToolEnvironment) -> [String] {
        ["-l", "-c", tools.wrap(command, cwd: cwd)]
    }

    /// A process that runs `command` in a login shell, in `cwd`, with `environment`
    /// added to the environment of the app. The caller sets its pipes and runs it.
    static func process(
        _ command: String, cwd: String?, environment: [String: String]?, tools: ToolEnvironment
    ) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(command, cwd: cwd, tools: tools)
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.environment = ProcessInfo.processInfo.environment.merging(environment ?? [:]) { _, new in new }
        return process
    }
}

enum Shell {
    /// The timeout of a command that does not give its own.
    static let defaultTimeout: Duration = .seconds(30)

    /// What a check shows when its command was killed after the timeout.
    static func timeoutText(_ command: String, after timeout: Duration) -> String {
        "\(command) did not answer in \(timeout.components.seconds) s"
    }

    /// Runs one program to its end.
    ///
    /// - It reads both pipes while the program runs, so a full pipe cannot block it.
    /// - Stdin is `/dev/null`, so a prompt gets the end of input and does not wait.
    /// - On timeout, and when the task is cancelled, it kills the program and its
    ///   child processes.
    /// - It returns when the program has ended. A child that keeps a pipe open
    ///   holds the result for one second at most.
    static func execute(
        _ executable: String,
        _ arguments: [String],
        cwd: String? = nil,
        environment: [String: String] = [:],
        timeout: Duration = defaultTimeout,
        onLine: (@Sendable (_ line: String, _ stream: LogEntry.Stream) -> Void)? = nil
    ) async -> CommandResult {
        let execution = Execution(
            executable: executable, arguments: arguments, cwd: cwd,
            environment: environment, timeout: timeout, onLine: onLine
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { execution.start($0) }
        } onCancel: {
            execution.cancel()
        }
    }

    /// One run of `execute`. All state changes happen on `queue`.
    private final class Execution: @unchecked Sendable {
        private let executable: String
        private let arguments: [String]
        private let cwd: String?
        private let environment: [String: String]
        private let timeout: Duration
        private let onLine: (@Sendable (String, LogEntry.Stream) -> Void)?

        private let queue = DispatchQueue(label: "travel-runner.shell")
        private let process = Process()
        private let pipes = [Pipe(), Pipe()]
        private var collected = [Data(), Data()]
        private var pending = [Data(), Data()]
        private var openStreams = 2
        private var continuation: CheckedContinuation<CommandResult, Never>?
        private var exitCode: Int32?
        private var timedOut = false
        private var cancelled = false
        private var started = false
        private var finished = false
        private var killing = false

        /// The time between SIGTERM and SIGKILL.
        private static let killGrace: DispatchTimeInterval = .seconds(2)
        /// How long the result waits for a pipe that a child process keeps open.
        private static let pipeGrace: DispatchTimeInterval = .seconds(1)

        init(
            executable: String, arguments: [String], cwd: String?, environment: [String: String],
            timeout: Duration, onLine: (@Sendable (String, LogEntry.Stream) -> Void)?
        ) {
            self.executable = executable
            self.arguments = arguments
            self.cwd = cwd
            self.environment = environment
            self.timeout = timeout
            self.onLine = onLine
        }

        func start(_ continuation: CheckedContinuation<CommandResult, Never>) {
            queue.async { self.launch(continuation) }
        }

        func cancel() {
            queue.async {
                self.cancelled = true
                if self.started { self.killTree() }
            }
        }

        private func launch(_ continuation: CheckedContinuation<CommandResult, Never>) {
            self.continuation = continuation
            if cancelled {
                finish(exitCode: -1, stderr: "Cancelled")
                return
            }

            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            if !environment.isEmpty {
                process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            }
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipes[0]
            process.standardError = pipes[1]

            for index in pipes.indices {
                pipes[index].fileHandleForReading.readabilityHandler = { [self] handle in
                    let data = handle.availableData
                    // `sync` keeps the chunks of one pipe in order.
                    queue.sync {
                        if data.isEmpty {
                            handle.readabilityHandler = nil
                            closeStream(index)
                        } else {
                            consume(data, index)
                        }
                    }
                }
            }
            process.terminationHandler = { [self] ended in
                let code = ended.terminationReason == .uncaughtSignal
                    ? 128 + ended.terminationStatus
                    : ended.terminationStatus
                queue.async { self.processEnded(code) }
            }

            do {
                try process.run()
            } catch {
                for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
                finish(exitCode: -1, stderr: error.localizedDescription)
                return
            }
            started = true

            let (seconds, attoseconds) = timeout.components
            let nanoseconds = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
            queue.asyncAfter(deadline: .now() + .nanoseconds(Int(clamping: nanoseconds))) { [self] in
                guard !finished, exitCode == nil else { return }
                timedOut = true
                killTree()
            }
        }

        private func consume(_ data: Data, _ index: Int) {
            guard !finished else { return }
            collected[index].append(data)
            guard let onLine else { return }
            pending[index].append(data)
            // Split on the newline byte, so a character that two chunks share stays whole.
            while let newline = pending[index].firstIndex(of: 0x0A) {
                onLine(Self.line(pending[index][pending[index].startIndex..<newline]), Self.stream(index))
                pending[index] = Data(pending[index][(newline + 1)...])
            }
        }

        private func closeStream(_ index: Int) {
            guard !finished else { return }
            openStreams -= 1
            finishIfDone()
        }

        private func processEnded(_ code: Int32) {
            exitCode = code
            finishIfDone()
            guard !finished else { return }
            // A child process that outlives the command can keep a pipe open.
            queue.asyncAfter(deadline: .now() + Self.pipeGrace) { [self] in
                guard !finished else { return }
                finish(exitCode: code)
            }
        }

        private func finishIfDone() {
            guard let exitCode, openStreams == 0 else { return }
            finish(exitCode: exitCode)
        }

        /// SIGTERM to the program and its child processes, then SIGKILL to what is left.
        private func killTree() {
            guard !killing, exitCode == nil else { return }
            killing = true
            let root = process.processIdentifier
            // Read the tree before the first signal: a child of a dead parent moves to launchd.
            let tree = ProcessTree.descendants(of: root) + [root]
            for pid in tree { kill(pid, SIGTERM) }
            queue.asyncAfter(deadline: .now() + Self.killGrace) { [self] in
                for pid in tree where ProcessTree.isAlive(pid) { kill(pid, SIGKILL) }
                queue.asyncAfter(deadline: .now() + Self.pipeGrace) { [self] in
                    guard !finished else { return }
                    finish(exitCode: -1)
                }
            }
        }

        private func finish(exitCode: Int32, stderr: String? = nil) {
            guard !finished else { return }
            finished = true
            for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
            if let onLine {
                for index in pending.indices where !pending[index].isEmpty {
                    onLine(Self.line(pending[index]), Self.stream(index))
                }
            }
            let stopped = timedOut || cancelled
            continuation?.resume(returning: CommandResult(
                exitCode: stopped ? -1 : exitCode,
                stdout: String(decoding: collected[0], as: UTF8.self),
                stderr: stderr ?? String(decoding: collected[1], as: UTF8.self),
                timedOut: timedOut
            ))
            continuation = nil
        }

        private static func stream(_ index: Int) -> LogEntry.Stream {
            index == 0 ? .stdout : .stderr
        }

        private static func line(_ data: Data) -> String {
            var data = data
            if data.last == 0x0D { data.removeLast() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
