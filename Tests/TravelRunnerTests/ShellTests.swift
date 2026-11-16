import Foundation
import XCTest
@testable import TravelRunner

/// `Shell.execute` with small real programs of the system (`/bin/sh`).
final class ShellTests: XCTestCase {
    /// Collects lines from another thread.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func add(_ line: String) {
            lock.lock()
            values.append(line)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    private func sh(
        _ script: String, environment: [String: String] = [:], timeout: Duration = .seconds(20),
        onLine: (@Sendable (String, LogEntry.Stream) -> Void)? = nil
    ) async -> CommandResult {
        await Shell.execute("/bin/sh", ["-c", script], environment: environment, timeout: timeout, onLine: onLine)
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    func testTheResultHasBothStreamsAndTheExitCode() async {
        let result = await sh("echo out; echo err >&2; exit 3")

        XCTAssertEqual(result, CommandResult(exitCode: 3, stdout: "out\n", stderr: "err\n", timedOut: false))
        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.trimmedOutput, "out")
    }

    func testAZeroExitSucceeds() async {
        let result = await sh("true")
        XCTAssertTrue(result.succeeded)
    }

    func testAProgramThatDoesNotExistGivesMinusOne() async {
        let result = await Shell.execute("/nonexistent/tr-\(UUID().uuidString)", [])

        XCTAssertEqual(result.exitCode, -1)
        XCTAssertFalse(result.timedOut)
        XCTAssertFalse(result.stderr.isEmpty, "the reason is in stderr")
    }

    func testAFolderThatDoesNotExistGivesMinusOne() async {
        let result = await Shell.execute("/bin/sh", ["-c", "true"], cwd: "/nonexistent/tr-\(UUID().uuidString)")
        XCTAssertEqual(result.exitCode, -1)
    }

