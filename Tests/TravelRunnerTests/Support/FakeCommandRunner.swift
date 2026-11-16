import Foundation
@testable import TravelRunner

/// A `CommandRunning` that starts no process. A test gives the answer of each
/// command and reads the calls afterwards.
final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    struct Call: Sendable, Equatable {
        let command: String
        let cwd: String?
        let environment: [String: String]
        let timeout: Duration
    }

    typealias Handler = @Sendable (Call) async -> CommandResult

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var handler: Handler

    /// Without a handler each command succeeds with no output.
    init(_ handler: @escaping Handler = { _ in FakeCommandRunner.ok() }) {
        self.handler = handler
    }

    static func ok(_ stdout: String = "") -> CommandResult {
        CommandResult(exitCode: 0, stdout: stdout, stderr: "")
    }

    static func failed(_ exitCode: Int32 = 1, stderr: String = "") -> CommandResult {
        CommandResult(exitCode: exitCode, stdout: "", stderr: stderr)
    }

    static let timedOut = CommandResult(exitCode: -1, stdout: "", stderr: "", timedOut: true)

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var commands: [String] { calls.map(\.command) }

    /// Replaces the answers of the next commands.
    func respond(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    private func record(_ call: Call) -> Handler {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(call)
        return handler
    }

    func run(
        _ command: String,
        cwd: String?,
        environment: [String: String],
        timeout: Duration,
        onLine: (@Sendable (_ line: String, _ stream: LogEntry.Stream) -> Void)?
    ) async -> CommandResult {
        let call = Call(command: command, cwd: cwd, environment: environment, timeout: timeout)
        let result = await record(call)(call)
        if let onLine {
            for line in result.stdout.split(whereSeparator: \.isNewline) { onLine(String(line), .stdout) }
            for line in result.stderr.split(whereSeparator: \.isNewline) { onLine(String(line), .stderr) }
        }
        return result
    }
}
