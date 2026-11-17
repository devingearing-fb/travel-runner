import Foundation
import XCTest
@testable import TravelRunner

final class ProcessRunnerTests: XCTestCase {
    /// Collects the termination of one launch.
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ProcessRunner.Termination?

        func set(_ termination: ProcessRunner.Termination) {
            lock.lock()
            value = termination
            lock.unlock()
        }

        var termination: ProcessRunner.Termination? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private func service(_ id: String, _ cmd: [String]) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: nil, cmd: cmd, cwd: nil, probe: nil, type: nil, restart: nil,
            dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
    }

    private func start(_ runner: ProcessRunner, _ definition: ServiceDefinition, _ box: Box) async throws -> Int32 {
        try await runner.start(
            service: definition,
            onStdout: { _ in },
            onStderr: { _ in },
            onTermination: { box.set($0) }
        )
    }

    private func waitForTermination(_ box: Box, seconds: Double = 10) async -> ProcessRunner.Termination? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let termination = box.termination { return termination }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return box.termination
    }

    private func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    func testAStopMarksTheTermination() async throws {
        let runner = ProcessRunner()
        let box = Box()
        let pid = try await start(runner, service("svc", ["sleep", "30"]), box)

        await runner.stop(serviceID: "svc")

        let termination = await waitForTermination(box)
        XCTAssertEqual(termination?.stoppedByRunner, true)
        XCTAssertEqual(termination.map(ServiceTermination.classify), .stoppedByRunner)
        XCTAssertFalse(isAlive(pid), "stop returns after the process is gone")
        let recorded = await runner.exit(of: pid)
        XCTAssertEqual(recorded, termination)
        let running = await runner.isRunning(serviceID: "svc")
        XCTAssertFalse(running)
    }

    func testAStopOfAProcessThatObeysSigtermIsFast() async throws {
        let runner = ProcessRunner()
        let box = Box()
        _ = try await start(runner, service("svc", ["sleep", "30"]), box)

        let began = Date()
        await runner.stop(serviceID: "svc")

        XCTAssertLessThan(Date().timeIntervalSince(began), 1.5, "no fixed two-second wait")
    }

    /// The ticket "Local Sequin Cache CDC exited with code 9": the process did not
    /// end on SIGTERM, the kill came two seconds later, and the old code read the
    /// late exit as a crash of the service.
    func testAProcessThatIgnoresSigtermIsKilledAndStillMarked() async throws {
        let runner = ProcessRunner()
        let box = Box()
        let pid = try await start(runner, service("svc", ["sh", "-c", "trap '' TERM; while true; do sleep 1; done"]), box)
        try await Task.sleep(for: .milliseconds(500))

        let began = Date()
        await runner.stop(serviceID: "svc")
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertGreaterThan(elapsed, 1.8, "SIGKILL comes after the grace time")
        XCTAssertLessThan(elapsed, 4.5)
        let termination = await waitForTermination(box)
        XCTAssertEqual(termination?.stoppedByRunner, true)
        XCTAssertFalse(isAlive(pid))
    }

    func testAFailureIsNotMarkedAsAStop() async throws {
        let runner = ProcessRunner()
        let box = Box()
        let pid = try await start(runner, service("svc", ["sh", "-c", "exit 3"]), box)

        let termination = await waitForTermination(box)
        XCTAssertEqual(termination, ProcessRunner.Termination(pid: pid, status: 3, bySignal: false, stoppedByRunner: false))
        XCTAssertEqual(termination.map(ServiceTermination.classify), .crashed(code: 3, bySignal: false))
    }

    func testAKillFromOutsideIsNotMarkedAsAStop() async throws {
        let runner = ProcessRunner()
        let box = Box()
        let pid = try await start(runner, service("svc", ["sleep", "30"]), box)
        try await Task.sleep(for: .milliseconds(300))

        kill(pid, SIGTERM)

        let termination = await waitForTermination(box)
        XCTAssertEqual(termination?.stoppedByRunner, false)
        XCTAssertEqual(termination.map(ServiceTermination.classify), .killedExternally(signal: SIGTERM))
    }

    func testACommandThatDoesNotExistReportsExit127() async throws {
        let runner = ProcessRunner()
        let box = Box()
        _ = try await start(runner, service("svc", ["./no-such-script-\(UUID().uuidString).sh"]), box)

        let termination = await waitForTermination(box)
        XCTAssertEqual(termination.map(ServiceTermination.classify), .commandNotRunnable(code: 127))
    }

    /// A tool that only `~/.zshrc` puts on PATH: the login shell does not see it.
    /// The tool environment adds the directory, so the service starts. The directory has a
    /// space, as `Application Support` has.
    func testAToolInAnInjectedDirectoryStarts() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool dir \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tool = "tr-fake-tool-\(UUID().uuidString)"
        let file = directory.appendingPathComponent(tool)
        try "#!/bin/sh\nexit 0\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        // An empty home: only the tool directories of the system count.
        let home = directory.appendingPathComponent("home").path

        // Without the directory the shell cannot find the tool.
        let bare = ToolEnvironment(home: home)
        let plain = ProcessRunner(tools: bare)
        let missing = Box()
        _ = try await start(plain, service("svc", [tool]), missing)
        let notFound = await waitForTermination(missing)
        XCTAssertEqual(notFound.map(ServiceTermination.classify), .commandNotRunnable(code: 127))

        // The PATH of the user's interactive shell has the directory.
        let resolved = ToolEnvironment(home: home, capture: .init(shellPath: [directory.path]))
        let runner = ProcessRunner(tools: resolved)
        let box = Box()
        _ = try await start(runner, service("svc", [tool]), box)
        let termination = await waitForTermination(box)
        XCTAssertEqual(termination.map(ServiceTermination.classify), .cleanExit)

        let searched = await ToolEnvironment.lookup(tool, cwd: nil, runner: LoginShell(tools: bare))
        guard case .missing(let path) = searched else { return XCTFail("the tool is not on the PATH of the shell: \(String(describing: searched))") }
        XCTAssertTrue(path.contains("/usr/bin"), path)
        let found = await ToolEnvironment.lookup(tool, cwd: nil, runner: LoginShell(tools: resolved))
        XCTAssertEqual(found, .found(file.path), "the shell finds the tool in the added directory")
    }

    /// A stop that started before a new launch must not drop the new launch.
    func testASecondStartEndsTheFirstProcessAndKeepsTheSecond() async throws {
        let runner = ProcessRunner()
        let first = Box()
        let second = Box()
        let firstPid = try await start(runner, service("svc", ["sleep", "30"]), first)
        let secondPid = try await start(runner, service("svc", ["sleep", "31"]), second)

        let ended = await waitForTermination(first)
        XCTAssertEqual(ended?.stoppedByRunner, true, "the runner ended it, so it is not a crash")
        XCTAssertFalse(isAlive(firstPid))
        XCTAssertTrue(isAlive(secondPid))
        let running = await runner.isRunning(serviceID: "svc")
        XCTAssertTrue(running)

        await runner.stop(serviceID: "svc")
        XCTAssertFalse(isAlive(secondPid))
    }

    func testStopAllMarksEveryProcess() async throws {
        let runner = ProcessRunner()
        let a = Box()
        let b = Box()
        _ = try await start(runner, service("a", ["sleep", "30"]), a)
        _ = try await start(runner, service("b", ["sleep", "30"]), b)

        await runner.stopAll()

        let endedA = await waitForTermination(a)
        let endedB = await waitForTermination(b)
        XCTAssertEqual(endedA?.stoppedByRunner, true)
        XCTAssertEqual(endedB?.stoppedByRunner, true)
    }

    /// The lines of one launch, as the runner gave them, and a copy of them made
    /// when the termination came.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stdout: [String] = []
        private var stderr: [String] = []
        private var atEnd: (stdout: [String], stderr: [String])?

        func add(_ lines: [String], stderr isStderr: Bool) {
            lock.lock()
            if isStderr { stderr += lines } else { stdout += lines }
            lock.unlock()
        }

        func ended() {
            lock.lock()
            atEnd = (stdout, stderr)
            lock.unlock()
        }

        var seenAtEnd: (stdout: [String], stderr: [String])? {
            lock.lock()
            defer { lock.unlock() }
            return atEnd
        }
    }

    /// Finding "Process output lost or reordered": the termination handler dropped
    /// what was still in the pipes, often the stack trace of a crash. Every line
    /// now comes in order, the last one without a newline too, before the termination.
    func testACrashKeepsEveryLineInOrder() async throws {
        let count = 400
        let script = """
            i=1; while [ $i -le \(count) ]; do echo "out-$i"; echo "err-$i" >&2; i=$((i+1)); done; \
            printf 'out-last'; printf 'err-last' >&2; exit 1
            """
        let expectedOut = (1...count).map { "out-\($0)" } + ["out-last"]
        let expectedErr = (1...count).map { "err-\($0)" } + ["err-last"]

        for _ in 0..<5 {
            let runner = ProcessRunner()
            let lines = Lines()
            let box = Box()
            _ = try await runner.start(
                service: service("svc", ["sh", "-c", script]),
                onStdout: { lines.add($0, stderr: false) },
                onStderr: { lines.add($0, stderr: true) },
                onTermination: { termination in
                    lines.ended()
                    box.set(termination)
                }
            )

            let termination = await waitForTermination(box)
            XCTAssertEqual(termination.map(ServiceTermination.classify), .crashed(code: 1, bySignal: false))
            let seen = try XCTUnwrap(lines.seenAtEnd)
            // A login shell profile can print lines of its own.
            XCTAssertEqual(seen.stdout.filter { $0.hasPrefix("out-") }, expectedOut)
            XCTAssertEqual(seen.stderr.filter { $0.hasPrefix("err-") }, expectedErr)
        }
    }

    /// The pipe can still hold data when the termination comes: here a child
    /// writes the last line after the root has ended. The old handler dropped it.
    func testALineWrittenAfterTheRootEndedIsKept() async throws {
        let runner = ProcessRunner()
        let lines = Lines()
        let box = Box()
        _ = try await runner.start(
            service: service("svc", ["sh", "-c", "echo out-1; (sleep 0.3; printf 'out-last') & exit 1"]),
            onStdout: { lines.add($0, stderr: false) },
            onStderr: { lines.add($0, stderr: true) },
            onTermination: { termination in
                lines.ended()
                box.set(termination)
            }
        )

        let termination = await waitForTermination(box)
        XCTAssertEqual(termination.map(ServiceTermination.classify), .crashed(code: 1, bySignal: false))
        let seen = try XCTUnwrap(lines.seenAtEnd)
        XCTAssertEqual(seen.stdout.filter { $0.hasPrefix("out-") }, ["out-1", "out-last"])
    }

    func testAStopWithNoProcessDoesNothing() async {
        let runner = ProcessRunner()
        let began = Date()
        await runner.stop(serviceID: "nothing")
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
    }
}
