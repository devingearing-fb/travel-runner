import Foundation
import XCTest
@testable import TravelRunner

/// The supervisor with small real processes. Each test is one of the failures that
/// the runner's debug issues recorded.
@MainActor
final class SupervisorLifecycleTests: XCTestCase {
    private var supervisor: EnvironmentSupervisor!
    private var port = 0
    private var workDir: URL!
    private var crashes: [(name: String, code: Int32)] = []

    override func setUp() async throws {
        port = Self.freePort()
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("SupervisorLifecycleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        crashes = []
        try makeSupervisor(tools: .shared)
    }

    /// The supervisor of a test. The shared tool environment is never resolved in
    /// a test, so no test reads the shell of this Mac.
    private func makeSupervisor(tools: ToolEnvironment) throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SupervisorLifecycleTests-\(UUID().uuidString)"))
        // The log files of a test go to its own folder.
        supervisor = EnvironmentSupervisor(
            userDefaults: defaults, tools: tools,
            logSink: LogFileSink(directory: workDir.appendingPathComponent("logs"), version: "9.9.9")
        )
        // The port cleanup of a test kills only a process that the test started. A
        // stranger can take the free port after `freePort` lets it go.
        let ownedDirectory = workDir.lastPathComponent
        supervisor.portTools = PortTools(
            listeners: PortTools.live.listeners,
            kill: { pid in if Self.process(pid, runsIn: ownedDirectory) { PortTools.live.kill(pid) } },
            killCommands: { _ in }
        )
        supervisor.onServiceCrash = { [weak self] name, code in
            self?.crashes.append((name, code))
        }
    }

    /// Gives the supervisor a shell that holds each "where is the tool" question
    /// until the test opens the gate. The answer: not on the PATH `/fake/bin`.
    private func heldPathQuestion() -> HeldPathQuestion {
        let gate = Gate()
        let shell = FakeCommandRunner { call in
            guard call.command.contains("command -v") else { return FakeCommandRunner.ok() }
            await gate.wait()
            return CommandResult(exitCode: 3, stdout: "/fake/bin\n", stderr: "")
        }
        supervisor.shell = shell
        return HeldPathQuestion(shell: shell, gate: gate)
    }