    func testTheCommandRunsInItsFolderWithItsEnvironment() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shell \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let result = await Shell.execute(
            "/bin/sh", ["-c", "pwd -P; echo \"$TR_TEST_VALUE\"; echo \"${HOME:+home}\""],
            cwd: folder.path, environment: ["TR_TEST_VALUE": "a b"]
        )

        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first.map { ($0 as NSString).lastPathComponent }, folder.lastPathComponent)
        XCTAssertEqual(lines.dropFirst().first, "a b")
        XCTAssertEqual(lines.last, "home", "the environment of the app stays")
    }

    /// A prompt must not wait for a person: stdin is at its end.
    func testStdinIsClosed() async {
        let began = Date()
        let result = await sh("cat; echo done")

        XCTAssertEqual(result.trimmedOutput, "done")
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    /// The old helpers read stdout after the exit. More output than a pipe holds
    /// blocked the command for ever.
    func testOutputLargerThanAPipeDoesNotBlock() async {
        let result = await sh("head -c 400000 /dev/zero | tr '\\0' o; head -c 400000 /dev/zero | tr '\\0' e >&2")

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.count, 400_000)
        XCTAssertEqual(result.stderr.count, 400_000)
    }

    func testATimeoutKillsTheCommandAndItsChildren() async throws {
        let began = Date()
        // The child prints its pid, then both wait far longer than the timeout.
        let result = await sh("sleep 60 & echo $!; wait", timeout: .milliseconds(600))
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, -1)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(elapsed, 6, "the result does not wait for the command")
        let child = try XCTUnwrap(pid_t(result.trimmedOutput), "the output before the timeout stays")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(isAlive(child), "the child process is gone too")
    }

    /// Negative control of the timeout: a command that ends in time is not marked.
    func testACommandThatEndsInTimeIsNotTimedOut() async {
        let result = await sh("sleep 0.2; echo late", timeout: .seconds(10))

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.trimmedOutput, "late")
    }

    func testACommandThatIgnoresSigtermIsKilled() async {
        let began = Date()
        let result = await sh("trap '' TERM; while true; do sleep 1; done", timeout: .milliseconds(300))

        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(began), 8)
    }

    func testACancelledTaskKillsTheCommand() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("shell-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let path = pidFile.path
        let task = Task {
            await Shell.execute("/bin/sh", ["-c", "echo $$ > \"$0\"; exec sleep 60", path], timeout: .seconds(120))
        }
        var pid: pid_t?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(for: .milliseconds(50))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let started = try XCTUnwrap(pid)
        XCTAssertTrue(isAlive(started))

        let began = Date()
        task.cancel()
        let result = await task.value

        XCTAssertEqual(result.exitCode, -1)
        XCTAssertFalse(result.timedOut, "a cancel is not a timeout")
        XCTAssertLessThan(Date().timeIntervalSince(began), 6)
        XCTAssertFalse(isAlive(started))
    }

    /// A background child keeps the pipe open after the command ends. The old
    /// helpers waited for the end of the pipe, so they waited for the child.
    func testAChildThatKeepsThePipeOpenDoesNotHoldTheResult() async {
        let began = Date()
        let result = await sh("sleep 6 & echo started")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.trimmedOutput, "started")
        XCTAssertLessThan(Date().timeIntervalSince(began), 4)
    }

    func testEachLineArrivesOnceAndInOrder() async {
        let lines = Lines()
        // The pause splits "é" (two bytes) between two chunks. The last line has no newline.
        let result = await sh(
            "printf 'one\\r\\ncaf\\303'; sleep 0.3; printf '\\251\\ntwo'; echo problem >&2",
            onLine: { line, stream in lines.add("\(stream == .stdout ? "out" : "err"):\(line)") }
        )

        XCTAssertEqual(lines.all.filter { $0.hasPrefix("out:") }, ["out:one", "out:café", "out:two"])
        XCTAssertEqual(lines.all.filter { $0.hasPrefix("err:") }, ["err:problem"])
        XCTAssertEqual(result.stdout, "one\r\ncafé\ntwo", "the result keeps the raw text")
    }

    func testASignalGivesTheShellExitCode() async {
        let result = await sh("kill -KILL $$")
        XCTAssertEqual(result.exitCode, 128 + SIGKILL)
        XCTAssertFalse(result.timedOut)
    }

    func testTheTimeoutText() {
        XCTAssertEqual(Shell.timeoutText("docker ps", after: .seconds(15)), "docker ps did not answer in 15 s")
    }

    // MARK: - ProcessTree

    func testDescendantsWalksTheWholeTree() {
        // 1 → 10 → 11 → 12, and 1 → 20. 30 belongs to another parent.
        let parents: [pid_t: pid_t] = [10: 1, 11: 10, 12: 11, 20: 1, 30: 2, 1: 0]

        XCTAssertEqual(ProcessTree.descendants(of: 1, parents: parents), [10, 20, 11, 12])
        XCTAssertEqual(ProcessTree.descendants(of: 11, parents: parents), [12])
        XCTAssertEqual(ProcessTree.descendants(of: 12, parents: parents), [])
    }

    func testDescendantsReadsTheProcessTableOfTheSystem() async throws {
        let lines = Lines()
        // The shell is a child of the test process, and its `sleep` is a grandchild.
        let task = Task {
            await Shell.execute(
                "/bin/sh", ["-c", "sleep 30 & echo $!; wait"], timeout: .seconds(60),
                onLine: { line, _ in lines.add(line) }
            )
        }
        for _ in 0..<100 where lines.all.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let grandchild = try XCTUnwrap(lines.all.first.flatMap { pid_t($0) })

        XCTAssertTrue(ProcessTree.descendants(of: getpid()).contains(grandchild))
        XCTAssertTrue(ProcessTree.isAlive(grandchild))

        task.cancel()
        _ = await task.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(ProcessTree.isAlive(grandchild))
    }

    // MARK: - LoginShell

    /// The live runner: a login shell with the PATH of the tool environment. The
    /// folder has a space, as `Application Support` has.
    func testTheLoginShellFindsAToolOfTheToolEnvironment() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("shell home \(UUID().uuidString)")
        let tools = home.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        // A name that no Mac has, so the tools of this machine do not count.
        let tool = "tr-fake-tool-\(UUID().uuidString)"
        let file = tools.appendingPathComponent(tool)
        try "#!/bin/sh\necho v98.1.0\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        let with = ToolEnvironment(home: home.path, capture: .init(shellPath: [tools.path]))
        let found = await LoginShell(tools: with).run("\(tool) --version")
        XCTAssertEqual(found.trimmedOutput, "v98.1.0")

        // Negative control: without the directory the shell does not find it.
        let missing = await LoginShell(tools: ToolEnvironment(home: home.path)).run("\(tool) --version")
        XCTAssertEqual(missing.exitCode, 127)
    }
}
