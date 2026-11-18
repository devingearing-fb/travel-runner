import Foundation

enum ContainerRuntime: Sendable, Equatable {
    case docker
    case orbstack

    var displayName: String {
        switch self {
        case .docker: "Docker Desktop"
        case .orbstack: "OrbStack"
        }
    }

    var appName: String {
        switch self {
        case .docker: "Docker"
        case .orbstack: "OrbStack"
        }
    }

    /// How long the runner waits for a runtime that it opened.
    static let startTimeout: Duration = .seconds(120)
    /// The time between two checks while the runner waits.
    static let pollInterval: Duration = .seconds(2)
    /// How often the wait reports its progress.
    static let progressInterval: Duration = .seconds(10)
    /// The timeout of one docker command of a probe. A daemon that hangs counts as down.
    static let commandTimeout: Duration = .seconds(10)

    /// The runtime of this Mac: the one the last probe found in `docker context show`.
    /// Before that, OrbStack when its app is installed, else Docker Desktop.
    static func detect() -> ContainerRuntime {
        if let probed = Probed.shared.runtime { return probed }
        if FileManager.default.fileExists(atPath: "/Applications/OrbStack.app") {
            return .orbstack
        }
        return .docker
    }

    /// The runtime of a docker context. A context that does not name one (`default`)
    /// is read from the socket in docker's answer. Nil when neither tells.
    static func runtime(context: String?, socket: String? = nil) -> ContainerRuntime? {
        switch context {
        case "orbstack": return .orbstack
        case "desktop-linux": return .docker
        default: break
        }
        guard let socket else { return nil }
        if socket.contains("/.orbstack/") { return .orbstack }
        if socket.contains("/.docker/run/") || socket.contains("/.docker/desktop/") { return .docker }
        return nil
    }

    /// The socket of docker's `default` context when DOCKER_HOST is not set.
    static let defaultSocket = "/var/run/docker.sock"

    /// The target of a symlink, or nil. OrbStack and Docker Desktop link the
    /// default socket into their own folder (~/.orbstack/run, ~/.docker/run).
    static let readLink: @Sendable (String) -> String? = { path in
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    /// The runtime of a probe. For the `default` context with no socket or the
    /// default socket, the runtime is read from where the default socket links to.
    static func runtime(context: String?, socket: String?, readLink: (String) -> String?) -> ContainerRuntime? {
        if let found = runtime(context: context, socket: socket) { return found }
        guard context == "default", socket == nil || socket == defaultSocket else { return nil }
        return readLink(defaultSocket).flatMap { runtime(context: context, socket: $0) }
    }

    /// The socket that a docker error names (`unix:///var/run/docker.sock`), as a path.
    static func socket(in text: String) -> String? {
        guard let start = text.range(of: "unix://") else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.firstIndex { $0 == ":" || $0 == "\"" || $0.isWhitespace } ?? rest.endIndex
        var path = String(rest[..<end])
        // "…/docker.sock. Is the docker daemon running?"
        while path.hasSuffix(".") { path.removeLast() }
        return path.isEmpty ? nil : path
    }

    /// Asks docker which context it uses and whether its daemon answers.
    static func probe(
        shell: any CommandRunning = LoginShell(), timeout: Duration = commandTimeout,
        readLink: @Sendable (String) -> String? = readLink
    ) async -> ContainerRuntimeProbe {
        let shown = await shell.run("docker context show", timeout: timeout)
        if shown.exitCode == 127 || shown.stderr.contains("command not found") {
            return .cliMissing
        }
        // A login profile can print lines first: the context is the last line.
        let name = shown.succeeded
            ? shown.trimmedOutput.components(separatedBy: .newlines).last.map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 }
            : nil
        return await probeDaemon(contextName: name, shell: shell, timeout: timeout, readLink: readLink)
    }

    /// Asks the daemon of a known context.
    private static func probeDaemon(
        contextName: String?, shell: any CommandRunning, timeout: Duration, opened: Bool = false,
        readLink: (String) -> String?
    ) async -> ContainerRuntimeProbe {
        let ps = await shell.run("docker ps -q >/dev/null", timeout: timeout)
        if ps.exitCode == 127 || ps.stderr.contains("command not found") {
            return .cliMissing
        }
        let socket = socket(in: ps.stderr)
        let found = runtime(context: contextName, socket: socket, readLink: readLink)
        if let found { Probed.shared.runtime = found }
        let context = ContainerRuntimeContext(
            name: contextName, runtime: found ?? detect(), timedOut: ps.timedOut, opened: opened
        )
        if ps.succeeded { return .running(context) }
        if !ps.timedOut, ps.stderr.lowercased().contains("permission denied") {
            return .permissionDenied(context, socket: socket ?? "the Docker socket")
        }
        return .daemonDown(context)
    }

