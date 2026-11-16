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
    /// The runner adds the directory, so the service starts. The directory has a
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

        // Without the directory the shell cannot find the tool.
        let plain = ProcessRunner(toolDirectories: { _ in [] })
        let missing = Box()
        _ = try await start(plain, service("svc", [tool]), missing)
        let notFound = await waitForTermination(missing)
        XCTAssertEqual(notFound.map(ServiceTermination.classify), .commandNotRunnable(code: 127))

        let path = directory.path
        let runner = ProcessRunner(toolDirectories: { _ in [path] })
        let box = Box()
        _ = try await start(runner, service("svc", [tool]), box)
        let termination = await waitForTermination(box)
        XCTAssertEqual(termination.map(ServiceTermination.classify), .cleanExit)

        let searched = await ToolPath.searchedPath(missing: tool, directories: [])
        XCTAssertNotNil(searched, "the tool is not on the PATH of the shell")
        let found = await ToolPath.searchedPath(missing: tool, directories: [path])
        XCTAssertNil(found, "the shell finds the tool in the added directory")
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

    func testAStopWithNoProcessDoesNothing() async {
        let runner = ProcessRunner()
        let began = Date()
        await runner.stop(serviceID: "nothing")
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5)
    }
}
