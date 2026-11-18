import Foundation

/// Who listens on a port, and which listeners the runner must never kill.
///
/// A container runtime publishes the ports of its containers through one helper
/// process. A kill of that helper stops every container on the Mac, so the port
/// cleanup skips it.
enum PortOwner {
    struct Listener: Equatable, Sendable {
        let pid: pid_t
        let command: String
    }

    /// Process names of the container runtimes (OrbStack, Docker Desktop, Lima, Colima).
    static let containerRuntimeCommands = [
        "OrbStack", "com.docker.backend", "com.docker.vpnkit", "vpnkit-bridge", "limactl", "colima",
    ]

    /// True when the command is a container runtime. `lsof` gives at most the first
    /// 16 characters of a name, and a helper has a suffix ("OrbStack Helper"), so
    /// both a longer and a cut name match.
    static func isContainerRuntime(_ command: String) -> Bool {
        let command = command.lowercased()
        guard !command.isEmpty else { return false }
        return containerRuntimeCommands.contains { name in
            let name = name.lowercased()
            return command.hasPrefix(name) || (command.count >= 9 && name.hasPrefix(command))
        }
    }

    /// `+c 0` asks for the full command name; the default is 9 characters.
    static func lsofArguments(port: Int) -> [String] {
        ["+c", "0", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
    }

    /// Reads the `-Fpc` output of `lsof`: a `p<pid>` line, then a `c<command>` line,
    /// for each process. Other field lines are ignored.
    static func parse(_ output: String) -> [Listener] {
        var listeners: [Listener] = []
        var pid: pid_t?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = pid_t(value)
            case "c":
                if let current = pid, !listeners.contains(where: { $0.pid == current }) {
                    listeners.append(Listener(pid: current, command: unescape(value)))
                }
                pid = nil
            default:
                break
            }
        }
        return listeners
    }

    /// `lsof` writes a character such as a space as `\x20` when its output is not a terminal.
    private static func unescape(_ text: String) -> String {
        guard text.contains("\\x") else { return text }
        var result = ""
        var rest = Substring(text)
        while let range = rest.range(of: "\\x") {
            result += rest[..<range.lowerBound]
            let hex = rest[range.upperBound...].prefix(2)
            if hex.count == 2, let code = UInt8(hex, radix: 16) {
                result.unicodeScalars.append(Unicode.Scalar(code))
                rest = rest[range.upperBound...].dropFirst(2)
            } else {
                result += "\\x"
                rest = rest[range.upperBound...]
            }
        }
        return result + rest
    }

    /// The processes that listen on the port. Empty when `lsof` fails.
    static func listeners(on port: Int) async -> [Listener] {
        let output = await run("/usr/sbin/lsof", lsofArguments(port: port))
        return parse(output ?? "")
    }

    /// The same answer without `await`, for the quit of the app.
    static func listenersNow(on port: Int) -> [Listener] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = lsofArguments(port: port)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Ownership

    /// Who a listener belongs to. An empty list of occupants is a free port.
    enum Owner: Equatable, Sendable {
        /// A process that this run of the app started, or a child of one.
        case ownLaunch(serviceID: String)
        /// A process of an earlier run (in the ledger), or one that runs in a folder of
        /// the configured repos (decision 15). `serviceID` is nil for the second kind.
        case ownLeftover(serviceID: String?)
        /// The port helper of a container runtime. It is never killed.
        case containerRuntime
        /// Anything else. The runner asks before it stops one.
        case foreign

        var isOwn: Bool {
            switch self {
            case .ownLaunch, .ownLeftover: true
            case .containerRuntime, .foreign: false
            }
        }
    }

    struct Occupant: Equatable, Sendable {
        let listener: Listener
        let owner: Owner
        /// The working directory of the listener, when the system gives it.
        var cwd: String? = nil
    }

    /// What the classification knows about the processes of the runner.
    struct Knowledge {
        /// The ledger entries whose process still runs.
        var ledger: [LaunchLedger.Entry] = []
        var sessionPIDs: Set<pid_t> = []
        /// The folders of the configured repos, resolved (`realPath`).
        var roots: [String] = []
        var facts: (pid_t) -> ProcessFacts? = { _ in nil }
        var ancestors: (pid_t) -> [pid_t] = { _ in [] }

        /// The ledger entry of the process or of one of its parents.
        func entry(owning pid: pid_t) -> LaunchLedger.Entry? {
            let chain = [pid] + ancestors(pid)
            return chain.lazy.compactMap { pid in ledger.first { $0.pid == pid } }.first
        }

        func isInRoots(_ cwd: String) -> Bool {
            roots.contains { cwd == $0 || cwd.hasPrefix($0 + "/") }
        }
    }

    static func owner(of listener: Listener, _ knowledge: Knowledge) -> Occupant {
        let cwd = knowledge.facts(listener.pid)?.cwd
        if isContainerRuntime(listener.command) {
            return Occupant(listener: listener, owner: .containerRuntime, cwd: cwd)
        }
        if let entry = knowledge.entry(owning: listener.pid) {
            let owner: Owner = knowledge.sessionPIDs.contains(entry.pid)
                ? .ownLaunch(serviceID: entry.serviceID) : .ownLeftover(serviceID: entry.serviceID)
            return Occupant(listener: listener, owner: owner, cwd: cwd)
        }
        if let cwd, knowledge.isInRoots(cwd) {
            return Occupant(listener: listener, owner: .ownLeftover(serviceID: nil), cwd: cwd)
        }
        return Occupant(listener: listener, owner: .foreign, cwd: cwd)
    }

    static func classify(_ listeners: [Listener], _ knowledge: Knowledge) -> [Occupant] {
        listeners.map { owner(of: $0, knowledge) }
    }

    /// The roots of the ownership rule: each folder resolved, without "" and "/",
    /// which would make every process an own one.
    static func roots(_ folders: some Sequence<String>) -> [String] {
        Set(folders.filter { !$0.isEmpty }.map(realPath)).filter { $0 != "/" }.sorted()
    }

    /// The path with its links resolved, as the system gives the working directory
    /// of a process (`/private/var/…` for `/var/…`). The path itself when it does not exist.
    static func realPath(_ path: String) -> String {
        guard let resolved = Darwin.realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A path for the person: the home folder as `~`.
    static func displayPath(_ path: String) -> String {
        let home = realPath(NSHomeDirectory())
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    /// The refusal of a start when a process that the runner did not start holds the port.
    static func foreignText(port: Int, occupant: Occupant, service: String) -> String {
        var place = "PID \(occupant.listener.pid)"
        if let cwd = occupant.cwd { place += ", \(displayPath(cwd))" }
        return "Port \(port) is in use by \(occupant.listener.command) (\(place)), which \(Flavor.current.displayName) did not start. \(service) was not started."
    }

    // MARK: - Another next dev

    /// True for a process of `next dev`: the `next` CLI with `dev`, or its server
    /// (`next-server (v16.2.6)`).
    static func isNextDev(_ arguments: [String]) -> Bool {
        if arguments.first?.hasPrefix("next-server") == true { return true }
        guard let next = arguments.firstIndex(where: { ($0 as NSString).lastPathComponent == "next" }) else { return false }
        return arguments[arguments.index(after: next)...].contains("dev")
    }

    /// The `next dev` processes in the folder of a service that the runner did not
    /// start. Of a parent and its child, only the parent: a stop of it stops both.
    static func otherNextDevs(_ processes: [ProcessFacts], _ knowledge: Knowledge) -> [ProcessFacts] {
        let matches = processes.filter { isNextDev($0.arguments) && knowledge.entry(owning: $0.pid) == nil }
        let pids = Set(matches.map(\.pid))
        return matches.filter { process in !knowledge.ancestors(process.pid).contains { pids.contains($0) } }
    }

    /// The folder for the person: the part below the repo that holds it
    /// (`apps/booking-portal`), or the name of the folder when it is a repo root.
    static func folderName(_ folder: String, roots: [String]) -> String {
        let folder = realPath(folder)
        if let root = roots.filter({ folder.hasPrefix($0 + "/") }).min(by: { $0.count < $1.count }) {
            return String(folder.dropFirst(root.count + 1))
        }
        return (folder as NSString).lastPathComponent
    }

    static func otherNextDevText(pid: pid_t, port: Int?, folder: String) -> String {
        let place = port.map { "PID \(pid), port \($0)" } ?? "PID \(pid)"
        return "Another next dev (\(place)) is running in \(folder). Next allows one dev server per folder."
    }

    /// The TCP ports that the processes listen on, from `lsof -Fn` (`n*:3006`, `n[::1]:3006`).
    static func parsePorts(_ output: String) -> [Int] {
        var ports: [Int] = []
        for line in output.split(whereSeparator: \.isNewline) where line.first == "n" {
            if let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]), !ports.contains(port) {
                ports.append(port)
            }
        }
        return ports.sorted()
    }

    /// The listening ports of the processes. Empty when `lsof` fails.
    static func listeningPorts(of pids: [pid_t]) async -> [Int] {
        guard !pids.isEmpty else { return [] }
        let list = pids.map(String.init).joined(separator: ",")
        let output = await run("/usr/sbin/lsof", ["-nP", "-a", "-p", list, "-iTCP", "-sTCP:LISTEN", "-Fn"])
        return parsePorts(output ?? "")
    }

    /// A `pkill -f` pattern that matches this command line and no other: the
    /// arguments joined by spaces, with each regex character made literal.
    static func commandPattern(for cmd: [String]) -> String {
        let special = Set("\\.^$*+?()[]{}|")
        return String(cmd.joined(separator: " ").flatMap { special.contains($0) ? ["\\", $0] : [$0] })
    }

    /// Kills each process whose command line matches the pattern.
    static func killCommands(matching pattern: String) async {
        guard !pattern.isEmpty else { return }
        _ = await run("/usr/bin/pkill", ["-f", "--", pattern])
    }

    private static func run(_ executable: String, _ arguments: [String]) async -> String? {
        let result = await Shell.execute(executable, arguments, timeout: .seconds(10))
        // -1: the tool did not start, or it did not end in time.
        return result.exitCode == -1 ? nil : result.stdout
    }
}