    /// Opens the runtime when its daemon does not answer, then checks it every
    /// `pollInterval` until it answers or `timeout` is over. A missing CLI and a
    /// refused connection return at once: waiting does not fix them.
    /// - Parameter onProgress: Gets a line when the runtime is opened and every
    ///   `progressInterval` of the wait.
    static func ensureRunning(
        timeout: Duration = startTimeout,
        shell: any CommandRunning = LoginShell(),
        clock: RunnerClock = .live,
        readLink: @Sendable (String) -> String? = readLink,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async -> ContainerRuntimeProbe {
        let first = await probe(shell: shell, readLink: readLink)
        guard case .daemonDown(let context) = first else { return first }
        let runtime = context.runtime
        await open(runtime, shell: shell)
        onProgress?("\(runtime.displayName) is not running — opening it and waiting up to \(timeout.components.seconds) s")
        let start = clock.uptime()
        var reported = Duration.zero
        var last = first
        while clock.uptime() - start < timeout {
            do {
                try await clock.sleep(for: pollInterval)
            } catch {
                return last
            }
            last = await probeDaemon(contextName: context.name, shell: shell, timeout: commandTimeout, opened: true, readLink: readLink)
            if case .daemonDown = last {
                let waited = clock.uptime() - start
                if waited - reported >= progressInterval, waited < timeout {
                    reported = waited
                    onProgress?("Waiting for \(runtime.displayName) — \(waited.components.seconds) s of \(timeout.components.seconds) s")
                }
                continue
            }
            return last
        }
        return last
    }

    /// Opens the runtime's app of this Mac.
    static func open(shell: any CommandRunning = LoginShell()) async {
        await open(detect(), shell: shell)
    }

    static func open(_ runtime: ContainerRuntime, shell: any CommandRunning) async {
        _ = await shell.run("open -a \(ShellQuote.quote(runtime.appName))", timeout: .seconds(10))
    }

    /// The runtime that the last probe found. The views read it without a command.
    /// Any probe writes it, a probe of a test too: a suite that probes or reads
    /// `detect()` clears it in setUp, and the tests must not run in parallel.
    private final class Probed: @unchecked Sendable {
        static let shared = Probed()
        private let lock = NSLock()
        private var value: ContainerRuntime?

        var runtime: ContainerRuntime? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    /// Forgets the runtime of the last probe. For tests.
    static func forgetProbed() {
        Probed.shared.runtime = nil
    }
}

/// The docker context of a probe and the runtime behind it.
struct ContainerRuntimeContext: Sendable, Equatable {
    /// The name `docker context show` printed. Nil when it printed none.
    var name: String?
    var runtime: ContainerRuntime
    /// True when `docker ps` did not answer within the timeout.
    var timedOut = false
    /// True when the runner opened the runtime before this probe.
    var opened = false
}

/// What a probe of the container runtime found.
enum ContainerRuntimeProbe: Sendable, Equatable {
    case cliMissing
    case daemonDown(ContainerRuntimeContext)
    case permissionDenied(ContainerRuntimeContext, socket: String)
    case running(ContainerRuntimeContext)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// The runtime of the probe; the runtime of this Mac when docker is missing.
    var runtime: ContainerRuntime {
        switch self {
        case .cliMissing: ContainerRuntime.detect()
        case .daemonDown(let context), .permissionDenied(let context, _), .running(let context): context.runtime
        }
    }

    static let cliMissingText = "docker was not found on Travel Runner's PATH — install OrbStack or Docker Desktop"

    /// What a failed probe means. Nil when the runtime runs.
    /// - Parameter waited: The wait for the runtime; nil when the runner did not wait.
    func failureText(waited: Duration?) -> String? {
        switch self {
        case .running:
            return nil
        case .cliMissing:
            return Self.cliMissingText
        case .permissionDenied(_, let socket):
            return "Docker refused the connection (permission denied on \(socket))"
        case .daemonDown(let context):
            guard let waited else { return "\(context.runtime.displayName) not responding" }
            return "\(context.runtime.displayName) did not answer after \(waited.components.seconds) s — open it, then press Retry"
        }
    }
}
