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

    /// The listeners that a port sweep may kill: all but a container runtime.
    static func killable(_ listeners: [Listener]) -> [Listener] {
        listeners.filter { !isContainerRuntime($0.command) }
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
struct PortTools: Sendable {
    var listeners: @Sendable (Int) async -> [PortOwner.Listener]
    var kill: @Sendable (pid_t) -> Void
    var killCommands: @Sendable (String) async -> Void

    static let live = PortTools(
        listeners: { await PortOwner.listeners(on: $0) },
        kill: { _ = Darwin.kill($0, SIGKILL) },
        killCommands: { await PortOwner.killCommands(matching: $0) }
    )
}