/// The tools of the port cleanup. The lifecycle tests replace them, so a test
/// never kills a process that it did not start.
///
/// The tools that read or stop other processes do nothing in a test that does not
/// set them: a test never reads or stops a process of this Mac by mistake.
struct PortTools: Sendable {
    var listeners: @Sendable (Int) async -> [PortOwner.Listener]
    var kill: @Sendable (pid_t) -> Void
    var killCommands: @Sendable (String) async -> Void
    /// The start time, folder and arguments of a process (`ProcessTree.facts`).
    var facts: @Sendable (pid_t) -> ProcessFacts? = { _ in nil }
    /// The parents of a process, nearest first.
    var ancestors: @Sendable (pid_t) -> [pid_t] = { _ in [] }
    /// The processes of this user that run in a folder.
    var processesIn: @Sendable (String) -> [ProcessFacts] = { _ in [] }
    /// The TCP ports that a process and its children listen on.
    var listeningPorts: @Sendable (pid_t) async -> [Int] = { _ in [] }
    /// Stops a process and its children: SIGTERM, then SIGKILL after the grace.
    var stopTree: @Sendable (pid_t) async -> Void = { _ in }
    /// The listeners of a port without `await`, for the quit of the app.
    var listenersNow: @Sendable (Int) -> [PortOwner.Listener] = { _ in [] }
    /// A process and its children (`ProcessTree.tree`), read before a signal.
    var tree: @Sendable (pid_t) -> [pid_t] = { [$0] }

    static let live = PortTools(
        listeners: { await PortOwner.listeners(on: $0) },
        kill: { _ = Darwin.kill($0, SIGKILL) },
        killCommands: { await PortOwner.killCommands(matching: $0) },
        facts: { ProcessTree.facts(of: $0) },
        ancestors: { ProcessTree.ancestors(of: $0) },
        processesIn: { ProcessTree.processes(in: $0) },
        listeningPorts: { await PortOwner.listeningPorts(of: ProcessTree.tree(of: $0)) },
        stopTree: { await ProcessTree.terminate(ProcessTree.tree(of: $0)) },
        listenersNow: { PortOwner.listenersNow(on: $0) },
        tree: { ProcessTree.tree(of: $0) }
    )
}
