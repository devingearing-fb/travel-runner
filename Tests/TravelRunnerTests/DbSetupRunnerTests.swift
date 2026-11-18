import Foundation
import XCTest
@testable import TravelRunner

/// The step runner of the DB setup: whole-tree stop, the cancelled state, ordered
/// output and the step limits. The steps run in `/bin/zsh -f`, which reads no
/// startup files, so no test depends on the shell of this Mac.
@MainActor
final class DbSetupRunnerTests: XCTestCase {
    private var cwd: URL!

    override func setUp() async throws {
        cwd = FileManager.default.temporaryDirectory.appendingPathComponent("DbSetupRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cwd)
    }

    private static let plainShell = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })

    private func runner(
        shell: FakeCommandRunner = FakeCommandRunner(), clock: RunnerClock = .awake,
        killGrace: Duration = ProcessTree.defaultGrace
    ) -> DbSetupRunner {
        DbSetupRunner(
            portalCwd: cwd.path, logStore: LogStore(), seedScenarioID: "standard", profile: "reset",
            tools: ToolEnvironment(home: cwd.appendingPathComponent("home").path), shell: shell,
            launcher: Self.plainShell, clock: clock, killGrace: killGrace
        )
    }

    private func makeStep(
        _ command: String, id: String = "load-hotels", healthCheck: String? = nil, timeoutSeconds: Int = 30
    ) -> DbSetupStep {
        DbSetupStep(
            id: id, name: "Load Hotels", command: command, healthCheckCommand: healthCheck,
            timeoutSeconds: timeoutSeconds, isOptional: false, stepNumber: 1
        )
    }

    /// A command that starts a child process, writes the child's pid to `child`,
    /// and waits for it. The child outlives a stop of the parent alone.
    private var parentWithChild: String { "sleep 60 & echo $! > child; wait" }

    private func childPid(timeout seconds: Double = 10) async throws -> pid_t {
        let file = cwd.appendingPathComponent("child").path
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: file, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        // A step that never starts is a failure, not a skip.
        return try XCTUnwrap(nil as pid_t?, "the step did not start its child in time")
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Ends a child that a failed test left, so no test leaves a process behind.
    /// Only a process in the test's folder: the pid may belong to another process by now.
    private func reap(_ pid: pid_t) {
        if isAlive(pid), SupervisorLifecycleTests.process(pid, runsIn: cwd.lastPathComponent) {
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Whole-tree stop and the cancelled state

    /// Finding "Timeout and Cancel kill only the wrapper": the child of the shell
    /// kept running. A cancel now ends the tree, waits for it, and is no fault.
    func testACancelStopsTheWholeTreeAndIsNotAFailure() async throws {
        let runner = runner()
        let step = makeStep(parentWithChild)
        let run = Task { await runner.executeStepPublic(step) }
        let child = try await childPid()
        defer { reap(child) }
        XCTAssertTrue(isAlive(child))
        let parent = try XCTUnwrap(runner.runningProcessID)

        await runner.cancel()

        // The cancel returns when the tree is gone.
        XCTAssertFalse(isAlive(child), "the child of the step still runs")
        XCTAssertFalse(isAlive(parent))
        let passed = await run.value
        XCTAssertFalse(passed)
        XCTAssertEqual(step.status, .cancelled)
        XCTAssertNil(step.errorMessage, "a cancel sets no error")
        XCTAssertNil(step.recoveryGuidance)
        XCTAssertNil(runner.runningProcessID)
        let wasCancelled = await runner.wasCancelled
        XCTAssertTrue(wasCancelled)
    }

    /// A cancel before the run starts still stops it: the runner serves one run.
    func testACancelBeforeTheRunStartsRunsNoStep() async throws {
        let marker = cwd.appendingPathComponent("ran").path
        let steps = [makeStep("touch \(ShellQuote.quote(marker))", id: "reset-database")]
        let scenario = DbSeedScenario(id: "test", name: "Test", description: "", fileSummary: "", variables: [])
        let pipeline = DbSetupPipeline(profile: "reset", seedScenario: scenario)
        pipeline.steps = steps
        let runner = runner()

        await runner.cancel()
        await runner.run(pipeline: pipeline)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
        XCTAssertEqual(steps.map(\.status), [.pending])
        XCTAssertFalse(pipeline.isRunning)

        // Control: a new runner runs the same pipeline.
        await self.runner().run(pipeline: pipeline)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        XCTAssertEqual(steps.map(\.status), [.passed])
    }

    /// A cancel in the middle of a pipeline leaves the later steps pending, shows
    /// no failed step, and says how to finish.
    func testACancelledPipelineHasNoFailedStep() async throws {
        let steps = [makeStep(parentWithChild, id: "start-supabase"), makeStep("true", id: "reset-database")]
        let scenario = DbSeedScenario(id: "test", name: "Test", description: "", fileSummary: "", variables: [])
        let pipeline = DbSetupPipeline(profile: "reset", seedScenario: scenario)
        pipeline.steps = steps
        let runner = runner()

        let run = Task { await runner.run(pipeline: pipeline) }
        let child = try await childPid()
        defer { reap(child) }
        await runner.cancel()
        await run.value

        XCTAssertEqual(steps.map(\.status), [.cancelled, .pending])
        XCTAssertNil(pipeline.firstFailed, "a cancel is not shown as a failure")
        XCTAssertEqual(pipeline.firstCancelled?.id, "start-supabase")
        XCTAssertFalse(pipeline.allRequiredPassed)
        XCTAssertEqual(DbSetupPipeline.cancelledMessage, "Cancelled. The database may be half-built — Run All to finish.")
    }

    /// A cancel during the health check ends the check and is not a failure.
    func testACancelEndsTheHealthCheck() async throws {
        let shell = FakeCommandRunner { _ in
            // Like `Shell.execute`: the command runs until its task is cancelled.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            return CommandResult(exitCode: -1, stdout: "", stderr: "Cancelled")
        }
        let runner = runner(shell: shell)
        let step = makeStep("true", healthCheck: "check")
        let run = Task { await runner.executeStepPublic(step) }
        let checking = await waitUntil(10) { step.status == .healthCheck && !shell.calls.isEmpty }
        XCTAssertTrue(checking)

        await runner.cancel()
        let passed = await run.value

        XCTAssertFalse(passed)
        XCTAssertEqual(step.status, .cancelled)
        XCTAssertNil(step.errorMessage)
    }

    // MARK: - Step limits

    /// A clock that does not move until the test opens the gate, then moves a
    /// second at each wait at no real cost.
    private func heldClock(_ gate: Gate) -> RunnerClock {
        let time = FakeClock()
        return RunnerClock(
            date: { time.now },
            uptime: { time.uptime },
            wait: { duration in
                await gate.wait()
                try await time.clock.wait(duration)
            }
        )
    }

    /// A step that prints nothing for 180 s is stopped, with its child, and the
    /// error names what it was doing and its last line.
    func testAStepWithNoOutputIsStoppedWithItsTree() async throws {
        let gate = Gate()
        let runner = runner(clock: heldClock(gate))
        let step = makeStep(
            "echo '##db:progress:0.50:Loading hotels'; echo 'loaded 1000 rows'; " + parentWithChild,
            timeoutSeconds: 5
        )
        let run = Task { await runner.executeStepPublic(step) }
        let child = try await childPid()
        defer { reap(child) }
        let printed = await waitUntil(10) { step.logEntries.map(\.text) == ["loaded 1000 rows"] }
        XCTAssertTrue(printed, "\(step.logEntries.map(\.text))")

        await gate.open()
        let passed = await run.value

        XCTAssertFalse(passed)
        XCTAssertEqual(step.status, .timedOut)
        XCTAssertEqual(step.errorMessage, "No output for 180 s while: Loading hotels. Last line: loaded 1000 rows.")
        XCTAssertNotNil(step.recoveryGuidance)
        XCTAssertFalse(isAlive(child), "the child of a timed-out step still runs")
    }

    /// The hard cap stops a step that runs too long. The manifest's 2 s is the cap
    /// of a step that has no larger one.
    func testAStepPastItsCapIsStopped() async throws {
        let gate = Gate()
        let runner = runner(clock: heldClock(gate))
        let step = makeStep(parentWithChild, id: "verify-data", timeoutSeconds: 2)
        let run = Task { await runner.executeStepPublic(step) }
        let child = try await childPid()
        defer { reap(child) }

        await gate.open()
        let passed = await run.value

        XCTAssertFalse(passed)
        XCTAssertEqual(step.status, .timedOut)
        XCTAssertEqual(step.errorMessage, "Timed out after 2 s")
        XCTAssertFalse(isAlive(child))
    }

    /// A child that ignores SIGTERM keeps the pipe open after the root has died.
    /// The tests give the stop a long wait before SIGKILL and end the child themselves.
    private var parentWithTermIgnoringChild: String { "(trap '' TERM; exec sleep 60) & echo $! > child; wait" }
    private static let longKillGrace: Duration = .seconds(30)

    /// Waits until the root of the step is gone, then past the pipe grace.
    private func waitPastTheRootAndTheGrace(_ root: pid_t) async throws {
        let rootGone = await waitUntil(5) { !self.isAlive(root) }
        XCTAssertTrue(rootGone, "the root of the step did not end on SIGTERM")
        try await Task.sleep(for: .milliseconds(1_400))
    }

    /// The step ends only when its stop has ended the whole tree, so the DB
    /// controls do not unlock while a child of the step still runs.
    func testACancelEndsTheStepOnlyWhenAChildThatHandlesSigtermIsGone() async throws {
        let runner = runner(killGrace: Self.longKillGrace)
        let step = makeStep(parentWithTermIgnoringChild)
        let run = Task { await runner.executeStepPublic(step) }
        let child = try await childPid()
        defer { reap(child) }
        let root = try XCTUnwrap(runner.runningProcessID)

        let cancel = Task { await runner.cancel() }
        try await waitPastTheRootAndTheGrace(root)

        // Negative control: the child is alive, so the stop is still on.
        XCTAssertTrue(isAlive(child), "the child did not outlive SIGTERM")
        XCTAssertEqual(step.status, .running, "the step ended before its tree")

        reap(child)
        await cancel.value
        XCTAssertFalse(isAlive(child))
        let passed = await run.value
        XCTAssertFalse(passed)
        XCTAssertEqual(step.status, .cancelled)
        XCTAssertNil(runner.runningProcessID)
    }

    /// The same for a stop that the watchdog starts.
    func testATimedOutStepEndsOnlyWhenAChildThatHandlesSigtermIsGone() async throws {
        let gate = Gate()
        let runner = runner(clock: heldClock(gate), killGrace: Self.longKillGrace)
        let step = makeStep(parentWithTermIgnoringChild, id: "verify-data", timeoutSeconds: 2)
        let run = Task { await runner.executeStepPublic(step) }
        let child = try await childPid()
        defer { reap(child) }
        let root = try XCTUnwrap(runner.runningProcessID)

        await gate.open()
        try await waitPastTheRootAndTheGrace(root)

        XCTAssertTrue(isAlive(child), "the child did not outlive SIGTERM")
        XCTAssertEqual(step.status, .running, "the step ended before its tree")

        reap(child)
        let passed = await run.value
        XCTAssertFalse(passed)
        XCTAssertEqual(step.status, .timedOut)
        XCTAssertFalse(isAlive(child))
    }

    func testTheLimitThatPassedFirstStopsTheStep() {
        func check(now: Int, lastOutput: Int, idle: Int = 180, cap: Int = 900) -> StepTimeout? {
            StepTimeout.check(
                now: .seconds(now), startedAt: .zero, lastOutputAt: .seconds(lastOutput),
                idleSeconds: idle, capSeconds: cap
            )
        }
        XCTAssertNil(check(now: 179, lastOutput: 0))
        XCTAssertEqual(check(now: 180, lastOutput: 0), .idle(seconds: 180))
        // Output resets the idle limit.
        XCTAssertNil(check(now: 300, lastOutput: 200))
        // A step that keeps printing still meets its cap.
        XCTAssertNil(check(now: 899, lastOutput: 899))
        XCTAssertEqual(check(now: 900, lastOutput: 899), .cap(seconds: 900))
    }

    /// Fixed timeouts did not fit a cold machine. The slow steps get the plan's
    /// hard caps, and a larger manifest value still wins.
    func testTheSlowStepsHaveHardCaps() {
        func cap(_ id: String, _ manifestSeconds: Int) -> Int {
            DbSetupStep(
                id: id, name: id, command: "", healthCheckCommand: nil,
                timeoutSeconds: manifestSeconds, isOptional: false, stepNumber: 1
            ).hardCapSeconds
        }
        XCTAssertEqual(cap("start-supabase", 300), 900)
        XCTAssertEqual(cap("reset-database", 180), 900)
        XCTAssertEqual(cap("load-hotels", 600), 2700, "a load may download the dump again first")
        XCTAssertEqual(cap("fetch-hotels", 1200), 1800)
        XCTAssertEqual(cap("verify-data", 30), 30, "a step with no hard cap keeps the manifest's limit")
        XCTAssertEqual(cap("load-hotels", 3600), 3600)    }

    func testTheManifestGivesTheIdleLimit() throws {
        let manifest = cwd.appendingPathComponent("manifest.json")
        try Data(#"""
        {"version": 4, "idleTimeoutMs": 240000,
         "profiles": {"reset": ["a", "b", "c"]},
         "steps": [
           {"id": "a", "name": "A", "command": "true", "timeoutMs": 1000},
           {"id": "b", "name": "B", "command": "true", "timeoutMs": 1000, "idleTimeoutMs": 60000},
           {"id": "c", "name": "C", "command": "true", "timeoutMs": 1000}
         ]}
        """#.utf8).write(to: manifest)
        let steps = try DbManifestLoader.load(from: manifest.path, profile: "reset")
        XCTAssertEqual(steps.map(\.idleTimeoutSeconds), [240, 60, 240])

        // Without the key the default is 180 s.
        try Data(#"""
        {"version": 4, "profiles": {"reset": ["a"]},
         "steps": [{"id": "a", "name": "A", "command": "true", "timeoutMs": 1000}]}
        """#.utf8).write(to: manifest)
        XCTAssertEqual(try DbManifestLoader.load(from: manifest.path, profile: "reset").map(\.idleTimeoutSeconds), [180])
    }

    // MARK: - Ordered output

    /// Finding "the final ##db:status:failed line can be lost": the error is read
    /// only after every line of the step is in.
    func testTheLastLinesAreNeverLost() async throws {
        let step = makeStep(
            "for i in $(seq 1 400); do echo line $i; done; echo '##db:status:failed:Hotel dump is missing'; printf 'no newline'; exit 1"
        )
        let passed = await runner().executeStepPublic(step)

        XCTAssertFalse(passed)
        XCTAssertEqual(step.status, .failed)
        XCTAssertEqual(step.errorMessage, "Hotel dump is missing")
        let expected = (1...400).map { "line \($0)" } + ["no newline"]
        XCTAssertEqual(step.logEntries.map(\.text), expected, "the lines are all there, in order")
    }

    /// Without the status line the error falls back to the last line, which is
    /// there because the output is read to its end first.
    func testTheFallbackErrorReadsTheLastLine() async throws {
        let step = makeStep("echo first; echo 'the real cause'; exit 3")
        _ = await runner().executeStepPublic(step)
        XCTAssertEqual(step.errorMessage, "Exit code 3: the real cause")
    }

    /// The health check's output was thrown away. Its lines now go to the log of
    /// the step, and its `##db:` lines to the step.
    func testTheHealthCheckOutputIsKept() async throws {
        let shell = FakeCommandRunner { _ in
            FakeCommandRunner.ok("##db:health:pass:209823 hotels\nhotel table checked\n")
        }
        let runner = runner(shell: shell)
        let step = makeStep("echo loaded", healthCheck: "node scripts/db/load-hotels.mjs --verify")

        let passed = await runner.executeStepPublic(step)

        XCTAssertTrue(passed)
        XCTAssertEqual(step.healthResult, "209823 hotels")
        XCTAssertEqual(step.logEntries.map(\.text), ["loaded", "hotel table checked"])
        XCTAssertEqual(shell.calls.first?.timeout, .seconds(30))
    }

    // MARK: - UTF-8 chunks

    /// Finding "split multi-byte chunks are dropped": a pipe can cut a character.
    func testACharacterCutBetweenChunksStaysWhole() {
        let text = "Hotels ✓ 🏨 café"
        let bytes = Data(text.utf8)
        for cut in 0...bytes.count {
            let decoder = UTF8ChunkDecoder()
            let joined = decoder.decode(bytes.prefix(cut)) + decoder.decode(bytes.dropFirst(cut)) + decoder.flush()
            XCTAssertEqual(joined, text, "cut at byte \(cut)")
        }
    }

    func testABadByteDoesNotDropTheChunk() {
        let decoder = UTF8ChunkDecoder()
        var bytes = Data("before ".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Data(" after\n".utf8))
        XCTAssertEqual(decoder.decode(bytes), "before \u{FFFD} after\n")
        // Control: the old decode dropped the whole chunk.
        XCTAssertNil(String(data: bytes, encoding: .utf8))
    }

    func testAnUnfinishedCharacterAtTheEndIsFlushed() {
        let decoder = UTF8ChunkDecoder()
        let emoji = Data("🏨".utf8)
        XCTAssertEqual(decoder.decode(emoji.prefix(2)), "")
        XCTAssertEqual(decoder.flush(), "\u{FFFD}")
        XCTAssertEqual(decoder.flush(), "", "the flush empties the decoder")
    }

    // MARK: - Helpers

    private func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}