    override func tearDown() async throws {
        supervisor.stopAll()
        _ = await waitUntil(10) { self.supervisor.health == .stopped }
        for pid in Self.listeners(on: port) where Self.process(pid, runsIn: workDir.lastPathComponent) {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Helpers

    private static func freePort() -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        addr.sin_port = 0
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// True when the working directory of the process is the test's own folder. Each
    /// service of a test starts there, and the folder has a new name for each test.
    private nonisolated static func process(_ pid: pid_t, runsIn directory: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return text.split(separator: "\n").contains { $0.hasPrefix("n") && $0.hasSuffix("/" + directory) }
    }

    private static func listeners(on port: Int) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-ti", "TCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.split(separator: "\n").compactMap { pid_t($0) }
    }

    private func daemon(_ id: String, _ cmd: [String], probeTimeout: Int = 30, reuse: Bool? = nil) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: id, cmd: cmd, cwd: workDir.path,
            probe: ProbeConfig(type: .tcp, port: port, host: nil, url: nil, pattern: nil, artifact: nil, timeout: probeTimeout),
            type: .daemon, restart: .onFailure, dependsOn: [], env: nil, phase: nil, reuseIfRunning: reuse
        )
    }

    /// A second daemon that counts as running, so the environment never looks
    /// stopped while the service under test restarts.
    private func load(_ service: ServiceDefinition) throws {
        let anchor = ServiceDefinition(
            id: "anchor", name: nil, cmd: ["sleep", "1"], cwd: nil, probe: nil, type: .daemon, restart: .never,
            dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        try supervisor.loadServices([service, anchor])
        supervisor.serviceStates["anchor"]?.phase = .running
        supervisor.health = .healthy
    }

    private var webServer: [String] {
        ["python3", "-u", "-m", "http.server", "\(port)", "--bind", "127.0.0.1"]
    }

    private func state(_ id: String) -> ServiceState {
        supervisor.serviceStates[id]!
    }

    /// Turns issue capture on, in a folder of the test. No config: that means on.
    private func captureIssues() -> DebugTracker {
        let tracker = DebugTracker(baseDir: workDir.appendingPathComponent("issues").path)
        supervisor.debugTracker = tracker
        return tracker
    }

    /// The events of one kind in `events.jsonl`. It waits for the first one, then
    /// a moment more, so a second one that should not be there is seen.
    private func events(_ kind: String, in tracker: DebugTracker) async -> [DebugTracker.Event] {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let found = await tracker.listEvents().filter { $0.kind == kind }
            if !found.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
                return await tracker.listEvents().filter { $0.kind == kind }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return []
    }

    private func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func logLines(_ id: String) async -> [String] {
        await supervisor.logStore.entries(for: id).map(\.text)
    }

    private func settled(_ id: String) -> Bool {
        state(id).phase == .running && supervisor.actionsInFlight.isEmpty
    }

    private func logFile(_ id: String) -> [String] {
        let url = workDir.appendingPathComponent("logs/\(id).log")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    // MARK: - Tests

    func testEachStartWritesASeparatorAndTheOutputToTheLogFile() async throws {
        try load(daemon("web", ["sh", "-c", "echo hello from web; exec \(webServer.joined(separator: " "))"]))

        supervisor.restartService("web")
        let started = await waitUntil(20) { self.settled("web") }
        XCTAssertTrue(started)
        let firstPid = try XCTUnwrap(state("web").pid)
        let wrote = await waitUntil(5) { self.logFile("web").contains { $0.hasSuffix("[out] hello from web") } }
        XCTAssertTrue(wrote, logFile("web").joined(separator: "\n"))

        supervisor.restartService("web")
        let restarted = await waitUntil(20) { self.settled("web") && self.state("web").pid != firstPid }
        XCTAssertTrue(restarted)
        let secondPid = try XCTUnwrap(state("web").pid)
        let both = await waitUntil(5) { self.logFile("web").filter { $0.contains("── started web pid ") }.count == 2 }
        XCTAssertTrue(both, logFile("web").joined(separator: "\n"))

        let separators = logFile("web").filter { $0.contains("[travel-runner] ── started") }
        XCTAssertTrue(separators[0].hasSuffix("[out] [travel-runner] ── started web pid \(firstPid) (runner v9.9.9) ──"), separators[0])
        XCTAssertTrue(separators[1].hasSuffix("[out] [travel-runner] ── started web pid \(secondPid) (runner v9.9.9) ──"), separators[1])
        // The file has the time on each line. The view does not show the separator.
        XCTAssertTrue(logFile("web").allSatisfy { $0.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{4} \[(out|err)\] "#, options: .regularExpression) != nil })
        let view = await logLines("web")
        XCTAssertFalse(view.contains { $0.contains("── started") })
    }

    /// Tickets "Travel Portal exited with code 1" with EADDRINUSE in the log: two
    /// requests for one service each started a process.
    func testRequestsAtTheSameTimeStartOneProcess() async throws {
        try load(daemon("web", webServer))

        supervisor.restartService("web")
        supervisor.clearCacheAndRestart("web")
        supervisor.restartService("web")
        supervisor.clearCacheAndRestart("web")

        let ready = await waitUntil(40) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        // A second process would fail on the port a moment later.
        try await Task.sleep(for: .seconds(3))

        let lines = await logLines("web")
        XCTAssertFalse(lines.contains { $0.contains("Address already in use") }, lines.joined(separator: "\n"))
        XCTAssertEqual(Self.listeners(on: port).count, 1)
        XCTAssertEqual(state("web").phase, .running)
        XCTAssertTrue(crashes.isEmpty, "\(crashes)")
        XCTAssertTrue(state("web").failureTimestamps.isEmpty)
    }

    /// "Exit code 127: command not found": the tool was installed, or added to
    /// `~/.zshrc`, after the launch of the app. Exit 127 reads the shell again, so
    /// the next start finds the tool. No relaunch of the app.
    func testAfterExit127TheShellIsReadAgainAndTheRestartFindsTheTool() async throws {
        // A tool that no Mac has, in a folder that only the "rc file" puts on PATH.
        let toolDirectory = workDir.appendingPathComponent("rc tools")
        try FileManager.default.createDirectory(at: toolDirectory, withIntermediateDirectories: true)
        let tool = "tr-fake-server-\(UUID().uuidString)"
        let file = toolDirectory.appendingPathComponent(tool)
        try "#!/bin/sh\nexec python3 -u -m http.server \"$1\" --bind 127.0.0.1\n"
            .write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)

        // At launch the shell of the user does not have the folder.
        let userShell = FakeCommandRunner { _ in
            FakeCommandRunner.ok("__TR_ENV_START__\nPATH=/usr/bin:/bin\n__TR_ENV_END__\n")
        }
        let tools = ToolEnvironment(home: workDir.appendingPathComponent("home").path)
        await tools.resolve(runner: userShell)
        try makeSupervisor(tools: tools)
        try load(daemon("web", [tool, "\(port)"]))

        // Later the user adds the folder to the rc file. The app does not know yet.
        let path = toolDirectory.path
        userShell.respond { _ in
            FakeCommandRunner.ok("__TR_ENV_START__\nPATH=\(path):/usr/bin:/bin\n__TR_ENV_END__\n")
        }

        supervisor.restartService("web")
        let failed = await waitUntil(20) { self.state("web").phase == .failed }
        XCTAssertTrue(failed, "with the PATH of the launch the start ends with exit 127: \(state("web").phase.rawValue)")
        XCTAssertEqual(state("web").exitCode, 127)

        // Exit 127 asks the shell again.
        let askedAgain = await waitUntil(20) { userShell.calls.count == 2 }
        XCTAssertTrue(askedAgain, "\(userShell.calls.count) reads of the shell")
        await tools.settled()
        XCTAssertEqual(tools.capture.shellPath.first, path)

        // The user reads that the tool is found now, not a question about the branch.
        let found = "web could not find \(tool) when it started. \(Flavor.current.displayName) read your shell again "
            + "and found it at \(path)/\(tool). Restart web."
        let said = await waitUntil(20) { self.supervisor.lastError == found && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(said, supervisor.lastError ?? "no error")
        let lines = await logLines("web")
        XCTAssertEqual(lines.filter { $0 == "[travel-runner] \(found)" }.count, 1, lines.joined(separator: "\n"))
        XCTAssertEqual(userShell.calls.count, 2, "one new read for one exit 127")

        supervisor.restartService("web")
        let ready = await waitUntil(40) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
    }

    /// Stop All while the shell is read: the start waited for the read inside the
    /// process runner, the stop saw no process, and the start then ran one. The
    /// port was taken while the app said "stopped".
    func testAStopAllDuringAReadOfTheShellStartsNoProcess() async throws {
        let gate = Gate()
        let userShell = FakeCommandRunner { _ in
            await gate.wait()
            return FakeCommandRunner.ok("__TR_ENV_START__\nPATH=/usr/bin:/bin\n__TR_ENV_END__\n")
        }
        let tools = ToolEnvironment(home: workDir.appendingPathComponent("home").path)
        try makeSupervisor(tools: tools)
        try load(daemon("web", webServer))

        tools.beginResolve(runner: userShell)
        supervisor.restartService("web")
        // A restart pauses for one second before the start. After that the start
        // waits for the read.
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(Self.listeners(on: port), [], "the start did not wait for the read of the shell")

        supervisor.stopAll()
        let stopped = await waitUntil(10) { self.supervisor.health == .stopped }
        XCTAssertTrue(stopped)

        await gate.open()
        await tools.settled()
        // A start that still runs would open the port within this time.
        try await Task.sleep(for: .seconds(3))

        XCTAssertEqual(Self.listeners(on: port), [], "a process started after Stop All")
        XCTAssertEqual(state("web").phase, .stopped)
        XCTAssertTrue(supervisor.actionsInFlight.isEmpty)
    }

    /// Control for the test above: without a stop, the start runs when the read ends.
    func testAStartThatWaitedForAReadOfTheShellRunsAfterIt() async throws {
        let gate = Gate()
        let userShell = FakeCommandRunner { _ in
            await gate.wait()
            return FakeCommandRunner.ok("__TR_ENV_START__\nPATH=/usr/bin:/bin\n__TR_ENV_END__\n")
        }
        let tools = ToolEnvironment(home: workDir.appendingPathComponent("home").path)
        try makeSupervisor(tools: tools)
        try load(daemon("web", webServer))

        tools.beginResolve(runner: userShell)
        supervisor.restartService("web")
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(Self.listeners(on: port), [], "the start did not wait for the read of the shell")

        await gate.open()
        let ready = await waitUntil(40) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
    }

    /// Tickets with 32 and 41 recurrences: each automatic restart cleared the failure
    /// history, so the circuit breaker never saw three failures.
    func testACrashLoopStopsAtTheThirdFailure() async throws {
        let tracker = captureIssues()
        try load(daemon("boom", ["sh", "-c", "echo boom-start; exit 1"], probeTimeout: 60))

        supervisor.restartService("boom")

        let tripped = await waitUntil(40) { self.state("boom").isCircuitBroken }
        XCTAssertTrue(tripped, "the circuit breaker did not trip")
        let startsAtTrip = await logLines("boom").filter { $0 == "boom-start" }.count
        XCTAssertEqual(startsAtTrip, 3)

        // It stays stopped.
        try await Task.sleep(for: .seconds(8))
        let startsLater = await logLines("boom").filter { $0 == "boom-start" }.count
        XCTAssertEqual(startsLater, 3)
        XCTAssertEqual(state("boom").phase, .failed)
        XCTAssertEqual(supervisor.health, .degraded)
        XCTAssertEqual(state("boom").restartCount, 2)

        // The trip is in the event log, once.
        let trips = await events("breaker_trip", in: tracker)
        XCTAssertEqual(trips.map(\.serviceId), ["boom"])
        XCTAssertEqual(trips.first?.message, "boom is crash-looping — auto-restart stopped")
    }

    /// A tripped breaker must not outlive a deliberate restart: the next failure of
    /// the service gets its automatic restart again.
    func testADeliberateRestartClearsATrippedBreaker() async throws {
        let marker = workDir.appendingPathComponent("healthy").path
        let script = "if [ -f '\(marker)' ]; then exec python3 -u -m http.server \(port) --bind 127.0.0.1; else exit 1; fi"
        try load(daemon("flaky", ["sh", "-c", script], probeTimeout: 60))
        supervisor.restartService("flaky")
        let tripped = await waitUntil(40) { self.state("flaky").isCircuitBroken && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(tripped)

        // The cause is fixed, and a deliberate restart brings the service back.
        FileManager.default.createFile(atPath: marker, contents: nil)
        supervisor.clearCacheAndRestart("flaky")
        let ready = await waitUntil(30) { self.settled("flaky") }
        XCTAssertTrue(ready, "flaky is \(state("flaky").phase.rawValue)")
        XCTAssertFalse(state("flaky").isCircuitBroken)
        let before = try XCTUnwrap(Self.listeners(on: port).first)

        kill(before, SIGTERM)

        let back = await waitUntil(30) {
            self.settled("flaky") && Self.listeners(on: self.port).first.map { $0 != before } == true
        }
        XCTAssertTrue(back, "no automatic restart: flaky is \(state("flaky").phase.rawValue)")
    }

    /// Tickets "exited with code 143": something outside the runner stopped the
    /// process. The runner brings it back, and it is not a crash.
    func testAKillFromOutsideIsRestartedWithoutACrashReport() async throws {
        let tracker = captureIssues()
        try load(daemon("web", webServer))
        supervisor.restartService("web")
        let ready = await waitUntil(30) { self.settled("web") }
        XCTAssertTrue(ready)
        let before = try XCTUnwrap(Self.listeners(on: port).first)

        kill(before, SIGTERM)

        let back = await waitUntil(30) {
            self.settled("web") && Self.listeners(on: self.port).first.map { $0 != before } == true
        }
        XCTAssertTrue(back, "web is \(state("web").phase.rawValue)")
        XCTAssertTrue(crashes.isEmpty, "\(crashes)")
        XCTAssertEqual(state("web").restartCount, 1)
        let lines = await logLines("web")
        XCTAssertTrue(lines.contains { $0.contains("was stopped from outside Travel Runner (SIGTERM)") })

        // No issue, but the event log has the kill.
        let kills = await events("outside_kill", in: tracker)
        XCTAssertEqual(
            kills.map(\.message), ["web was stopped from outside Travel Runner (SIGTERM) — restarting it"]
        )
        let open = await tracker.openIssueCount()
        XCTAssertEqual(open, 0)
    }

    /// Ticket "Local Sequin Cache CDC exited with code 9": the old process ended two
    /// seconds after the stop, when the restart was on its way, and counted as a crash.
    func testAProcessThatDiesLateDoesNotFailTheRestart() async throws {
        let script = "trap '' TERM; exec python3 -u -m http.server \(port) --bind 127.0.0.1"
        try load(daemon("stubborn", ["sh", "-c", script]))
        supervisor.restartService("stubborn")
        let ready = await waitUntil(30) { self.settled("stubborn") }
        XCTAssertTrue(ready)

        supervisor.restartService("stubborn")
        _ = await waitUntil(5) { self.state("stubborn").phase != .running }
        let back = await waitUntil(40) { self.settled("stubborn") }
        XCTAssertTrue(back, "stubborn is \(state("stubborn").phase.rawValue)")
        try await Task.sleep(for: .seconds(2))

        XCTAssertEqual(state("stubborn").phase, .running)
        XCTAssertTrue(crashes.isEmpty, "\(crashes)")
        XCTAssertTrue(state("stubborn").failureTimestamps.isEmpty)
        XCTAssertEqual(Self.listeners(on: port).count, 1)
    }

    /// Ticket "exited with code 127" (six recurrences): the branch did not have the
    /// script. The same command cannot work on the next try.
    func testACommandThatDoesNotExistIsNotRestarted() async throws {
        try load(daemon("ghost", ["./no-such-script.sh"]))

        supervisor.restartService("ghost")

        let failed = await waitUntil(20) { self.state("ghost").phase == .failed && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(failed)
        try await Task.sleep(for: .seconds(6))

        let attempts = await logLines("ghost").filter { $0.contains("no-such-script.sh") }.count
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(state("ghost").restartCount, 0)
        XCTAssertEqual(state("ghost").phase, .failed)
        XCTAssertTrue(supervisor.lastError?.contains("cannot start") == true, supervisor.lastError ?? "nil")
    }

    /// Exit 127 for a tool, not a script: the error names the tool and the PATH
    /// that the runner searched.
    func testAMissingToolNamesThePathThatWasSearched() async throws {
        let tool = "tr-no-such-tool-\(UUID().uuidString)"
        try load(daemon("toolless", [tool, "dev"]))

        supervisor.restartService("toolless")

        let expected = "toolless cannot start: \(tool) was not found. \(Flavor.current.displayName) looked in: "
        let named = await waitUntil(30) {
            self.state("toolless").phase == .failed && self.supervisor.lastError?.hasPrefix(expected) == true
        }
        XCTAssertTrue(named, supervisor.lastError ?? "nil")
        XCTAssertTrue(supervisor.lastError?.contains("/usr/bin") == true, supervisor.lastError ?? "nil")
        XCTAssertTrue(
            supervisor.lastError?.hasSuffix("Install \(tool) or add its folder to ~/.zprofile, then restart the service.") == true,
            supervisor.lastError ?? "nil"
        )
        XCTAssertEqual(state("toolless").restartCount, 0)
    }

    /// The PATH question takes time. A stop that arrives while it runs keeps the
    /// service stopped, and the answer does not bring the error back.
    func testAStopDuringThePathQuestionLeavesTheServiceStopped() async throws {
        let tool = "tr-no-such-tool-\(UUID().uuidString)"
        let question = heldPathQuestion()
        try load(daemon("toolless", [tool, "dev"]))

        supervisor.restartService("toolless")
        let asked = await waitUntil(30) { self.state("toolless").phase == .failed && question.calls == 1 }
        XCTAssertTrue(asked, "\(question.calls) questions")
        // Longer than one round of the probe, so the wait for the probe asks too.
        try await Task.sleep(for: .seconds(3))

        supervisor.stopAll()
        let stopped = await waitUntil(10) { self.supervisor.health == .stopped }
        XCTAssertTrue(stopped)
        await question.gate.open()
        let done = await waitUntil(10) { self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(done)
        // Time for the answer to reach the end of the process.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(state("toolless").phase, .stopped)
        XCTAssertNil(supervisor.lastError)
        XCTAssertEqual(question.calls, 2, "one question: the PATH of the launch, then the PATH of the new read")
    }

    /// The control of the test above: with no stop, the answer gives the error. The
    /// wait for the probe and the end of the process ask one question for the process.
    func testThePathQuestionIsAskedOncePerProcess() async throws {
        let tool = "tr-no-such-tool-\(UUID().uuidString)"
        let question = heldPathQuestion()
        try load(daemon("toolless", [tool, "dev"]))

        supervisor.restartService("toolless")
        let asked = await waitUntil(30) { self.state("toolless").phase == .failed && question.calls == 1 }
        XCTAssertTrue(asked, "\(question.calls) questions")
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(supervisor.actionsInFlight.isEmpty, "the wait for the probe has not ended")

        await question.gate.open()
        let done = await waitUntil(10) { self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(done)

        XCTAssertEqual(state("toolless").phase, .failed)
        XCTAssertEqual(
            supervisor.lastError,
            "toolless cannot start: \(ToolEnvironment.notFoundText(tool: tool, searchedPath: "/fake/bin"))"
        )
        XCTAssertEqual(question.calls, 2, "one question: the PATH of the launch, then the PATH of the new read")
    }

    /// A stop-all while a service starts: the start's wait for the probe must not
    /// mark the service as failed after the stop.
    func testStopAllDuringAStartLeavesTheServiceStopped() async throws {
        try load(daemon("slow", ["sleep", "60"], probeTimeout: 4))
        supervisor.restartService("slow")
        let starting = await waitUntil(15) { self.state("slow").phase == .starting && self.state("slow").pid != nil }
        XCTAssertTrue(starting)

        supervisor.stopAll()
        // Longer than the probe timeout.
        try await Task.sleep(for: .seconds(8))

        XCTAssertEqual(state("slow").phase, .stopped)
        XCTAssertEqual(supervisor.health, .stopped)
        XCTAssertTrue(crashes.isEmpty, "\(crashes)")
    }

    /// Finding "startup timeouts create no ticket": a service that never passes its
    /// probe gets an issue that says whether the process still runs.
    func testAStartupProbeTimeoutIsCaptured() async throws {
        let issues = workDir.appendingPathComponent("issues")
        try FileManager.default.createDirectory(at: issues, withIntermediateDirectories: true)
        try #"{"enabled": true}"#.write(to: issues.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        supervisor.debugTracker = DebugTracker(baseDir: issues.path)
        try load(daemon("slow", ["sh", "-c", "echo slow-start; sleep 60"], probeTimeout: 3))

        supervisor.restartService("slow")
        let failed = await waitUntil(20) { self.state("slow").phase == .failed }
        XCTAssertTrue(failed, "slow is \(state("slow").phase.rawValue)")
        let captured = await waitUntil(5) { self.supervisor.debugOpenIssueCount == 1 }
        XCTAssertTrue(captured)

        let found = await supervisor.listDebugIssues()
        let issue = try XCTUnwrap(found.first)
        XCTAssertEqual(issue.trigger, "probe_timeout")
        XCTAssertEqual(issue.serviceId, "slow")
        XCTAssertEqual(issue.errorMessage, "slow did not pass its startup probe in 3s (process alive: yes)")
        let log = try String(contentsOf: issues.appendingPathComponent("open/\(issue.id)/logs-slow.txt"), encoding: .utf8)
        XCTAssertTrue(log.contains("slow-start"), log)

        // F4: the row says why, with the last check of the probe.
        XCTAssertEqual(state("slow").lastProbe, .refused)
        let said = await waitUntil(5) { self.state("slow").condition != nil }
        XCTAssertTrue(said)
        XCTAssertEqual(state("slow").condition?.headline, "slow did not answer on port \(port) within 3s.")
        XCTAssertEqual(
            state("slow").condition?.detail,
            "The process is still running — it may still be compiling. Last check: connection refused."
        )
        XCTAssertEqual(supervisor.lastError, "slow did not pass its health probe in 3s (last check: connection refused)")
    }

    /// A daemon that crashes once while it starts and then hangs has two waiters: the
    /// one of the first launch and the one of the automatic restart. They file one
    /// issue, and it describes the process that runs now.
    func testACrashThenAHangFilesOneProbeTimeoutThatSaysAlive() async throws {
        let issues = workDir.appendingPathComponent("issues")
        try FileManager.default.createDirectory(at: issues, withIntermediateDirectories: true)
        try #"{"enabled": true}"#.write(to: issues.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        // No rate limit: the two waiters end a few seconds apart, and this test counts both.
        supervisor.debugTracker = DebugTracker(baseDir: issues.path, rateLimitSeconds: 0)
        let script = "if [ -f ran-once ]; then sleep 60; else touch ran-once; exit 1; fi"
        try load(daemon("flaky", ["sh", "-c", script], probeTimeout: 10))

        supervisor.restartService("flaky")
        let restarted = await waitUntil(20) { self.state("flaky").restartCount == 1 && self.state("flaky").pid != nil }
        XCTAssertTrue(restarted, "restart count \(state("flaky").restartCount)")
        // Both waiters end: the first launch's files the issue, and the restart's adds to it.
        func probeTimeouts() async -> [DebugTracker.Issue] {
            await supervisor.listDebugIssues().filter { $0.trigger == "probe_timeout" }
        }
        let deadline = Date().addingTimeInterval(40)
        while await probeTimeouts().first?.recurrenceCount != 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        // A third capture, or a second issue, would come soon after.
        try await Task.sleep(for: .seconds(3))

        let found = await probeTimeouts()
        XCTAssertEqual(found.count, 1, "\(found.map(\.errorMessage))")
        XCTAssertEqual(found.first?.errorMessage, "flaky did not pass its startup probe in 10s (process alive: yes)")
        XCTAssertEqual(found.first?.recurrenceCount, 1, "the second waiter adds to the first issue")
    }

    /// Supabase: `supabase start` ends with code 0 when the stack is up. The stack
    /// runs on, so the service must stay "running".
    func testALauncherThatEndsCleanlyLeavesAReusedServiceRunning() async throws {
        let script = "python3 -u -m http.server \(port) --bind 127.0.0.1 >/dev/null 2>&1 & sleep 5; exit 0"
        try load(daemon("stack", ["sh", "-c", script], reuse: true))

        supervisor.restartService("stack")

        let ready = await waitUntil(30) { self.settled("stack") }
        XCTAssertTrue(ready)
        // The launcher ends about five seconds after it started.
        try await Task.sleep(for: .seconds(8))

        XCTAssertEqual(state("stack").phase, .running)
        XCTAssertEqual(supervisor.health, .healthy)
        XCTAssertEqual(state("stack").exitCode, 0, "the launcher has ended")
    }

    /// GitHub issue 1: a portal that starts without the local stack's keys has no
    /// signing key, or it uses the hosted dev values of its shared .env.
    func testAPortalDoesNotStartInLocalModeWithoutTheLocalKeys() async throws {
        try load(daemon("partner-portal", ["sh", "-c", "echo portal-start; sleep 30"]))
        XCTAssertEqual(supervisor.dbMode, .local)

        supervisor.restartService("partner-portal")

        let failed = await waitUntil(20) {
            self.state("partner-portal").phase == .failed && self.supervisor.actionsInFlight.isEmpty
        }
        XCTAssertTrue(failed, "partner-portal is \(state("partner-portal").phase.rawValue)")
        let lines = await logLines("partner-portal")
        XCTAssertFalse(lines.contains("portal-start"), "the process must not start")
        XCTAssertTrue(supervisor.lastError?.contains("keys of the local Supabase stack") == true, supervisor.lastError ?? "nil")
        XCTAssertTrue(Self.listeners(on: port).isEmpty)
    }

    /// A probe with no port crashed the app at Start. It must fail the one service
    /// with a message, and start no process.
    func testAServiceWithABadProbeFailsWithAMessageAndStartsNothing() async throws {
        let probes = [
            ProbeConfig(type: .tcp, port: nil, host: nil, url: nil, pattern: nil, artifact: nil, timeout: 5),
            ProbeConfig(type: .tcp, port: 70000, host: nil, url: nil, pattern: nil, artifact: nil, timeout: 5),
            ProbeConfig(type: .stdoutRegex, port: nil, host: nil, url: nil, pattern: nil, artifact: nil, timeout: 5),
            ProbeConfig(type: .stdoutRegex, port: nil, host: nil, url: nil, pattern: "ready (", artifact: nil, timeout: 5),
            ProbeConfig(type: .http, port: nil, host: nil, url: nil, pattern: nil, artifact: nil, timeout: 5),
        ]
        for probe in probes {
            try load(ServiceDefinition(
                id: "custom", name: "Custom", cmd: ["sh", "-c", "echo custom-start; sleep 30"], cwd: workDir.path,
                probe: probe, type: .daemon, restart: .onFailure, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
            ))

            supervisor.restartService("custom")

            let failed = await waitUntil(20) {
                self.state("custom").phase == .failed && self.supervisor.actionsInFlight.isEmpty
            }
            XCTAssertTrue(failed, "custom is \(state("custom").phase.rawValue) for \(probe)")
            let reason = try XCTUnwrap(probe.problem)
            XCTAssertEqual(
                supervisor.lastError,
                "Custom cannot start: \(reason). Correct its probe in services.json, "
                    + "then quit \(Flavor.current.displayName) and open it again."
            )
            let lines = await logLines("custom")
            XCTAssertFalse(lines.contains("custom-start"), "the process must not start")
            XCTAssertNil(state("custom").pid)
        }
    }

    /// Ticket "failed wake probe" with a recurrence five seconds later: two wake
    /// notifications ran two passes, and both restarted the service.
    func testTwoWakeNotificationsRestartAFailedServiceOnce() async throws {
        try load(daemon("web", webServer))
        // "Running" for the supervisor, but nothing listens: the probe after wake fails.
        state("web").phase = .running
        state("web").lastStarted = Date().addingTimeInterval(-3600)

        supervisor.handleWake()
        supervisor.handleWake()

        let back = await waitUntil(60) { self.state("web").phase == .running && !Self.listeners(on: self.port).isEmpty }
        XCTAssertTrue(back, "web is \(state("web").phase.rawValue)")
        try await Task.sleep(for: .seconds(4))

        let lines = await logLines("web")
        XCTAssertFalse(lines.contains { $0.contains("Address already in use") }, lines.joined(separator: "\n"))
        XCTAssertEqual(Self.listeners(on: port).count, 1)
        XCTAssertEqual(state("web").restartCount, 1)
        XCTAssertEqual(state("web").phase, .running)
        XCTAssertTrue(crashes.isEmpty, "\(crashes)")
    }

    /// Platform core of the hackathon fork: a checkout without the app, or without
    /// its packages or its env, must not make a crash loop on the port of the app. The
    /// service is skipped with the cause in its log, and it starts when the cause is gone.
    func testPlatformCoreIsSkippedUntilItsFolderHasThePackagesAndTheEnv() async throws {
        let id = ServiceCatalog.platformCoreID
        try load(daemon(id, webServer))
        let fm = FileManager.default

        /// Restarts the service and waits for a line of the runner with `text` in its log.
        func restartAndWait(for text: String) async throws -> [String] {
            supervisor.restartService(id)
            var lines: [String] = []
            let deadline = Date().addingTimeInterval(20)
            repeat {
                try await Task.sleep(for: .milliseconds(100))
                lines = await logLines(id)
            } while !lines.contains { $0.contains(text) } && Date() < deadline
            XCTAssertTrue(lines.contains { $0.contains(text) }, lines.joined(separator: "\n"))
            let idle = await waitUntil(10) { self.supervisor.actionsInFlight.isEmpty }
            XCTAssertTrue(idle)
            return lines
        }
        func writePackage(port: Int) throws {
            let scripts = ["dev:dev": "dotenv -e .env.dev -- next dev --turbopack -p \(port)"]
            try JSONSerialization.data(withJSONObject: ["scripts": scripts]).write(to: workDir.appendingPathComponent("package.json"))
        }

        // An old checkout: the app is not there.
        var lines = try await restartAndWait(for: "Pull the fork")
        XCTAssertTrue(lines.contains { $0.contains("Platform core is skipped") && $0.contains("apps/platform-core") })
        XCTAssertEqual(state(id).phase, .skipped)

        // The fork starts the app on a port that the runner did not read.
        try writePackage(port: port + 1)
        lines = try await restartAndWait(for: "Quit the runner")
        XCTAssertTrue(lines.contains { $0.contains("port \(port + 1)") })
        XCTAssertEqual(state(id).phase, .skipped)

        // The port of the runner, but no packages.
        try writePackage(port: port)
        _ = try await restartAndWait(for: "pnpm install")
        XCTAssertEqual(state(id).phase, .skipped)

        // The packages, but no env.
        let bin = workDir.appendingPathComponent("node_modules/.bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: bin.appendingPathComponent("next"))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("next").path)
        lines = try await restartAndWait(for: "LOGIN_URL, NEXT_PUBLIC_FASTBREAK_DOMAIN")
        XCTAssertTrue(lines.contains { $0.contains("apps/platform-core/.env.dev") })
        XCTAssertEqual(state(id).phase, .skipped)
        XCTAssertTrue(Self.listeners(on: port).isEmpty)

        // The env in the file that the script reads.
        try "LOGIN_URL=https://identity.example.ai/login/init\nNEXT_PUBLIC_FASTBREAK_DOMAIN=example.ai\n"
            .write(to: workDir.appendingPathComponent(".env.dev"), atomically: true, encoding: .utf8)
        supervisor.restartService(id)
        let ready = await waitUntil(40) { self.settled(id) }
        XCTAssertTrue(ready, "\(id) is \(state(id).phase.rawValue)")
        XCTAssertEqual(Self.listeners(on: port).count, 1)
        lines = await logLines(id)
        XCTAssertTrue(lines.contains { $0.contains("http://localhost:\(port)") }, lines.joined(separator: "\n"))
        XCTAssertTrue(crashes.isEmpty, "\(crashes)")
    }

    // MARK: - Automatic database reset

    /// A stand-in for Supabase that counts as running, with a fake database behind it.
    private func loadSupabase() throws {
        try load(daemon("supabase", ["sleep", "60"]))
        state("supabase").phase = .running
    }

    /// Finding "failed query treated as empty DB": Docker was down, or the container
    /// was not there, and the runner wiped the database.
    func testAFailedDatabaseQueryNeverStartsAReset() async throws {
        try loadSupabase()
        // One question for each call: the wait for a late database has its own tests.
        supervisor.databaseProbeRetry = (.milliseconds(10), .zero)
        var queries = 0
        var resets = 0
        // A login profile prints its own warning first; the error of Docker is the last line.
        var answer = DbQueryResult(exitCode: 1, stdout: "", stderr: "\ncompinit: insecure directories\nCannot connect to the Docker daemon\n")
        supervisor.databaseQuery = { _, _ in
            queries += 1
            return answer
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }

        let failedQuery = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)

        XCTAssertFalse(failedQuery)
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(resets, 0)
        XCTAssertFalse(supervisor.dbResetRunning)
        XCTAssertEqual(
            supervisor.lastError,
            "Could not read the local database (Cannot connect to the Docker daemon). Nothing was changed."
        )

        // An answer that is not a number is not an empty database.
        answer = DbQueryResult(exitCode: 0, stdout: "", stderr: "")
        _ = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)
        XCTAssertEqual(resets, 0)

        // Supabase does not run: the runner does not ask, and does not reset.
        answer = DbQueryResult(exitCode: 0, stdout: "0", stderr: "")
        state("supabase").phase = .failed
        _ = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)
        XCTAssertEqual(queries, 2)
        XCTAssertEqual(resets, 0)

        // Control: a database that answers with no tables is reset, as before.
        state("supabase").phase = .running
        supervisor.lastError = nil
        let emptyDatabase = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)
        XCTAssertTrue(emptyDatabase)
        XCTAssertEqual(resets, 1)
        XCTAssertNil(supervisor.lastError)

        // A database with tables is left alone.
        answer = DbQueryResult(exitCode: 0, stdout: "42", stderr: "")
        _ = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: false)
        XCTAssertEqual(resets, 1)
    }

    /// The query itself (`docker exec … psql`) with a Docker that hangs: the
    /// timeout counts as a failed query, never as an empty database.
    func testADatabaseQueryThatTimesOutNeverStartsAReset() async throws {
        try loadSupabase()
        supervisor.databaseProbeRetry = (.milliseconds(10), .zero)
        var resets = 0
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }
        let docker = FakeCommandRunner { _ in FakeCommandRunner.timedOut }
        supervisor.shell = docker

        let didReset = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)

        XCTAssertFalse(didReset)
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(docker.calls.count, 1)
        XCTAssertTrue(docker.commands.first?.contains("psql") == true, "\(docker.commands)")
        XCTAssertEqual(docker.calls.first?.timeout, .seconds(20))
        XCTAssertEqual(
            supervisor.lastError, "Could not read the local database (The database did not answer in 20 s.). Nothing was changed."
        )

        // Control: the same path with a database that answers "no tables" is reset.
        docker.respond { _ in FakeCommandRunner.ok("0\n") }
        supervisor.lastError = nil
        let emptyDatabase = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)
        XCTAssertTrue(emptyDatabase)
        XCTAssertEqual(resets, 1)
    }

    /// A first run: the port of Supabase is open, but Postgres does not take queries
    /// yet. The runner asks again, and the empty database still gets its setup.
    func testADatabaseThatAnswersLateIsReset() async throws {
        try loadSupabase()
        supervisor.databaseProbeRetry = (.milliseconds(20), .seconds(20))
        var queries = 0
        var resets = 0
        supervisor.databaseQuery = { _, _ in
            queries += 1
            return queries < 3
                ? DbQueryResult(exitCode: 2, stdout: "", stderr: "psql: error: the database system is starting up")
                : DbQueryResult(exitCode: 0, stdout: "0", stderr: "")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }

        let didReset = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)

        XCTAssertTrue(didReset)
        XCTAssertEqual(queries, 3)
        XCTAssertEqual(resets, 1)
        XCTAssertNil(supervisor.lastError)
        let lines = await logLines("supabase")
        XCTAssertEqual(lines.filter { $0.contains("does not answer yet") }.count, 1, lines.joined(separator: "\n"))
    }

    // MARK: - Runner too old for the checkout (T2)

    private func writeManifest(minVersion: String) throws {
        let folder = workDir.appendingPathComponent("scripts/db")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"version":4,"runner":{"minVersion":"\#(minVersion)"},"steps":[],"profiles":{}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
    }

    private static let tooOldText =
        "This fb-travel-monolith checkout needs Travel Runner 0.14.0 or newer (you have 0.13.4). "
        + "The database was not touched."

    /// Finding "no runner-to-monolith compatibility check": an old runner on a new
    /// checkout wiped the database in a loop. Now it does not even ask the database.
    func testARunnerOlderThanTheCheckoutNeverResetsByItself() async throws {
        try loadSupabase()
        try writeManifest(minVersion: "0.14.0")
        supervisor.runnerVersion = "0.13.4"
        supervisor.databaseProbeRetry = (.milliseconds(10), .zero)
        var queries = 0
        var resets = 0
        // An empty database: the case that starts a reset.
        supervisor.databaseQuery = { _, _ in
            queries += 1
            return DbQueryResult(exitCode: 0, stdout: "0", stderr: "")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }

        let blocked = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)

        XCTAssertFalse(blocked)
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(resets, 0)
        XCTAssertFalse(supervisor.dbResetRunning)
        XCTAssertEqual(supervisor.compatibilityNotice?.text, Self.tooOldText)
        // The service is left alone: only the reset is blocked.
        XCTAssertEqual(state("supabase").phase, .running)
        XCTAssertTrue(supervisor.statusJSON().contains("\"reset_blocked\""))

        // Control: the same checkout with the runner it asks for is reset, and the banner goes.
        supervisor.runnerVersion = "0.14.0"
        let allowed = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)
        XCTAssertTrue(allowed)
        XCTAssertEqual(resets, 1)
        XCTAssertNil(supervisor.compatibilityNotice)
        XCTAssertFalse(supervisor.statusJSON().contains("reset_blocked"))
    }

    /// The Reset button, a retry, one step, and the control API: all blocked.
    func testARunnerOlderThanTheCheckoutRunsNoManualResetOrStep() async throws {
        try loadSupabase()
        try writeManifest(minVersion: "0.14.0")
        supervisor.runnerVersion = "0.13.4"

        supervisor.resetDatabase()
        supervisor.runDbSetup(profile: "full")
        supervisor.runDbSetup(from: "reset-database")
        supervisor.runDbSetupStep("reset-database")

        XCTAssertNil(supervisor.dbSetupPipeline)
        XCTAssertFalse(supervisor.dbResetRunning)
        XCTAssertNil(supervisor.lastError)
        XCTAssertEqual(supervisor.compatibilityNotice?.text, Self.tooOldText)
        let body = try XCTUnwrap(supervisor.resetBlockJSON())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["error"] as? String, "runner_too_old")
        XCTAssertEqual(json["message"] as? String, Self.tooOldText)
        XCTAssertEqual(json["download_url"] as? String, "https://github.com/devingearing-fb/travel-runner/releases/latest")

        // Control: a runner that is new enough passes the check. This test has no seed
        // scenario, so the reset stops at the next guard, with that guard's message.
        supervisor.runnerVersion = "0.14.0"
        XCTAssertNil(supervisor.resetBlockJSON())
        supervisor.resetDatabase()
        XCTAssertNil(supervisor.compatibilityNotice)
        XCTAssertNotNil(supervisor.lastError)
        XCTAssertFalse(supervisor.dbResetRunning)
    }

    /// A checkout with no `runner` section, and a runner with no version (`swift run`),
    /// reset as before.
    func testNoMinimumOrNoVersionBlocksNothing() async throws {
        try loadSupabase()
        supervisor.databaseProbeRetry = (.milliseconds(10), .zero)
        var resets = 0
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "0", stderr: "") }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }

        // No manifest at all.
        supervisor.runnerVersion = "0.13.4"
        let noManifest = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: false)
        XCTAssertTrue(noManifest)

        // A minimum, but a runner that has no version to compare.
        try writeManifest(minVersion: "99.0.0")
        supervisor.runnerVersion = nil
        let noVersion = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: false)
        XCTAssertTrue(noVersion)

        XCTAssertEqual(resets, 2)
        XCTAssertNil(supervisor.compatibilityNotice)
    }

    /// A database that never answers is never reset: the wait ends with the message.
    func testADatabaseThatNeverAnswersIsNotReset() async throws {
        try loadSupabase()
        supervisor.databaseProbeRetry = (.milliseconds(20), .milliseconds(300))
        var queries = 0
        var resets = 0
        supervisor.databaseQuery = { _, _ in
            queries += 1
            return DbQueryResult(exitCode: 1, stdout: "", stderr: "Error response from daemon: No such container: x")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }

        let didReset = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)

        XCTAssertFalse(didReset)
        XCTAssertGreaterThan(queries, 1, "the runner asks again before it gives up")
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(
            supervisor.lastError,
            "Could not read the local database (Error response from daemon: No such container: x). Nothing was changed."
        )
    }

    /// A stop during the wait for a late database ends the wait, without a message.
    func testAStopEndsTheWaitForALateDatabase() async throws {
        try loadSupabase()
        supervisor.databaseProbeRetry = (.milliseconds(20), .seconds(30))
        var queries = 0
        var resets = 0
        supervisor.databaseQuery = { _, _ in
            queries += 1
            return DbQueryResult(exitCode: 2, stdout: "", stderr: "psql: error: the database system is starting up")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }
        let cwd = workDir.path
        let check = Task { await self.supervisor.resetDatabaseIfNeeded(cwd: cwd, checkMigrations: true) }
        let asking = await waitUntil(10) { queries >= 2 }
        XCTAssertTrue(asking)

        supervisor.stopAll()
        let ended = await waitUntil(10) { self.supervisor.health == .stopped }
        XCTAssertTrue(ended)
        let didReset = await check.value

        XCTAssertFalse(didReset)
        XCTAssertEqual(resets, 0)
        XCTAssertNil(supervisor.lastError)
    }

    /// The reset keeps its own error, and a second reset does not start while one runs.
    func testAFailedResetKeepsItsErrorAndASecondResetDoesNotStart() async throws {
        try loadSupabase()
        var resets = 0
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "0", stderr: "") }
        var second: Bool?
        supervisor.dbResetAction = { [supervisor] cwd in
            resets += 1
            // The same request while this one runs.
            second = await supervisor?.resetDatabaseIfNeeded(cwd: cwd, checkMigrations: false)
            supervisor?.lastError = "DB reset failed at Load hotels: HTTP 401"
            return false
        }

        let first = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: false)

        XCTAssertTrue(first, "a reset ran, and failed")
        XCTAssertEqual(second, false, "no reset started for the second request")
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(supervisor.lastError, "DB reset failed at Load hotels: HTTP 401")
        XCTAssertFalse(supervisor.dbResetRunning)
    }

    /// Finding "reset runs after Stop": the stop arrived while the runner asked the
    /// database, the answer was "no tables" (or an error), and a reset started.
    func testStopDuringGroundDoesNotStartAReset() async throws {
        try loadSupabase()
        var resets = 0
        var asked = false
        var release: CheckedContinuation<Void, Never>?
        supervisor.databaseQuery = { _, _ in
            asked = true
            await withCheckedContinuation { release = $0 }
            return DbQueryResult(exitCode: 0, stdout: "0", stderr: "")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }
        let cwd = workDir.path
        let check = Task { await self.supervisor.resetDatabaseIfNeeded(cwd: cwd, checkMigrations: true) }
        let waiting = await waitUntil(10) { asked && release != nil }
        XCTAssertTrue(waiting)

        supervisor.stopAll()
        let stopped = await waitUntil(10) { self.supervisor.health == .stopped }
        XCTAssertTrue(stopped)
        release?.resume()
        let didReset = await check.value

        XCTAssertFalse(didReset)
        XCTAssertEqual(resets, 0)
        XCTAssertFalse(supervisor.dbResetRunning)
        XCTAssertNil(supervisor.lastError)
    }

    /// A reset that was cancelled between two steps has no failed step. The banner
    /// stayed at "running db:reset..." although nothing ran.
    func testAResetThatEndsWithNoFailedStepDoesNotLeaveTheProgressText() async throws {
        try loadSupabase()
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "0", stderr: "") }
        supervisor.dbResetAction = { _ in false }

        await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: false)

        XCTAssertEqual(
            supervisor.lastError,
            "The database reset stopped before it finished. Open DB Tools and click Reset Database to run it again."
        )
        XCTAssertFalse(supervisor.dbResetRunning)
    }

    /// The answer "no tables" arrives after Stop was clicked and before the stop
    /// changed the state of Supabase: only the stop flag says that the start is over.
    func testAnAnswerThatArrivesAsTheStopBeginsDoesNotStartAReset() async throws {
        try loadSupabase()
        var resets = 0
        var asked = false
        var release: CheckedContinuation<Void, Never>?
        supervisor.databaseQuery = { _, _ in
            asked = true
            await withCheckedContinuation { release = $0 }
            return DbQueryResult(exitCode: 0, stdout: "0", stderr: "")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }
        let cwd = workDir.path
        let check = Task { await self.supervisor.resetDatabaseIfNeeded(cwd: cwd, checkMigrations: true) }
        let waiting = await waitUntil(10) { asked && release != nil }
        XCTAssertTrue(waiting)

        // The answer is on its way when the stop begins. Nothing waits between the
        // two lines, so the answer is read before the stop marks Supabase as stopping.
        release?.resume()
        supervisor.stopAll()
        let didReset = await check.value

        XCTAssertFalse(didReset)
        XCTAssertEqual(resets, 0)
        _ = await waitUntil(10) { self.supervisor.health == .stopped }
    }

    /// A stop cancels the task of the start. Supabase can still count as running
    /// then, so the cancel alone must end the check.
    func testACancelledStartDoesNotStartAReset() async throws {
        try loadSupabase()
        var resets = 0
        var release: CheckedContinuation<Void, Never>?
        supervisor.databaseQuery = { _, _ in
            await withCheckedContinuation { release = $0 }
            return DbQueryResult(exitCode: 0, stdout: "0", stderr: "")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }
        let cwd = workDir.path
        let check = Task { await self.supervisor.resetDatabaseIfNeeded(cwd: cwd, checkMigrations: true) }
        let waiting = await waitUntil(10) { release != nil }
        XCTAssertTrue(waiting)

        check.cancel()
        release?.resume()
        let didReset = await check.value

        XCTAssertFalse(didReset)
        XCTAssertEqual(resets, 0)
        XCTAssertEqual(state("supabase").phase, .running)
        XCTAssertNil(supervisor.lastError)

        // Control: the same answer without the cancel starts the reset.
        release = nil
        let again = Task { await self.supervisor.resetDatabaseIfNeeded(cwd: cwd, checkMigrations: true) }
        _ = await waitUntil(10) { release != nil }
        release?.resume()
        let didResetAgain = await again.value
        XCTAssertTrue(didResetAgain)
        XCTAssertEqual(resets, 1)
    }

    /// The database has tables and lacks a migration. A stop that arrives while the
    /// runner reads the applied migrations must not start the reset.
    func testAStopWhileTheMigrationsAreReadDoesNotStartAReset() async throws {
        try loadSupabase()
        let migrations = workDir.appendingPathComponent(".backend-baseline/supabase/migrations")
        try FileManager.default.createDirectory(at: migrations, withIntermediateDirectories: true)
        try Data().write(to: migrations.appendingPathComponent("20260101000000_base.sql"))
        var resets = 0
        var release: CheckedContinuation<Void, Never>?
        supervisor.databaseQuery = { _, sql in
            // The first question counts the tables; the second reads the applied versions.
            guard sql.contains("schema_migrations") else { return DbQueryResult(exitCode: 0, stdout: "42", stderr: "") }
            await withCheckedContinuation { release = $0 }
            return DbQueryResult(exitCode: 0, stdout: "", stderr: "")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }
        let cwd = workDir.path

        // Control: without a stop, the missing migration starts the reset.
        let control = Task { await self.supervisor.resetDatabaseIfNeeded(cwd: cwd, checkMigrations: true) }
        let controlWaiting = await waitUntil(10) { release != nil }
        XCTAssertTrue(controlWaiting)
        release?.resume()
        let controlReset = await control.value
        XCTAssertTrue(controlReset)
        XCTAssertEqual(resets, 1)

        release = nil
        let check = Task { await self.supervisor.resetDatabaseIfNeeded(cwd: cwd, checkMigrations: true) }
        let waiting = await waitUntil(10) { release != nil }
        XCTAssertTrue(waiting)
        // Supabase went down while the runner asked.
        state("supabase").phase = .failed
        release?.resume()
        let didReset = await check.value

        XCTAssertFalse(didReset)
        XCTAssertEqual(resets, 1)
    }

    func testOnlyAnAnswerOfZeroIsAnEmptyDatabase() {
        XCTAssertEqual(DbProbe.classify(DbQueryResult(exitCode: 0, stdout: "0", stderr: "")), .empty)
        XCTAssertEqual(DbProbe.classify(DbQueryResult(exitCode: 0, stdout: "17\n", stderr: "warning")), .hasTables)
        XCTAssertEqual(
            DbProbe.classify(DbQueryResult(exitCode: 1, stdout: "", stderr: "Error response from daemon: No such container: x")),
            .unknown("Error response from daemon: No such container: x")
        )
        XCTAssertEqual(DbProbe.classify(DbQueryResult(exitCode: 127, stdout: "", stderr: "")), .unknown("exit code 127"))
        XCTAssertEqual(DbProbe.classify(DbQueryResult(exitCode: 0, stdout: "", stderr: "")), .unknown("the query gave no answer"))

        // The query runs in a login shell. A profile that prints does not hide the count.
        XCTAssertEqual(DbProbe.classify(DbQueryResult(exitCode: 0, stdout: "Welcome back\n0\n", stderr: "")), .empty)
        XCTAssertEqual(DbProbe.classify(DbQueryResult(exitCode: 0, stdout: "nvm: using v22\n\n17", stderr: "")), .hasTables)
        // The error of Docker or psql is the last line, after the warnings of the profile.
        XCTAssertEqual(
            DbProbe.classify(DbQueryResult(
                exitCode: 1, stdout: "", stderr: "compinit: insecure directories\nError response from daemon: No such container: x\n"
            )),
            .unknown("Error response from daemon: No such container: x")
        )
        // psql prints `LINE 1:` and a caret after an SQL error. The detail is the error.
        XCTAssertEqual(
            DbProbe.classify(DbQueryResult(
                exitCode: 1, stdout: "",
                stderr: "ERROR:  relation \"public.events\" does not exist\nLINE 1: SELECT count(*) FROM public.events\n                             ^\n"
            )),
            .unknown("ERROR:  relation \"public.events\" does not exist")
        )
        // A socket that does not answer: the cause is the first line, a hint is the last.
        XCTAssertEqual(
            DbProbe.classify(DbQueryResult(
                exitCode: 2, stdout: "",
                stderr: "psql: error: connection to server on socket \"/tmp/.s.PGSQL.5432\" failed: No such file or directory\n"
                    + "\tIs the server running locally and accepting connections on that socket?\n"
            )),
            .unknown("psql: error: connection to server on socket \"/tmp/.s.PGSQL.5432\" failed: No such file or directory")
        )
        // An error with no known mark: the last line.
        XCTAssertEqual(
            DbProbe.classify(DbQueryResult(exitCode: 1, stdout: "", stderr: "first\nsomething broke\n")),
            .unknown("something broke")
        )
        // An answer that is not a number stays on one line of the banner.
        XCTAssertEqual(
            DbProbe.classify(DbQueryResult(exitCode: 0, stdout: "first line\nnot a number", stderr: "")),
            .unknown("unexpected answer: not a number")
        )
    }

    /// Finding ux-triage-no-cause: FAILED with three raw lines and no cause. A failed
    /// service now says why and offers the fix; the reason goes when it runs again.
    func testAFailedServiceSaysWhyAndTheReasonGoesWhenItRuns() async throws {
        let marker = workDir.appendingPathComponent("installed").path
        let script = "if [ -f '\(marker)' ]; then exec \(webServer.joined(separator: " ")); "
            + "else echo \"Error: Cannot find module 'next'\"; exit 1; fi"
        try load(ServiceDefinition(
            id: "web", name: "Web App", cmd: ["sh", "-c", script], cwd: workDir.path,
            probe: ProbeConfig(type: .tcp, port: port, host: nil, url: nil, pattern: nil, artifact: nil, timeout: 30),
            type: .daemon, restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        ))

        supervisor.restartService("web")

        // The exit says why at once; the wait for the probe ends up to two seconds later.
        let said = await waitUntil(20) {
            self.state("web").phase == .failed && self.state("web").condition != nil
                && self.supervisor.actionsInFlight.isEmpty
        }
        XCTAssertTrue(said, "web is \(state("web").phase.rawValue)")
        let condition = try XCTUnwrap(state("web").condition)
        XCTAssertEqual(condition.headline, "A package is missing — dependencies are out of date.")
        XCTAssertEqual(condition.action, .installDependencies)
        XCTAssertEqual(state("web").likelyCause, "Error: Cannot find module 'next'")
        XCTAssertEqual(supervisor.lastError, "Web App exited before it was ready — see its log")
        let failed = EnvironmentSupervisor.statusFields(state("web"))
        XCTAssertEqual(failed["reason"], condition.text)
        XCTAssertEqual(failed["likely_cause"], "Error: Cannot find module 'next'")
        XCTAssertNil(failed["skip_reason"])

        FileManager.default.createFile(atPath: marker, contents: nil)
        supervisor.restartService("web")

        let ready = await waitUntil(30) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        XCTAssertNil(state("web").condition)
        XCTAssertNil(state("web").likelyCause)
        XCTAssertEqual(state("web").lastProbe, .ok)
        let running = EnvironmentSupervisor.statusFields(state("web"))
        XCTAssertNil(running["reason"])
        XCTAssertNil(running["likely_cause"])
        XCTAssertEqual(running["last_probe"], "ready")
    }

    /// The breaker gives its own reason, and the exit of the third crash does not
    /// replace it.
    func testATrippedBreakerSaysItStoppedRetrying() async throws {
        try load(daemon("boom", ["sh", "-c", "echo boom-start; exit 1"], probeTimeout: 60))

        supervisor.restartService("boom")

        let tripped = await waitUntil(40) {
            self.state("boom").isCircuitBroken && self.supervisor.actionsInFlight.isEmpty
                && self.state("boom").condition != nil
        }
        XCTAssertTrue(tripped)
        try await Task.sleep(for: .seconds(1))
        let condition = try XCTUnwrap(state("boom").condition)
        XCTAssertEqual(condition.kind, .halted(reason: "crash loop"))
        XCTAssertEqual(condition.text, "Stopped retrying after 3 crashes in a minute. Cause: not clear from the log.")
        XCTAssertEqual(condition.action, .restart)
    }

    /// A daemon that ends with code 0 has no process, and nothing starts it again.
    /// The environment showed "starting" with no end.
    func testACleanExitOfADaemonGivesDegradedNotStarting() async throws {
        let quitter = ServiceDefinition(
            id: "quitter", name: "quitter", cmd: ["sh", "-c", "echo quitter-start; sleep 2; exit 0"], cwd: workDir.path,
            probe: nil, type: .daemon, restart: .onFailure, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        try load(quitter)
        supervisor.restartService("quitter")
        let ready = await waitUntil(15) { self.settled("quitter") }
        XCTAssertTrue(ready, "quitter is \(state("quitter").phase.rawValue)")
        XCTAssertEqual(supervisor.health, .healthy)

        let ended = await waitUntil(15) { self.state("quitter").phase != .running }
        XCTAssertTrue(ended)
        // Long enough for an automatic restart, if there was one.
        try await Task.sleep(for: .seconds(4))

        XCTAssertEqual(supervisor.health, .degraded)
        XCTAssertEqual(state("quitter").phase, .failed)
        XCTAssertEqual(state("quitter").exitCode, 0)
        let lines = await logLines("quitter")
        XCTAssertTrue(lines.contains("[travel-runner] quitter exited (code 0) — not restarted"), lines.joined(separator: "\n"))
        XCTAssertEqual(lines.filter { $0 == "quitter-start" }.count, 1, "it is not restarted")
        XCTAssertTrue(crashes.isEmpty, "a clean exit is not a crash: \(crashes)")
        // The header shows its banner only with a text.
        XCTAssertEqual(supervisor.lastError, "quitter exited (code 0) and was not restarted — restart it from its row")
    }

    /// The banner of a clean exit asks for a restart from the row. The restart
    /// clears it, and it does not clear another error.
    func testARestartFromTheRowClearsTheCleanExitBanner() async throws {
        let marker = workDir.appendingPathComponent("second-run").path
        let script = "if [ -f '\(marker)' ]; then exec sleep 60; else touch '\(marker)'; sleep 2; exit 0; fi"
        let quitter = ServiceDefinition(
            id: "quitter", name: "quitter", cmd: ["sh", "-c", script], cwd: workDir.path,
            probe: nil, type: .daemon, restart: .onFailure, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        try load(quitter)
        supervisor.restartService("quitter")
        let banner = EnvironmentSupervisor.cleanExitMessage("quitter")
        let ended = await waitUntil(20) { self.state("quitter").phase == .failed && self.supervisor.lastError == banner }
        XCTAssertTrue(ended, supervisor.lastError ?? "nil")

        supervisor.restartService("quitter")
        let cleared = await waitUntil(15) { self.settled("quitter") && self.supervisor.lastError == nil }
        XCTAssertTrue(cleared, supervisor.lastError ?? "nil")

        // An error that is not the banner of this service stays.
        supervisor.lastError = "Could not save profile: disk full"
        supervisor.restartService("quitter")
        let started = await waitUntil(5) { !self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(started)
        let restarted = await waitUntil(15) { self.settled("quitter") }
        XCTAssertTrue(restarted)
        XCTAssertEqual(supervisor.lastError, "Could not save profile: disk full")
    }

    /// The Start control of a row: only for a daemon of the profile that has no
    /// process while the environment runs.
    func testTheRowOffersStartOnlyForAStoppedDaemonOfTheProfile() throws {
        func service(_ id: String, type: ServiceType = .daemon) -> ServiceDefinition {
            ServiceDefinition(
                id: id, name: id, cmd: ["sleep", "1"], cwd: workDir.path, probe: nil, type: type, restart: .never,
                dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
            )
        }
        try supervisor.loadServices(
            [service("stripe"), service("partner-portal"), service("seed", type: .oneshot)], profile: .booking
        )
        supervisor.health = .degraded
        for id in ["stripe", "partner-portal", "seed"] { state(id).phase = .skipped }

        XCTAssertTrue(supervisor.canStartFromRow(state("stripe")))
        state("stripe").phase = .stopped
        XCTAssertTrue(supervisor.canStartFromRow(state("stripe")))

        // Negative controls.
        XCTAssertFalse(supervisor.canStartFromRow(state("partner-portal")), "outside the profile")
        XCTAssertFalse(supervisor.canStartFromRow(state("seed")), "a oneshot")
        for phase in [ServicePhase.running, .starting, .failed, .pending] {
            state("stripe").phase = phase
            XCTAssertFalse(supervisor.canStartFromRow(state("stripe")), phase.rawValue)
        }
        state("stripe").phase = .skipped
        supervisor.health = .stopped
        XCTAssertFalse(supervisor.canStartFromRow(state("stripe")), "the environment is stopped: Start All is the control")
    }

    private func stripe(_ script: String) -> ServiceDefinition {
        ServiceDefinition(
            id: "stripe", name: "Stripe CLI", cmd: ["sh", "-c", script], cwd: workDir.path,
            probe: nil, type: .daemon, restart: .onFailure, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
    }

    /// 105 tickets: Stripe ended as "skipped" with no line that says why. The CLI
    /// check is a fake; the test does not run the Stripe CLI.
    func testStripeWithoutItsCliIsSkippedWithTheCauseInItsLog() async throws {
        let tracker = captureIssues()
        try load(stripe("echo stripe-start; sleep 30"))
        supervisor.stripeAvailability = { false }
        var feedback: [String] = []
        supervisor.onActionFeedback = { message, _ in feedback.append(message) }

        supervisor.restartService("stripe")

        let skipped = await waitUntil(15) { self.state("stripe").phase == .skipped && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(skipped, "stripe is \(state("stripe").phase.rawValue)")
        let lines = await logLines("stripe")
        XCTAssertTrue(
            lines.contains { $0.hasPrefix("[travel-runner] Stripe stopped: ") && $0.contains("stripe login") },
            lines.joined(separator: "\n")
        )
        XCTAssertFalse(lines.contains("stripe-start"), "the process must not start")
        XCTAssertEqual(feedback, ["Stripe CLI skipped — see its log"])
        XCTAssertEqual(supervisor.health, .healthy, "Stripe is optional")

        let skips = await events("stripe_skip", in: tracker)
        XCTAssertEqual(skips.count, 1)
        XCTAssertEqual(skips.first?.serviceId, "stripe")
        XCTAssertTrue(skips.first?.message.contains("stripe login") == true, "\(skips)")

        // F4: a skip has a reason on the row and in the status API.
        let condition = try XCTUnwrap(state("stripe").condition)
        XCTAssertEqual(condition.kind, .optionalOff)
        XCTAssertEqual(condition.headline, "Stripe CLI is not installed or not logged in — webhooks are off.")
        let fields = EnvironmentSupervisor.statusFields(state("stripe"))
        XCTAssertEqual(fields["skip_reason"], condition.text)
        XCTAssertNil(fields["reason"])
    }

    /// A Stripe CLI that fails (an expired session, say) is skipped, not restarted in
    /// a loop. Its log says so, with the exit code.
    func testAStripeCrashIsSkippedWithTheCauseInItsLog() async throws {
        try load(stripe("echo stripe-start; sleep 2; exit 1"))
        supervisor.stripeAvailability = { true }

        supervisor.restartService("stripe")

        let started = await waitUntil(15) { self.settled("stripe") }
        XCTAssertTrue(started, "stripe is \(state("stripe").phase.rawValue)")
        let skipped = await waitUntil(15) { self.state("stripe").phase == .skipped }
        XCTAssertTrue(skipped, "stripe is \(state("stripe").phase.rawValue)")
        try await Task.sleep(for: .seconds(3))

        let lines = await logLines("stripe")
        XCTAssertTrue(
            lines.contains(
                "[travel-runner] Stripe stopped: the Stripe CLI exited with code 1 — see the lines above. "
                    + "If they show 401, run: stripe login. Then start it from its row."
            ),
            lines.joined(separator: "\n")
        )
        XCTAssertEqual(lines.filter { $0 == "stripe-start" }.count, 1, "it is not restarted")
        XCTAssertEqual(state("stripe").phase, .skipped)
        XCTAssertEqual(supervisor.health, .healthy, "Stripe is optional")
        XCTAssertTrue(crashes.isEmpty, "\(crashes)")
    }

    /// The Stripe line said "see the lines above". Now it names the cause it finds there.
    func testAStripeCrashWithA401SaysThatTheSessionExpired() async throws {
        try load(stripe("echo 'Authorization failed, status=401'; sleep 2; exit 1"))
        supervisor.stripeAvailability = { true }

        supervisor.restartService("stripe")

        let skipped = await waitUntil(20) { self.state("stripe").phase == .skipped }
        XCTAssertTrue(skipped, "stripe is \(state("stripe").phase.rawValue)")
        let expected = "[travel-runner] Stripe stopped: the Stripe CLI exited with code 1 — "
            + "Stripe session expired — run `stripe login`, then restart Stripe"
        var lines: [String] = []
        for _ in 0..<100 where !lines.contains(expected) {
            try await Task.sleep(for: .milliseconds(50))
            lines = await logLines("stripe")
        }
        XCTAssertTrue(lines.contains(expected), lines.joined(separator: "\n"))
    }

    /// The Stripe log is not cleared on a restart. A 401 from an earlier launch
    /// labelled a later exit as an expired session.
    func testAnOld401InTheStripeLogIsNotTheCauseOfALaterExit() async throws {
        try load(stripe("echo stripe-start; sleep 2; exit 1"))
        supervisor.stripeAvailability = { true }
        await supervisor.logStore.append(serviceID: "stripe", entry: LogEntry(
            timestamp: Date().addingTimeInterval(-600), stream: .stderr, text: "Authorization failed, status=401"
        ))

        supervisor.restartService("stripe")

        let skipped = await waitUntil(20) { self.state("stripe").phase == .skipped }
        XCTAssertTrue(skipped, "stripe is \(state("stripe").phase.rawValue)")
        let prefix = "[travel-runner] Stripe stopped: the Stripe CLI exited with code 1"
        var lines: [String] = []
        for _ in 0..<100 where !lines.contains(where: { $0.hasPrefix(prefix) }) {
            try await Task.sleep(for: .milliseconds(50))
            lines = await logLines("stripe")
        }
        let stopped = lines.first { $0.hasPrefix(prefix) }
        XCTAssertNotNil(stopped, lines.joined(separator: "\n"))
        XCTAssertEqual(stopped?.contains("Stripe session expired"), false, stopped ?? "")
    }

    /// The row showed the first 20 characters of the webhook secret.
    func testTheRowShowsOnlyTheEndOfTheWebhookSecret() {
        let state = ServiceState(definition: stripe("true"))
        XCTAssertNil(state.capturedArtifactSummary)

        state.capturedArtifact = "whsec_0123456789abcdefWXYZ"

        XCTAssertEqual(state.capturedArtifactSummary, "Webhook secret captured (…WXYZ)")
    }

    /// Tickets on the port cleanup: a start killed each listener on a known port, also
    /// for a service outside the profile, and also the port helper of the container
    /// runtime. It also killed each `stripe listen` on the Mac.
    /// The test runs the cleanup step of a start with fake tools; no process is killed.
    func testAStartDoesNotKillAListenerOutsideTheProfile() async throws {
        let inProfile = try Self.listeningSocket()
        let outside = try Self.listeningSocket()
        let container = try Self.listeningSocket()
        defer { for socket in [inProfile, outside, container] { close(socket.fd) } }

        func service(_ id: String, _ cmd: [String], port: Int?) -> ServiceDefinition {
            ServiceDefinition(
                id: id, name: id, cmd: cmd, cwd: workDir.path,
                probe: port.map { ProbeConfig(type: .tcp, port: $0, host: nil, url: nil, pattern: nil, artifact: nil, timeout: 30) },
                type: .daemon, restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
            )
        }
        let stripeCmd = ["stripe", "listen", "--forward-to", "http://localhost:\(inProfile.port)/hook"]
        let services = [
            service("travel-portal", ["sleep", "1"], port: inProfile.port),
            service("partner-portal", ["sleep", "1"], port: outside.port),
            service("universal-login", ["sleep", "1"], port: container.port),
            service("stripe", stripeCmd, port: nil),
        ]

        let calls = PortToolCalls()
        let commands = [inProfile.port: "node", outside.port: "node", container.port: "OrbStack Helper"]
        supervisor.portTools = PortTools(
            listeners: { port in commands[port].map { [PortOwner.Listener(pid: pid_t(port), command: $0)] } ?? [] },
            kill: { calls.addKill($0) },
            killCommands: { calls.addPattern($0) }
        )

        // The booking profile: the partner portal is outside it.
        try supervisor.loadServices(services, profile: .booking)
        XCTAssertFalse(supervisor.isInProfile("partner-portal"))
        await supervisor.cleanupStaleProcesses()

        XCTAssertEqual(calls.kills, [pid_t(inProfile.port)], "only the listener of the profile's service")
        XCTAssertEqual(calls.patterns, [PortOwner.commandPattern(for: stripeCmd)])
        let lines = await logLines("universal-login")
        XCTAssertTrue(
            lines.contains("[travel-runner] Port \(container.port) is published by OrbStack Helper (a container). Not killed."),
            lines.joined(separator: "\n")
        )

        // The stop sweeps the same ports with the same rules.
        calls.reset()
        supervisor.health = .healthy
        supervisor.stopAll()
        let stopped = await waitUntil(10) { self.supervisor.health == .stopped }
        XCTAssertTrue(stopped)
        XCTAssertEqual(calls.kills, [pid_t(inProfile.port)])

        // A service that this session started stays in the sweep of the stop (and of
        // the quit) after a change of profile puts it outside. The container stays alive.
        calls.reset()
        XCTAssertEqual(supervisor.sweepPorts.sorted(), [inProfile.port, container.port].sorted())
        supervisor.serviceStates["partner-portal"]?.lastStarted = .now
        XCTAssertEqual(supervisor.sweepPorts.sorted(), [inProfile.port, outside.port, container.port].sorted())
        supervisor.health = .healthy
        supervisor.stopAll()
        let stoppedAgain = await waitUntil(10) { self.supervisor.health == .stopped }
        XCTAssertTrue(stoppedAgain)
        XCTAssertEqual(calls.kills.sorted(), [pid_t(inProfile.port), pid_t(outside.port)].sorted())
        // The next start still leaves it alone.
        calls.reset()
        await supervisor.cleanupStaleProcesses()
        XCTAssertEqual(calls.kills, [pid_t(inProfile.port)])

        // The port sweep of a wake (the LAN address changed) has the same rules: not
        // the partner portal outside the profile, and not the container.
        calls.reset()
        await supervisor.killWebServicePorts()
        XCTAssertEqual(calls.kills, [pid_t(inProfile.port)])

        // The partner profile: now the partner portal is in, and Stripe is out.
        calls.reset()
        try supervisor.loadServices(services, profile: .partner)
        await supervisor.cleanupStaleProcesses()
        XCTAssertEqual(calls.kills, [pid_t(outside.port)])
        XCTAssertEqual(calls.patterns, [], "Stripe is outside the profile")
        // Control for the wake sweep: in the profile, the partner portal is swept.
        calls.reset()
        await supervisor.killWebServicePorts()
        XCTAssertEqual(calls.kills, [pid_t(outside.port)])
    }

    /// A container publishes the port of a service. The runner does not kill the
    /// container runtime, and it does not start the service: it would fail with
    /// EADDRINUSE while its probe passes against the container.
    func testAServiceDoesNotStartOnAPortThatAContainerPublishes() async throws {
        let held = try Self.listeningSocket()
        defer { close(held.fd) }
        // Nothing accepts on this socket: room for each connection of the runner's port checks.
        XCTAssertEqual(listen(held.fd, 128), 0)
        port = held.port
        let calls = PortToolCalls()
        supervisor.portTools = PortTools(
            listeners: { _ in [PortOwner.Listener(pid: 1, command: "OrbStack Helper")] },
            kill: { calls.addKill($0) },
            killCommands: { calls.addPattern($0) }
        )
        try load(daemon("held", ["sh", "-c", "echo held-start; sleep 30"]))
        let started = Date()

        supervisor.restartService("held")

        let failed = await waitUntil(30) { self.state("held").phase == .failed && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(failed, "held is \(state("held").phase.rawValue)")
        // Nothing was killed, so the port cannot become free: the start does not wait 5 s for it.
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(
            supervisor.lastError,
            "held cannot start: port \(port) is published by a container (OrbStack Helper) — stop that container, then restart held"
        )
        let lines = await logLines("held")
        XCTAssertFalse(lines.contains("held-start"), "the process must not start")
        XCTAssertEqual(calls.kills, [])
        XCTAssertEqual(state("held").restartCount, 0)
    }

    /// A socket of the test that listens on a free loopback port.
    private static func listeningSocket() throws -> (fd: Int32, port: Int) {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard sock >= 0, bound == 0, listen(sock, 8) == 0 else {
            if sock >= 0 { close(sock) }
            throw POSIXError(.EADDRNOTAVAIL)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        return (sock, Int(UInt16(bigEndian: addr.sin_port)))
    }

    // MARK: - Start All with fakes

    /// A supervisor whose Start All reads no tool of this Mac, asks no other app,
    /// and opens no fixed port. `node --version` gives `node`.
    private func fakeTheOutsideOfStartAll(node: String = "v22.3.0\n") -> FakeCommandRunner {
        let shell = FakeCommandRunner { call in
            call.command == "node --version" ? FakeCommandRunner.ok(node) : FakeCommandRunner.ok()
        }
        supervisor.shell = shell
        supervisor.siblingActiveServices = { [] }
        supervisor.secretRegistryPorts = 0...0
        return shell
    }

    /// Start All needs only a loaded graph: no services.json.
    func testStartAllStartsALoadedGraph() async throws {
        let shell = fakeTheOutsideOfStartAll()
        try supervisor.loadServices([daemon("web", webServer)])

        supervisor.startAll()

        let healthy = await waitUntil(40) { self.supervisor.health == .healthy }
        XCTAssertTrue(healthy, "health is \(supervisor.health), error: \(supervisor.lastError ?? "none")")
        XCTAssertEqual(state("web").phase, .running)
        XCTAssertEqual(supervisor.currentPhase, .running)
        XCTAssertNil(supervisor.lastError)
        XCTAssertEqual(Self.listeners(on: port).count, 1)
        // The preflight ran, with the shell of the supervisor.
        XCTAssertTrue(supervisor.completedPhases.contains("PREFLIGHT"))
        XCTAssertEqual(
            supervisor.preflightChecks.map(\.id),
            ["docker", "node-version", "stripe-auth", "port-\(port)", "dir-\(workDir.lastPathComponent)"]
        )
        XCTAssertFalse(supervisor.preflightChecks.contains { $0.result.isFailed })
        XCTAssertTrue(shell.commands.contains("node --version"), "\(shell.commands)")
    }

    func testStartAllStartsNothingWhileTheOtherAppRunsAStack() async throws {
        let shell = fakeTheOutsideOfStartAll()
        supervisor.siblingActiveServices = { ["supabase", "travel-portal"] }
        try supervisor.loadServices([daemon("web", webServer)])

        supervisor.startAll()

        let refused = await waitUntil(10) { self.supervisor.health == .degraded }
        XCTAssertTrue(refused)
        XCTAssertEqual(supervisor.lastError, SiblingRunner.refusal(activeServices: ["supabase", "travel-portal"]))
        XCTAssertNil(state("web").lastStarted)
        XCTAssertTrue(supervisor.preflightChecks.isEmpty)
        XCTAssertEqual(shell.commands, [])
        XCTAssertEqual(Self.listeners(on: port), [])
    }

    func testAFailedPreflightStartsNothing() async throws {
        // `node --version` prints nothing: Node is not there.
        _ = fakeTheOutsideOfStartAll(node: "")
        try supervisor.loadServices([daemon("web", webServer)])

        supervisor.startAll()

        let failed = await waitUntil(10) { self.supervisor.health == .degraded }
        XCTAssertTrue(failed)
        XCTAssertEqual(supervisor.lastError, "Preflight failed — Node.js \u{2265} 22: Node.js not found")
        XCTAssertEqual(supervisor.currentPhase, .idle)
        XCTAssertNil(state("web").lastStarted)
        XCTAssertEqual(Self.listeners(on: port), [])
    }

    /// After the GROUND phase Start All asks the fake database. A database with
    /// tables is left alone.
    func testStartAllAsksTheDatabaseAfterGround() async throws {
        _ = fakeTheOutsideOfStartAll()
        var questions: [String] = []
        var resets = 0
        supervisor.databaseQuery = { cwd, sql in
            questions.append(cwd)
            return DbQueryResult(exitCode: 0, stdout: sql.contains("pg_tables") ? "42" : "", stderr: "")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }
        try supervisor.loadServices([daemon("supabase", webServer)])

        supervisor.startAll()

        let healthy = await waitUntil(40) { self.supervisor.health == .healthy }
        XCTAssertTrue(healthy, "health is \(supervisor.health), error: \(supervisor.lastError ?? "none")")
        XCTAssertTrue(supervisor.completedPhases.contains("GROUND"), "\(supervisor.completedPhases)")
        XCTAssertFalse(questions.isEmpty)
        XCTAssertEqual(Set(questions), [workDir.path])
        XCTAssertEqual(resets, 0)
    }

    // MARK: - DB setup with a pipeline from the test

    private func pipeline(_ steps: [DbSetupStep]) -> DbSetupPipeline {
        let scenario = DbSeedScenario(id: "test", name: "Test", description: "", fileSummary: "", variables: [])
        let pipeline = DbSetupPipeline(profile: "reset", seedScenario: scenario)
        pipeline.steps = steps
        return pipeline
    }

    private func step(_ id: String, _ command: String, healthCheck: String? = nil) -> DbSetupStep {
        DbSetupStep(
            id: id, name: id, command: command, healthCheckCommand: healthCheck,
            timeoutSeconds: 30, isOptional: false, stepNumber: 1
        )
    }

    /// The DB setup runs the pipeline that the test gives: no manifest, no seed
    /// scenario. The health check of a step runs in the shell of the supervisor.
    func testADbSetupRunsThePipelineOfTheFactory() async throws {
        try loadSupabase()
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "", stderr: "") }
        let steps = [
            step("first", "echo first-ran", healthCheck: "check-first"),
            step("second", "echo second-ran; exit 3"),
            step("third", "echo third-ran"),
        ]
        var asked: [[String]] = []
        supervisor.dbPipelineFactory = { cwd, profile in
            asked.append([cwd, profile])
            return self.pipeline(steps)
        }

        supervisor.runDbSetup(profile: "full")

        XCTAssertTrue(supervisor.dbResetRunning)
        let done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)
        XCTAssertEqual(asked, [[workDir.path, "full"]])
        XCTAssertEqual(steps.map(\.status), [.passed, .failed, .pending])
        // The step runs in a real login shell, and a profile can print lines of its own.
        XCTAssertTrue(steps[0].logEntries.map(\.text).contains("first-ran"), "\(steps[0].logEntries.map(\.text))")
        XCTAssertEqual(shell.calls.filter { $0.command == "check-first" }.map(\.cwd), [workDir.path])
        let error = try XCTUnwrap(supervisor.lastError)
        XCTAssertTrue(error.hasPrefix("DB setup failed at second: "), error)
    }

    /// A factory that gives no pipeline starts nothing, like a missing seed scenario.
    func testADbSetupWithoutAPipelineStartsNothing() async throws {
        try loadSupabase()
        supervisor.dbPipelineFactory = { _, _ in nil }

        supervisor.runDbSetup()

        XCTAssertFalse(supervisor.dbResetRunning)
        XCTAssertNil(supervisor.dbSetupPipeline)
        XCTAssertEqual(supervisor.lastError, "No DB setup pipeline for the profile reset.")
    }

    // MARK: - Time from the clock of the test

    /// The wait for a late database with the times of the app (2 s between
    /// questions, 60 s in all) takes no real time with the clock of the test.
    func testTheWaitForALateDatabaseUsesTheClockOfTheSupervisor() async throws {
        try loadSupabase()
        let time = FakeClock()
        supervisor.clock = time.clock
        var queries = 0
        var resets = 0
        supervisor.databaseQuery = { _, _ in
            queries += 1
            return DbQueryResult(exitCode: 1, stdout: "", stderr: "No such container: x")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }

        let began = Date()
        let didReset = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)

        XCTAssertFalse(didReset)
        XCTAssertEqual(time.sleeps, Array(repeating: .seconds(2), count: 30))
        XCTAssertEqual(queries, 31)
        XCTAssertEqual(resets, 0)
        XCTAssertLessThan(Date().timeIntervalSince(began), 10)
        XCTAssertEqual(
            supervisor.lastError,
            "Could not read the local database (No such container: x). Nothing was changed."
        )
    }

    /// The time stamps of a service come from the same clock.
    func testAStartStampsTheServiceWithTheClockOfTheSupervisor() async throws {
        let time = FakeClock()
        // Only the time stamps: the waits of a real process stay real.
        supervisor.clock = time.stampsOnly
        try load(daemon("web", webServer))

        supervisor.restartService("web")

        let ready = await waitUntil(40) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        XCTAssertEqual(state("web").lastStarted, time.now)
        XCTAssertEqual(state("web").readyAt, time.now)
    }

    // MARK: - Reconfigure

    /// A config for the supervisor, with nothing of this Mac behind it: no
    /// services.json, no control port 19900, no tickets folder and no other app.
    /// The services have no folder, so no watcher starts.
    private func fakeConfigHost(services ids: [String]) -> ConfigLoads {
        let loads = ConfigLoads()
        loads.serviceIDs = ids
        let issues = workDir.appendingPathComponent("issues").path
        supervisor.configHost = EnvironmentSupervisor.ConfigHost(
            load: {
                loads.count += 1
                if let error = loads.error { throw error }
                let services = loads.serviceIDs.map { id in
                    ServiceDefinition(
                        id: id, name: nil, cmd: ["sleep", "30"], cwd: nil, probe: nil, type: .daemon,
                        restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
                    )
                }
                return ServiceConfig(
                    version: ConfigLoader.currentVersion, registryPortRange: [0, 0], services: services,
                    paths: nil, profile: .full
                )
            },
            controlServer: {
                let server = ControlServer(port: 0)
                loads.controlServers.append(server)
                return server
            },
            siblingServices: { [] }
        )
        supervisor.makeIssueTracker = { DebugTracker(baseDir: issues) }
        return loads
    }

    /// Findings "Reconfigure while running loses state": a config load made new
    /// service states, and the runner forgot the processes that ran.
    func testReconfigureWhileAServiceRunsChangesNothingAndKeepsThePid() async throws {
        try load(daemon("web", webServer))
        supervisor.restartService("web")
        let ready = await waitUntil(40) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        let before = state("web")
        let pid = try XCTUnwrap(before.pid)
        let loads = fakeConfigHost(services: ["other"])

        let result = await supervisor.reconfigure()

        XCTAssertEqual(result, .needsStop)
        XCTAssertEqual(loads.count, 0, "the new config is not read while the stack runs")
        XCTAssertTrue(state("web") === before)
        XCTAssertEqual(state("web").pid, pid)
        XCTAssertEqual(state("web").phase, .running)
        XCTAssertEqual(Self.listeners(on: port), [pid])
        XCTAssertNil(supervisor.serviceStates["other"])
        XCTAssertTrue(supervisor.reconfigurePending)
        XCTAssertTrue(loads.controlServers.isEmpty)
    }

    /// "Stop and apply": the stop ends first, then the new config loads.
    func testStopAndApplyStopsTheStackThenLoadsTheNewConfig() async throws {
        try load(daemon("web", webServer))
        supervisor.restartService("web")
        let ready = await waitUntil(40) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        let loads = fakeConfigHost(services: ["other"])
        var feedback: [String] = []
        supervisor.onActionFeedback = { message, _ in feedback.append(message) }
        let needsStop = await supervisor.reconfigure()
        XCTAssertEqual(needsStop, .needsStop)

        let result = await supervisor.stopAndReconfigure().value

        XCTAssertEqual(result, .applied)
        XCTAssertEqual(loads.count, 1)
        XCTAssertEqual(Self.listeners(on: port), [], "the old process is gone before the new config loads")
        XCTAssertEqual(supervisor.sortedServiceIDs, ["other"])
        XCTAssertEqual(Array(supervisor.serviceStates.keys), ["other"])
        XCTAssertNil(state("other").pid)
        XCTAssertEqual(supervisor.health, .stopped)
        XCTAssertFalse(supervisor.reconfigurePending)
        XCTAssertEqual(feedback, ["Paths updated"])
        await loads.stopControlServers()
    }

    /// Findings "Reconfigure saves but does not reload": with the stack stopped the
    /// new config loads at once. And the app keeps one control server: a second
    /// one cannot bind the port.
    func testReconfigureOfAStoppedStackLoadsTheConfigAndKeepsOneControlServer() async throws {
        let loads = fakeConfigHost(services: ["first"])
        var feedback: [String] = []
        supervisor.onActionFeedback = { message, _ in feedback.append(message) }

        supervisor.loadConfig()
        XCTAssertEqual(supervisor.sortedServiceIDs, ["first"])
        XCTAssertEqual(loads.controlServers.count, 1)
        XCTAssertEqual(feedback, [])

        loads.serviceIDs = ["second"]
        let result = await supervisor.reconfigure()

        XCTAssertEqual(result, .applied)
        XCTAssertEqual(supervisor.sortedServiceIDs, ["second"])
        XCTAssertEqual(Array(supervisor.serviceStates.keys), ["second"])
        XCTAssertEqual(feedback, ["Paths updated"])
        XCTAssertNil(supervisor.lastError)

        supervisor.loadConfig()
        XCTAssertEqual(loads.controlServers.count, 1, "one control server for the life of the app")

        // The one server listens.
        let server = try XCTUnwrap(loads.controlServers.first)
        var bound: UInt16?
        for _ in 0..<100 where bound == nil {
            bound = await server.boundPort
            if bound == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertNotNil(bound)
        XCTAssertNil(supervisor.controlAPIError)
        await loads.stopControlServers()
    }

    /// A first run has no services.json. The control API still listens, says so,
    /// and its preflight answers: the release smoke test asks exactly this.
    func testWithoutAConfigTheControlAPIAnswersAndSaysNotConfigured() async throws {
        let loads = fakeConfigHost(services: ["first"])
        loads.error = ConfigLoader.ConfigError.noConfig
        // A Mac without Node: the shell finds no `node`.
        let shell = FakeCommandRunner { call in
            call.command == "node --version" ? FakeCommandRunner.failed(127, stderr: "command not found: node") : FakeCommandRunner.ok()
        }
        supervisor.shell = shell

        supervisor.loadConfig()

        XCTAssertNil(supervisor.lastError, "a first run is no error")
        XCTAssertEqual(loads.controlServers.count, 1)
        let server = try XCTUnwrap(loads.controlServers.first)
        var bound: UInt16?
        for _ in 0..<100 where bound == nil {
            bound = await server.boundPort
            if bound == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let port = try XCTUnwrap(bound)
        func get(_ path: String) async throws -> [String: Any] {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let (data, _) = try await session.data(from: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        let status = try await get("/api/status")
        XCTAssertEqual(status["configured"] as? Bool, false)
        XCTAssertEqual(status["health"] as? String, HealthStatus.stopped.rawValue)
        let preflight = try await get("/api/preflight")
        XCTAssertEqual(preflight["configured"] as? Bool, false)
        let checks = try XCTUnwrap(preflight["checks"] as? [[String: String]])
        XCTAssertEqual(checks.map { $0["id"] }, ["node-version"], "only checks that change nothing, and no service has a port yet")
        XCTAssertEqual(checks.first?["status"], "failed")
        XCTAssertEqual(checks.first?["detail"], "Node.js not found")
        XCTAssertEqual(shell.commands, ["node --version"], "no container runtime and no Stripe is asked")

        // The setup saved a config: the same server now says so.
        loads.error = nil
        let result = await supervisor.reconfigure()
        XCTAssertEqual(result, .applied)
        let configured = try await get("/api/status")
        XCTAssertEqual(configured["configured"] as? Bool, true)
        XCTAssertEqual(loads.controlServers.count, 1)
        await loads.stopControlServers()
    }

    func testAConfigThatDoesNotLoadKeepsTheOldOne() async throws {
        let loads = fakeConfigHost(services: ["first"])
        supervisor.loadConfig()
        let before = state("first")
        var feedback: [(String, Bool)] = []
        supervisor.onActionFeedback = { message, ok in feedback.append((message, ok)) }
        loads.error = ConfigLoader.ConfigError.monorepoNotFound

        let result = await supervisor.reconfigure()

        let message = "Paths not applied: \(ConfigLoader.ConfigError.monorepoNotFound)"
        XCTAssertEqual(result, .failed(message))
        XCTAssertTrue(state("first") === before)
        XCTAssertEqual(supervisor.sortedServiceIDs, ["first"])
        XCTAssertEqual(supervisor.lastError, message)
        XCTAssertEqual(feedback.map(\.0), [message])
        XCTAssertEqual(feedback.map(\.1), [false])
        await loads.stopControlServers()
    }
}

/// What the supervisor asked of the fake config host.
@MainActor
private final class ConfigLoads {
    var count = 0
    /// The services of the config that the next load gives.
    var serviceIDs: [String] = []
    var error: (any Error)?
    var controlServers: [ControlServer] = []

    /// The listen runs in a task of the supervisor; it ends before the stop.
    func stopControlServers() async {
        for server in controlServers {
            for _ in 0..<100 {
                if await server.boundPort != nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            await server.stop()
        }
    }
}

/// What the fake port tools were asked to kill.
private final class PortToolCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var killed: [pid_t] = []
    private var killedPatterns: [String] = []

    var kills: [pid_t] { lock.withLock { killed } }
    var patterns: [String] { lock.withLock { killedPatterns } }
    func addKill(_ pid: pid_t) { lock.withLock { killed.append(pid) } }
    func addPattern(_ pattern: String) { lock.withLock { killedPatterns.append(pattern) } }
    func reset() { lock.withLock { killed = []; killedPatterns = [] } }
}

/// The PATH question of the supervisor's shell, which a test holds open.
private struct HeldPathQuestion {
    let shell: FakeCommandRunner
    let gate: Gate

    /// How often the shell was asked where a tool is.
    var calls: Int { shell.commands.filter { $0.contains("command -v") }.count }
}
