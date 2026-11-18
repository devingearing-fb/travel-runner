import Foundation
import os
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
        // deps.json of a test is in its own folder, never in ~/.config.
        supervisor.dependencyRecord = DependencyRecord(path: workDir.appendingPathComponent("config/deps.json").path)
        // The diagnostics of an issue read no tool of this Mac.
        supervisor.diagnosticsTools = { _ in [] }
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
    nonisolated static func process(_ pid: pid_t, runsIn directory: String) -> Bool {
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

    private nonisolated static func listeners(on port: Int) -> [pid_t] {
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

    /// The process of this test that listens on the test's port. A test signals
    /// only this one: a stranger can take the port after `freePort()` released it.
    private func ownListener() throws -> pid_t {
        try XCTUnwrap(
            Self.listeners(on: port).first { Self.process($0, runsIn: workDir.lastPathComponent) },
            "no process of this test listens on the port"
        )
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
        let before = try ownListener()

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
        let before = try ownListener()

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

    /// An update installs by itself only when the restart interrupts nothing: a
    /// running service, the open window or a database reset keep the app running.
    func testAnUpdateRestartWaitsForAStoppedStackAndAClosedWindow() async throws {
        try load(daemon("web", webServer))
        supervisor.restartService("web")
        let ready = await waitUntil(30) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        let running = await supervisor.updateRestartState(panelOpen: false)
        XCTAssertTrue(running.stackRunning)
        XCTAssertFalse(UpdatePolicy.mayRestartUnattended(running, isDev: false))

        supervisor.stopAll()
        let down = await waitUntil(10) { self.supervisor.health == .stopped }
        XCTAssertTrue(down)
        let stopped = await supervisor.updateRestartState(panelOpen: false)
        XCTAssertEqual(stopped, UpdatePolicy.RestartState())
        XCTAssertTrue(UpdatePolicy.mayRestartUnattended(stopped, isDev: false))

        let open = await supervisor.updateRestartState(panelOpen: true)
        XCTAssertFalse(UpdatePolicy.mayRestartUnattended(open, isDev: false))

        supervisor.dbResetRunning = true
        let resetting = await supervisor.updateRestartState(panelOpen: false)
        supervisor.dbResetRunning = false
        XCTAssertTrue(resetting.databaseBusy)
        XCTAssertFalse(UpdatePolicy.mayRestartUnattended(resetting, isDev: false))
    }

    /// A fix of the setup checks keeps the app running until it ends. A count that
    /// never went down would block the restart for good.
    func testAnUpdateRestartWaitsForAFixToEnd() async throws {
        let gate = Gate()
        let runner = FakeCommandRunner { call in
            if call.command.contains(StripeLauncher.installCommand) { await gate.wait() }
            return FakeCommandRunner.ok()
        }
        let checker = EnvironmentChecker(
            monorepoPath: workDir.path, loginPath: "/nonexistent/login", streamServicesPath: "/nonexistent/stream",
            flavor: .standard, shell: runner, tools: ToolEnvironment(home: workDir.path)
        )
        checker.buildChecks()
        let idle = await supervisor.updateRestartState(panelOpen: false)
        XCTAssertFalse(idle.fixRunning, "no fix runs yet")

        let fix = Task { await checker.fix("stripe-cli") }
        let held = await waitUntil(5) { self.supervisor.updateRestartStateNow(panelOpen: false).fixRunning }
        XCTAssertTrue(held, "the fix runs")
        XCTAssertFalse(UpdatePolicy.mayRestartUnattended(supervisor.updateRestartStateNow(panelOpen: false), isDev: false))

        await gate.open()
        await fix.value
        let after = await supervisor.updateRestartState(panelOpen: false)
        XCTAssertFalse(after.fixRunning, "the count goes down when the fix ends")
    }

    /// "Stop and apply" keeps the app running until the new paths are applied.
    func testAnUpdateRestartWaitsForStopAndApplyToEnd() async throws {
        try load(daemon("web", webServer))
        supervisor.restartService("web")
        let ready = await waitUntil(40) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        let loads = fakeConfigHost(services: ["other"])
        XCTAssertFalse(supervisor.updateRestartStateNow(panelOpen: false).reconfigureRunning)

        let task = supervisor.stopAndReconfigure()
        XCTAssertTrue(supervisor.updateRestartStateNow(panelOpen: false).reconfigureRunning, "set before the stop ends")
        let result = await task.value

        XCTAssertEqual(result, .applied)
        let after = await supervisor.updateRestartState(panelOpen: false)
        XCTAssertFalse(after.reconfigureRunning, "the count goes down when the apply ends")
        XCTAssertEqual(after, UpdatePolicy.RestartState())
        await loads.stopControlServers()
    }

    /// A check through `/api/preflight` keeps the app running until it answers.
    func testAnUpdateRestartWaitsForAPreflightRequest() async throws {
        let gate = Gate()
        supervisor.shell = FakeCommandRunner { _ in
            await gate.wait()
            return FakeCommandRunner.ok("v22.0.0")
        }
        XCTAssertFalse(supervisor.updateRestartStateNow(panelOpen: false).otherWorkRunning)

        let request = Task { await self.supervisor.preflightJSON() }
        let held = await waitUntil(5) { self.supervisor.updateRestartStateNow(panelOpen: false).otherWorkRunning }
        XCTAssertTrue(held, "the preflight runs")

        await gate.open()
        _ = await request.value
        XCTAssertFalse(supervisor.updateRestartStateNow(panelOpen: false).otherWorkRunning)
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

        // The runner's own line names the file too; it is not an attempt.
        let attempts = await logLines("ghost")
            .filter { $0.contains("no-such-script.sh") && !$0.hasPrefix("[travel-runner]") }.count
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(state("ghost").restartCount, 0)
        XCTAssertEqual(state("ghost").phase, .failed)
        let expected = "ghost cannot start: this branch has no file `./no-such-script.sh` in \(workDir.path). "
            + "Switch branch or pull, then restart ghost."
        let said = await waitUntil(10) { self.supervisor.lastError == expected }
        XCTAssertTrue(said, supervisor.lastError ?? "nil")
    }

    /// Exit 127 for a tool of the packages (`./node_modules/.bin/next`): the row
    /// says that the packages are not installed and offers the install.
    func testExit127ForAToolOfThePackagesOffersTheInstall() async throws {
        try #"{"name":"web","scripts":{"dev":"next dev"}}"#.write(
            to: workDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8
        )
        try load(daemon("web", ["./node_modules/.bin/next", "dev"]))

        supervisor.restartService("web")

        let expected = "web cannot start: its packages are not installed in \(workDir.path)."
        let said = await waitUntil(20) {
            self.state("web").phase == .failed && self.state("web").condition?.headline == expected
        }
        XCTAssertTrue(said, state("web").condition?.headline ?? "no condition")
        XCTAssertEqual(state("web").condition?.actions, [.installDependencies, .openLog])
        XCTAssertEqual(state("web").restartCount, 0)
        XCTAssertTrue(supervisor.canPerform(.installDependencies, for: "web"))
    }

    /// pnpm ends with 1, not 127, when `node_modules` is missing, so the service
    /// restarts until the breaker trips. The halted row still offers the install,
    /// and the banner says what is missing.
    func testAPnpmRunWithoutPackagesThatTripsTheBreakerOffersTheInstall() async throws {
        // A fake pnpm that says what the real one says without node_modules.
        let bin = workDir.appendingPathComponent("fake bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let pnpm = bin.appendingPathComponent("pnpm")
        try "#!/bin/sh\necho ' WARN   Local package.json exists, but node_modules missing, did you mean to install?' >&2\nexit 1\n"
            .write(to: pnpm, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pnpm.path)
        try #"{"name":"web","scripts":{"dev":"next dev"}}"#.write(
            to: workDir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8
        )
        let shell = FakeCommandRunner { _ in
            FakeCommandRunner.ok("__TR_ENV_START__\nPATH=\(bin.path):/usr/bin:/bin\n__TR_ENV_END__\n")
        }
        let tools = ToolEnvironment(home: workDir.appendingPathComponent("home").path)
        await tools.resolve(runner: shell)
        try makeSupervisor(tools: tools)
        try load(daemon("web", ["pnpm", "dev"], probeTimeout: 60))

        supervisor.restartService("web")

        let expected = "web cannot start: its packages are not installed in \(workDir.path)."
        let halted = await waitUntil(40) {
            self.state("web").isCircuitBroken && self.state("web").condition?.kind == .halted(reason: "crash loop")
        }
        XCTAssertTrue(halted, state("web").condition?.text ?? "no condition")
        XCTAssertEqual(state("web").exitCode, 1)
        let condition = try XCTUnwrap(state("web").condition)
        XCTAssertEqual(condition.detail, "Cause: \(expected)")
        XCTAssertEqual(condition.actions, [.installDependencies, .openLog, .restart])
        let said = await waitUntil(10) { self.supervisor.lastError == expected }
        XCTAssertTrue(said, supervisor.lastError ?? "nil")
    }

    /// Exit 126: the file exists but has no execute bit. The row names the file.
    func testExit126NamesTheFileThatIsNotExecutable() async throws {
        let script = workDir.appendingPathComponent("run.sh")
        try "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: script.path)
        try load(daemon("plain", ["./run.sh"]))

        supervisor.restartService("plain")

        let said = await waitUntil(20) {
            self.state("plain").phase == .failed
                && self.state("plain").condition?.headline.hasSuffix("is not executable (exit 126).") == true
        }
        XCTAssertTrue(said, state("plain").condition?.headline ?? "no condition")
        XCTAssertEqual(state("plain").exitCode, 126)
        XCTAssertTrue(state("plain").condition?.headline.contains("run.sh") == true)
        XCTAssertEqual(state("plain").restartCount, 0)
    }

    /// Exit 127 for a tool, not a script: the error names the tool and the PATH
    /// that the runner searched.
    func testAMissingToolNamesThePathThatWasSearched() async throws {
        let tool = "tr-no-such-tool-\(UUID().uuidString)"
        try load(daemon("toolless", [tool, "dev"]))

        supervisor.restartService("toolless")

        let expected = "toolless cannot start: `\(tool)` is not on \(Flavor.current.displayName)'s PATH. It looked in: "
        let named = await waitUntil(30) {
            self.state("toolless").phase == .failed && self.supervisor.lastError?.hasPrefix(expected) == true
        }
        XCTAssertTrue(named, supervisor.lastError ?? "nil")
        XCTAssertTrue(supervisor.lastError?.contains("/usr/bin") == true, supervisor.lastError ?? "nil")
        XCTAssertTrue(
            supervisor.lastError?.hasSuffix("Open Health to see where each tool was found.") == true,
            supervisor.lastError ?? "nil"
        )
        XCTAssertEqual(state("toolless").restartCount, 0)
        let offered = await waitUntil(10) { self.state("toolless").condition?.actions == [.openHealth, .openLog] }
        XCTAssertTrue(offered, "\(state("toolless").condition?.actions ?? [])")
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
            CommandDiagnosis.message(.toolMissing(tool: tool, searchedPath: "/fake/bin"), name: "toolless")
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

    /// Findings "SIGKILL after 2 s cuts cleanup" and "2 s grace kills Sequin
    /// teardown": Stop All waits for a cleanup of three seconds on SIGTERM, then
    /// runs the stop verb, and sweeps the port last. The listener runs outside the service's
    /// process tree, as a container's port does, so only the sweep stops it.
    func testStopAllRunsTheStopVerbAndTheCleanupBeforeThePortSweep() async throws {
        let order = workDir.appendingPathComponent("order")
        let orderPath = ShellQuote.quote(order.path)
        let ownedDirectory = workDir.lastPathComponent
        supervisor.portTools = PortTools(
            listeners: PortTools.live.listeners,
            kill: { pid in
                guard Self.process(pid, runsIn: ownedDirectory) else { return }
                if let handle = try? FileHandle(forWritingTo: order) {
                    handle.seekToEndOfFile()
                    handle.write(Data("sweep\n".utf8))
                    try? handle.close()
                }
                PortTools.live.kill(pid)
            },
            killCommands: { _ in }
        )
        let script = "(\(webServer.joined(separator: " ")) > /dev/null 2>&1 &); "
            + "trap 'sleep 3; echo cleanup >> \(orderPath); exit 0' TERM; while true; do sleep 1; done"
        var service = daemon("sequin", ["sh", "-c", script])
        service.stopCmd = ["sh", "-c", "echo verb >> \(orderPath)"]
        service.stopNote = "Sequin (compose down)"
        try load(service)

        supervisor.restartService("sequin")
        let started = await waitUntil(30) { self.settled("sequin") }
        XCTAssertTrue(started, "sequin is \(state("sequin").phase.rawValue)")

        supervisor.stopAll()
        let stopping = await waitUntil(5) { self.state("sequin").phase == .stopping }
        XCTAssertTrue(stopping)
        XCTAssertEqual(state("sequin").definition.stoppingText, "Stopping Sequin (compose down)…")
        let stopped = await waitUntil(20) { self.supervisor.health == .stopped }
        XCTAssertTrue(stopped)

        let lines = ((try? String(contentsOf: order, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["cleanup", "verb", "sweep"])
        XCTAssertTrue(Self.listeners(on: port).filter { Self.process($0, runsIn: ownedDirectory) }.isEmpty)
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
    /// one of the first launch and the one of the automatic restart. Only the
    /// restart's waiter gives a verdict (L1): one issue, about the process that runs now.
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
        // The restart's waiter files the issue; the first launch's waiter files nothing.
        func probeTimeouts() async -> [DebugTracker.Issue] {
            await supervisor.listDebugIssues().filter { $0.trigger == "probe_timeout" }
        }
        let deadline = Date().addingTimeInterval(40)
        while await probeTimeouts().isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        // A second capture, or a second issue, would come soon after.
        try await Task.sleep(for: .seconds(3))

        let found = await probeTimeouts()
        XCTAssertEqual(found.count, 1, "\(found.map(\.errorMessage))")
        XCTAssertEqual(found.first?.errorMessage, "flaky did not pass its startup probe in 10s (process alive: yes)")
        XCTAssertEqual(found.first?.recurrenceCount, 0, "the old waiter gives no verdict")
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

    /// A service whose folder services.json does not set has the cwd "". Started on
    /// its own, it must not run in the app's own folder.
    func testAServiceWithNoFolderFailsWithAMessageAndStartsNothing() async throws {
        try load(ServiceDefinition(
            id: "custom", name: "Custom", cmd: ["sh", "-c", "echo custom-start; sleep 30"], cwd: "",
            probe: nil, type: .daemon, restart: .onFailure, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        ))

        supervisor.restartService("custom")

        let failed = await waitUntil(20) {
            self.state("custom").phase == .failed && self.supervisor.actionsInFlight.isEmpty
        }
        XCTAssertTrue(failed, "custom is \(state("custom").phase.rawValue)")
        XCTAssertEqual(supervisor.lastError, "Custom cannot start: no folder is set — open Settings → Reconfigure Repos")
        let lines = await logLines("custom")
        XCTAssertFalse(lines.contains("custom-start"), "the process must not start")
        XCTAssertNil(state("custom").pid)
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

    /// The database has tables and lacks a migration, and the opt-in setting resets
    /// it. A stop that arrives while the runner reads the applied migrations must not
    /// start the reset.
    func testAStopWhileTheMigrationsAreReadDoesNotStartAReset() async throws {
        try loadSupabase()
        supervisor.autoResetOnMigrations = true
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

    // MARK: - Reset policy and Apply migrations (D1)

    /// A checkout whose backend baseline has one migration, with the manifest
    /// profiles `profiles`. The database answers with tables and `applied`.
    private func checkoutLackingAMigration(
        profiles: [String] = ["reset", "migrate"], builtFrom: String? = nil
    ) throws -> (queries: () -> [String], resets: () -> Int) {
        let migrations = workDir.appendingPathComponent(".backend-baseline/supabase/migrations")
        try FileManager.default.createDirectory(at: migrations, withIntermediateDirectories: true)
        try Data().write(to: migrations.appendingPathComponent("20260101000000_base.sql"))
        let folder = workDir.appendingPathComponent("scripts/db")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let profileJSON = profiles.map { "\"\($0)\":[\"verify-data\"]" }.joined(separator: ",")
        try Data(#"{"version":4,"steps":[{"id":"verify-data","command":"true"}],"profiles":{\#(profileJSON)}}"#.utf8)
            .write(to: folder.appendingPathComponent("manifest.json"))
        supervisor.shell = FakeCommandRunner { call in
            call.command.contains("rev-parse") ? FakeCommandRunner.ok("abc1234\n") : FakeCommandRunner.ok()
        }
        supervisor.databaseProbeRetry = (.milliseconds(10), .zero)
        var queries: [String] = []
        var resets = 0
        supervisor.databaseQuery = { _, sql in
            queries.append(sql)
            if sql.contains("pg_tables") { return DbQueryResult(exitCode: 0, stdout: "42", stderr: "") }
            if sql.contains("seed_state") {
                guard let builtFrom else { return DbQueryResult(exitCode: 1, stdout: "", stderr: "relation does not exist") }
                return DbQueryResult(exitCode: 0, stdout: builtFrom, stderr: "")
            }
            // Applied: only versions the checkout does not know about are absent.
            return DbQueryResult(exitCode: 0, stdout: "", stderr: "")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }
        return ({ queries }, { resets })
    }

    /// Findings "automatic reset destroys data silently" and "Start and branch switch
    /// reset the DB unprompted": a database with data that lacks a migration is not
    /// reset. The banner asks, with Apply migrations.
    func testMissingMigrationsShowTheBannerAndNeverResetByThemselves() async throws {
        try loadSupabase()
        let fake = try checkoutLackingAMigration()

        let didReset = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)
        await supervisor.refreshPendingMigrations(cwd: workDir.path)

        XCTAssertFalse(didReset)
        XCTAssertEqual(fake.resets(), 0)
        XCTAssertNil(supervisor.lastError)
        XCTAssertEqual(supervisor.pendingMigrations, ["20260101000000"])
        let notice = try XCTUnwrap(supervisor.migrationNotice)
        let baseline = (workDir.appendingPathComponent(".backend-baseline").path as NSString).abbreviatingWithTildeInPath
        XCTAssertEqual(notice.headline, "Local database is missing 1 migration (from \(baseline) @ abc1234)")
        XCTAssertTrue(notice.offersApply)
        XCTAssertTrue(supervisor.migrationsBannerVisible)

        // The same database with the opt-in setting on is reset.
        supervisor.autoResetOnMigrations = true
        let optIn = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)
        XCTAssertTrue(optIn)
        XCTAssertEqual(fake.resets(), 1)
    }

    /// The opt-in setting never replaces the data of another checkout. The banner
    /// says who built the database.
    func testTheSettingDoesNotResetADatabaseThatAnotherCheckoutBuilt() async throws {
        try loadSupabase()
        let fake = try checkoutLackingAMigration(
            builtFrom: #"{"scenario_id":"standard","checkout_path":"/elsewhere/fb-travel-monolith-hackathon","branch":"main"}"#
        )
        supervisor.autoResetOnMigrations = true

        let didReset = await supervisor.resetDatabaseIfNeeded(cwd: workDir.path, checkMigrations: true)
        await supervisor.refreshPendingMigrations(cwd: workDir.path)

        XCTAssertFalse(didReset)
        XCTAssertEqual(fake.resets(), 0)
        let notice = try XCTUnwrap(supervisor.migrationNotice)
        let other = "This database was last built from /elsewhere/fb-travel-monolith-hackathon (main). "
            + "Resetting replaces it for every checkout that shares project `\(workDir.lastPathComponent)`."
        XCTAssertEqual(notice.detail, other)
        XCTAssertTrue(notice.resetConfirmation.hasSuffix(other), notice.resetConfirmation)
    }

    /// The manifest of an older branch has no `migrate` profile. The loader would run
    /// `reset` in its place, so Apply refuses and the banner hides its button.
    func testApplyMigrationsWithoutAMigrateProfileChangesNothing() async throws {
        try loadSupabase()
        let fake = try checkoutLackingAMigration(profiles: ["reset"])
        supervisor.dbResetAction = nil

        supervisor.applyMigrations()

        XCTAssertNil(supervisor.dbSetupPipeline)
        XCTAssertFalse(supervisor.dbResetRunning)
        XCTAssertEqual(supervisor.lastError, DbResetPolicy.noMigrateProfileText)
        await supervisor.refreshPendingMigrations(cwd: workDir.path)
        XCTAssertEqual(supervisor.migrationNotice?.offersApply, false)
        XCTAssertFalse(fake.queries().isEmpty)
    }

    /// "Apply migrations" runs the `migrate` profile. A failed apply keeps the
    /// script's message, files an issue, and resets nothing; the banner stays.
    func testAFailedApplyIsReportedAndNothingResets() async throws {
        let tracker = captureIssues()
        try loadSupabase()
        _ = try checkoutLackingAMigration()
        supervisor.dbResetAction = nil
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        let failure = "Migration 20260101000000_base.sql could not be applied on top of your data. Reset and reseed to continue."
        var profiles: [String] = []
        var command = "echo '##db:status:failed:\(failure)'; exit 1"
        supervisor.dbPipelineFactory = { _, profile in
            profiles.append(profile)
            return self.pipeline([self.step("apply-migrations", command)], profile: profile)
        }

        supervisor.applyMigrations()
        let done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)

        XCTAssertEqual(profiles, ["migrate"])
        XCTAssertEqual(supervisor.lastError, "DB setup failed at apply-migrations: \(failure)")
        XCTAssertEqual(supervisor.migrationApplyError, failure)
        XCTAssertNil(supervisor.migrationsAppliedNotice)
        XCTAssertNotNil(supervisor.migrationNotice, "the banner with Reset and reseed stays")
        let issues = await tracker.listOpenIssues()
        XCTAssertEqual(issues.count, 1)
        let resets = await events("db_reset", in: tracker)
        XCTAssertEqual(resets.map(\.message), ["origin: apply-migrations, profile: migrate"])

        // Control: an apply that passes shows the note and clears the error.
        command = "echo '##db:status:done'"
        supervisor.applyMigrations()
        let passed = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(passed)
        XCTAssertEqual(profiles, ["migrate", "migrate"])
        XCTAssertNil(supervisor.lastError)
        XCTAssertNil(supervisor.migrationApplyError)
        XCTAssertEqual(supervisor.migrationsAppliedNotice, DbResetPolicy.appliedText)
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

    /// A kill from outside says so, also when the log of the launch has a line with
    /// a fix of its own (a page that did not compile while the server ran).
    func testAnOutsideKillSaysSoWhateverTheLogSays() async throws {
        let line = "Module not found: Can't resolve './x'"
        try load(ServiceDefinition(
            id: "web", name: "Web App", cmd: ["sh", "-c", "echo \"\(line)\"; exec \(webServer.joined(separator: " "))"],
            cwd: workDir.path,
            probe: ProbeConfig(type: .tcp, port: port, host: nil, url: nil, pattern: nil, artifact: nil, timeout: 30),
            type: .daemon, restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        ))
        supervisor.restartService("web")
        let ready = await waitUntil(30) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        let lines = await logLines("web")
        XCTAssertTrue(lines.contains(line), lines.joined(separator: "\n"))
        let pid = try ownListener()

        kill(pid, SIGTERM)

        let said = await waitUntil(10) { self.state("web").phase == .failed && self.state("web").condition != nil }
        XCTAssertTrue(said, "web is \(state("web").phase.rawValue)")
        let condition = try XCTUnwrap(state("web").condition)
        XCTAssertEqual(condition.headline, "Web App was stopped from outside Travel Runner (SIGTERM).")
        XCTAssertEqual(condition.actions, [.restart, .openLog])
    }

    /// Kills from outside until the breaker trips: the reason is the crash loop. The
    /// kill records its reason first, and the breaker's reason replaces it.
    func testOutsideKillsThatTripTheBreakerSayItStoppedRetrying() async throws {
        try load(daemon("web", webServer))
        supervisor.restartService("web")
        var last: pid_t = 0
        for kill in 1...AutoRestart.failuresToTrip {
            let up = await waitUntil(40) {
                self.settled("web") && Self.listeners(on: self.port).first.map { $0 != last } == true
            }
            XCTAssertTrue(up, "kill \(kill): web is \(state("web").phase.rawValue)")
            last = try ownListener()
            Darwin.kill(last, SIGTERM)
        }

        let tripped = await waitUntil(20) {
            self.state("web").isCircuitBroken && self.state("web").condition?.kind == .halted(reason: "crash loop")
        }
        XCTAssertTrue(tripped, "web: \(state("web").condition?.text ?? "no condition")")
        // A late record of the last kill does not replace it.
        try await Task.sleep(for: .seconds(1))
        let condition = try XCTUnwrap(state("web").condition)
        XCTAssertEqual(condition.text, "Stopped retrying after 3 crashes in a minute. Cause: not clear from the log.")
        XCTAssertEqual(condition.action, .restart)
        XCTAssertEqual(state("web").phase, .failed)
    }

    /// A service outside the profile is skipped, and `/api/status` says why.
    func testAServiceOutsideTheProfileHasASkipReason() async throws {
        let partner = ServiceDefinition(
            id: "partner-portal", name: "Partner Portal", cmd: ["sleep", "30"], cwd: workDir.path, probe: nil,
            type: .daemon, restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        let anchor = ServiceDefinition(
            id: "anchor", name: nil, cmd: ["sleep", "1"], cwd: nil, probe: nil, type: .daemon, restart: .never,
            dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        try supervisor.loadServices([partner, anchor], profile: .booking)
        supervisor.serviceStates["anchor"]?.phase = .running
        supervisor.health = .healthy

        supervisor.restartService("partner-portal")

        let skipped = await waitUntil(10) {
            self.state("partner-portal").phase == .skipped && self.supervisor.actionsInFlight.isEmpty
        }
        XCTAssertTrue(skipped, "partner-portal is \(state("partner-portal").phase.rawValue)")
        XCTAssertEqual(state("partner-portal").condition?.kind, .notInProfile)
        let fields = EnvironmentSupervisor.statusFields(state("partner-portal"))
        XCTAssertEqual(fields["skip_reason"], "Not in the Booking profile.")
        XCTAssertNil(fields["reason"])
    }

    /// "Install dependencies": the install runs in the folder of the service, its output
    /// goes to the service's log in order, and then the service starts again.
    func testTheInstallButtonInstallsThenRestarts() async throws {
        let output = (1...200).map { "install line \($0)" }
        let shell = FakeCommandRunner { call in
            call.command == "npm install" ? FakeCommandRunner.ok(output.joined(separator: "\n")) : FakeCommandRunner.ok()
        }
        supervisor.shell = shell
        try load(daemon("web", webServer))
        XCTAssertTrue(supervisor.canPerform(.installDependencies, for: "web"))
        // Negative control: a service that is not a Next app has no cache to clear.
        XCTAssertFalse(supervisor.canPerform(.clearCacheAndRestart, for: "web"))

        supervisor.perform(.installDependencies, for: "web")

        let ready = await waitUntil(30) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        let install = try XCTUnwrap(shell.calls.first { $0.command == "npm install" })
        XCTAssertEqual(install.cwd, workDir.path, "a folder without a pnpm workspace runs npm in the service folder")
        let lines = await logLines("web")
        XCTAssertEqual(lines.filter { $0.hasPrefix("install line ") }, output, "the install output keeps its order")
        let started = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("[travel-runner] Running npm install") })
        let lastInstall = try XCTUnwrap(lines.lastIndex(of: "install line 200"))
        XCTAssertLessThan(started, lastInstall)
        XCTAssertNotNil(Self.listeners(on: port).first, "the restart started the service")
    }

    /// A failed install does not restart the service; the banner says why.
    func testAFailedInstallDoesNotRestart() async throws {
        let shell = FakeCommandRunner { call in
            call.command == "npm install" ? FakeCommandRunner.failed(1, stderr: "ERR! network") : FakeCommandRunner.ok()
        }
        supervisor.shell = shell
        try load(daemon("web", webServer))

        supervisor.perform(.installDependencies, for: "web")

        let done = await waitUntil(10) { self.supervisor.lastError != nil && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(supervisor.lastError, "npm install for web failed (exit 1) — see its log")
        try await Task.sleep(for: .seconds(1))
        XCTAssertNotEqual(state("web").phase, .running)
        XCTAssertEqual(Self.listeners(on: port), [], "no restart after a failed install")
        let lines = await logLines("web")
        XCTAssertTrue(lines.contains("ERR! network"), lines.joined(separator: "\n"))
    }

    // MARK: - Dependencies before start (O6)

    private nonisolated static let pnpmInstall = "pnpm install --frozen-lockfile"

    /// Makes the folder of the test a pnpm workspace with no packages installed.
    private func makeWorkspace(lock: String = "lock A") throws {
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        for (name, text) in [("pnpm-workspace.yaml", "packages: []\n"), ("package.json", "{}\n"), ("pnpm-lock.yaml", lock)] {
            let url = workDir.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
    }

    private nonisolated static func markInstalled(_ folder: URL) {
        let modules = folder.appendingPathComponent("node_modules")
        try? FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: modules.appendingPathComponent(".modules.yaml").path, contents: Data())
    }

    /// A fake pnpm install that writes the install marker, as the real one does.
    private func fakeInstaller(gate: Gate? = nil, during: (@Sendable () -> Void)? = nil) -> FakeCommandRunner {
        let folder = workDir!
        return FakeCommandRunner { call in
            guard call.command == Self.pnpmInstall else { return FakeCommandRunner.ok() }
            await gate?.wait()
            during?()
            Self.markInstalled(folder)
            return FakeCommandRunner.ok("Packages: +1\nDone")
        }
    }

    /// Finding "lifecycle-deps-stale-badge-only": a service whose packages are not
    /// installed is started only after an install, which runs in its log.
    func testMissingPackagesAreInstalledBeforeTheStart() async throws {
        try makeWorkspace()
        let shell = fakeInstaller()
        supervisor.shell = shell
        try load(daemon("web", webServer))

        supervisor.restartService("web")

        let ready = await waitUntil(30) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        let installs = shell.calls.filter { $0.command == Self.pnpmInstall }
        XCTAssertEqual(installs.map(\.cwd), [workDir.path])
        XCTAssertEqual(installs.first?.timeout, EnvironmentChecker.installTimeout)
        let lines = await logLines("web")
        let announce = try XCTUnwrap(lines.firstIndex(of: "[travel-runner] packages are not installed — running pnpm install --frozen-lockfile"))
        let done = try XCTUnwrap(lines.firstIndex(of: "Done"))
        XCTAssertLessThan(announce, done)
        XCTAssertEqual(supervisor.dependencyRecord.hash(for: workDir.path), DependencyWatcher.lockHash(folder: workDir.path))
        XCTAssertNotNil(Self.listeners(on: port).first)
    }

    /// Two services of one workspace that start together share one install.
    func testOneInstallPerWorkspaceRoot() async throws {
        try makeWorkspace()
        let gate = Gate()
        let shell = fakeInstaller(gate: gate)
        supervisor.shell = shell
        let worker = ServiceDefinition(
            id: "worker", name: nil, cmd: ["sleep", "30"], cwd: workDir.path, probe: nil, type: .daemon,
            restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        let anchor = ServiceDefinition(
            id: "anchor", name: nil, cmd: ["sleep", "1"], cwd: nil, probe: nil, type: .daemon, restart: .never,
            dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        try supervisor.loadServices([daemon("web", webServer), worker, anchor])
        supervisor.serviceStates["anchor"]?.phase = .running
        supervisor.health = .healthy

        supervisor.restartService("web")
        supervisor.restartService("worker")

        let joined = await waitUntil(10) { shell.calls.contains { $0.command == Self.pnpmInstall } }
        XCTAssertTrue(joined)
        var waiting = false
        for _ in 0..<100 where !waiting {
            let all = await logLines("web") + logLines("worker")
            waiting = all.contains { $0.hasPrefix("[travel-runner] Waiting for the pnpm install --frozen-lockfile that runs in") }
            if !waiting { try await Task.sleep(for: .milliseconds(50)) }
        }
        XCTAssertTrue(waiting, "the second service waits for the install that runs")
        await gate.open()

        let ready = await waitUntil(30) { self.settled("web") && self.settled("worker") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue), worker is \(state("worker").phase.rawValue)")
        XCTAssertEqual(shell.commands.filter { $0 == Self.pnpmInstall }.count, 1)
    }

    /// A failed install leaves the service failed, with a reason and the install
    /// button. GitHub Packages' 401 names the row that fixes it.
    func testAFailedInstallBeforeTheStartSaysWhy() async throws {
        try makeWorkspace()
        let shell = FakeCommandRunner { call in
            call.command == Self.pnpmInstall
                ? FakeCommandRunner.failed(1, stderr: " ERR_PNPM_FETCH_401  GET https://npm.pkg.github.com/x: Unauthorized - 401")
                : FakeCommandRunner.ok()
        }
        supervisor.shell = shell
        try load(daemon("web", webServer))

        supervisor.restartService("web")

        let failed = await waitUntil(10) {
            self.state("web").phase == .failed && self.state("web").condition != nil && self.supervisor.actionsInFlight.isEmpty
        }
        XCTAssertTrue(failed, "web is \(state("web").phase.rawValue)")
        let text = "web cannot start: its packages are not installed and pnpm install --frozen-lockfile failed: GitHub Packages rejected your token — fix the 'GitHub Packages auth' row, then retry."
        XCTAssertEqual(supervisor.lastError, text)
        XCTAssertEqual(state("web").condition?.headline, text)
        XCTAssertEqual(state("web").condition?.actions, [.installDependencies, .openLog])
        XCTAssertEqual(Self.listeners(on: port), [], "nothing started")
        XCTAssertNil(supervisor.dependencyRecord.hash(for: workDir.path), "a failed install records no hash")
    }

    /// Stop all during the install before a start cancels the install, and that start
    /// runs no process, also when a new start follows at once.
    func testStopAllCancelsTheInstallBeforeTheStart() async throws {
        try makeWorkspace()
        let cancelled = LockedPids()
        let shell = FakeCommandRunner { call in
            guard call.command == Self.pnpmInstall else { return FakeCommandRunner.ok() }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            cancelled.set([1])
            return CommandResult(exitCode: -1, stdout: "", stderr: "Cancelled")
        }
        supervisor.shell = shell
        try load(daemon("web", webServer))

        supervisor.restartService("web")
        let installing = await waitUntil(10) { shell.calls.contains { $0.command == Self.pnpmInstall } }
        XCTAssertTrue(installing)

        supervisor.stopAll()
        let stopped = await waitUntil(10) { cancelled.pids == [1] && self.supervisor.health == .stopped }
        XCTAssertTrue(stopped, "the install was cancelled: \(cancelled.pids)")
        try await Task.sleep(for: .seconds(1))
        XCTAssertNotEqual(state("web").phase, .running)
        XCTAssertNil(state("web").condition, "a stop is not a failure")
        XCTAssertNil(supervisor.lastError)
        XCTAssertEqual(Self.listeners(on: port), [], "the cancelled start runs no process")
        XCTAssertNil(supervisor.dependencyRecord.hash(for: workDir.path), "a cancelled install records no hash")
        let lines = await logLines("web")
        XCTAssertTrue(lines.contains("[travel-runner] Stop all stopped the pnpm install --frozen-lockfile"), lines.joined(separator: "\n"))
    }

    /// Decision 11: stale packages (the lockfile changed after the install) are not
    /// installed at a start. The row offers the install instead.
    func testStalePackagesDoNotInstallAtTheStart() async throws {
        try makeWorkspace(lock: "lock B")
        Self.markInstalled(workDir)
        let marker = workDir.appendingPathComponent("node_modules/.modules.yaml").path
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: marker)
        supervisor.dependencyRecord.record("hash of lock A", marker: nil, for: workDir.path)
        XCTAssertEqual(DependencyWatcher.state(of: workDir.path, record: supervisor.dependencyRecord), .stale)
        let shell = fakeInstaller()
        supervisor.shell = shell
        try load(daemon("web", webServer))

        supervisor.restartService("web")

        let ready = await waitUntil(30) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        XCTAssertFalse(shell.commands.contains(Self.pnpmInstall))
        XCTAssertTrue(supervisor.canPerform(.installDependencies, for: "web"))
    }

    /// Critic item 26: a branch change that changes the lockfile installs before the
    /// restart, while the old process still runs. Without a lockfile change it only restarts.
    func testBranchChangeWithANewLockfileInstallsBeforeTheRestart() async throws {
        try makeWorkspace(lock: "lock A")
        Self.markInstalled(workDir)
        let port = port
        let duringInstall = LockedPids()
        let shell = fakeInstaller(during: { duringInstall.set(Self.listeners(on: port)) })
        supervisor.shell = shell
        try load(daemon("web", webServer))
        supervisor.restartService("web")
        let ready = await waitUntil(30) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        let first = try XCTUnwrap(state("web").pid)

        // Negative control: the same lockfile, so no install.
        await supervisor.restartAfterBranchChange(["web"])
        let restarted = await waitUntil(30) { self.settled("web") && self.state("web").pid != first }
        XCTAssertTrue(restarted)
        XCTAssertFalse(shell.commands.contains(Self.pnpmInstall))
        let second = try XCTUnwrap(state("web").pid)

        try Data("lock B".utf8).write(to: workDir.appendingPathComponent("pnpm-lock.yaml"))
        await supervisor.restartAfterBranchChange(["web"])

        XCTAssertEqual(shell.commands.filter { $0 == Self.pnpmInstall }.count, 1)
        XCTAssertEqual(duringInstall.pids, [second], "the old process ran during the install")
        let again = await waitUntil(30) { self.settled("web") && self.state("web").pid != second }
        XCTAssertTrue(again)
        let lines = await logLines("web")
        XCTAssertTrue(lines.contains("[travel-runner] The lockfile changed — running pnpm install --frozen-lockfile before the restart"))
        XCTAssertEqual(DependencyWatcher.state(of: workDir.path, record: supervisor.dependencyRecord), .fresh)
    }

    /// After a failed install on a branch change the old process keeps running: a
    /// restart on the old packages would crash in a loop.
    func testBranchChangeWithAFailedInstallKeepsTheProcess() async throws {
        try makeWorkspace(lock: "lock A")
        Self.markInstalled(workDir)
        let shell = FakeCommandRunner { call in
            call.command == Self.pnpmInstall ? FakeCommandRunner.failed(1, stderr: "ERR! network") : FakeCommandRunner.ok()
        }
        supervisor.shell = shell
        try load(daemon("web", webServer))
        supervisor.restartService("web")
        let ready = await waitUntil(30) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        let pid = try XCTUnwrap(state("web").pid)

        try Data("lock B".utf8).write(to: workDir.appendingPathComponent("pnpm-lock.yaml"))
        await supervisor.restartAfterBranchChange(["web"])

        XCTAssertEqual(
            supervisor.lastError,
            "pnpm install --frozen-lockfile for web failed (exit 1) — see its log. web still runs the old packages; fix the cause, then press Install dependencies."
        )
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(state("web").pid, pid)
        XCTAssertEqual(state("web").phase, .running)
    }

    /// "Free port and restart" frees the port of the EADDRINUSE line, also when it is
    /// not the port of the probe, and keeps a container's port helper alive.
    func testFreePortAndRestartFreesThePortItNames() async throws {
        let hmr = try Self.listeningSocket()
        let published = try Self.listeningSocket()
        defer { close(hmr.fd); close(published.fd) }
        let calls = PortToolCalls()
        let commands = [hmr.port: "node", published.port: "OrbStack Helper"]
        supervisor.portTools = PortTools(
            listeners: { port in commands[port].map { [PortOwner.Listener(pid: pid_t(port), command: $0)] } ?? [] },
            kill: { calls.addKill($0) },
            killCommands: { calls.addPattern($0) }
        )
        try load(daemon("web", webServer))

        supervisor.perform(.stopForeignAndRetry(port: hmr.port), for: "web")

        let ready = await waitUntil(30) { self.settled("web") }
        XCTAssertTrue(ready, "web is \(state("web").phase.rawValue)")
        XCTAssertEqual(calls.kills, [pid_t(hmr.port)])

        // Negative control: a container's port helper is not killed.
        calls.reset()
        let before = try XCTUnwrap(Self.listeners(on: port).first)
        supervisor.perform(.stopForeignAndRetry(port: published.port), for: "web")
        let again = await waitUntil(30) {
            self.settled("web") && Self.listeners(on: self.port).first.map { $0 != before } == true
        }
        XCTAssertTrue(again, "the service did not restart")
        XCTAssertEqual(calls.kills, [])
    }

    /// A daemon that ends with code 0 gets one automatic restart (decision 22). When
    /// it ends again it has no process, and nothing starts it again. The
    /// environment showed "starting" with no end.
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

        let banner = EnvironmentSupervisor.cleanExitMessage("quitter")
        let ended = await waitUntil(25) { self.supervisor.lastError == banner }
        XCTAssertTrue(ended, supervisor.lastError ?? "nil")
        // Long enough for another automatic restart, if there was one.
        try await Task.sleep(for: .seconds(4))

        XCTAssertEqual(supervisor.health, .degraded)
        XCTAssertEqual(state("quitter").phase, .failed)
        XCTAssertEqual(state("quitter").exitCode, 0)
        let lines = await logLines("quitter")
        XCTAssertTrue(lines.contains("[travel-runner] quitter exited (code 0) — restarting it once"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("[travel-runner] quitter exited (code 0) — not restarted"), lines.joined(separator: "\n"))
        XCTAssertEqual(lines.filter { $0 == "quitter-start" }.count, 2, "one automatic restart, then none")
        XCTAssertTrue(crashes.isEmpty, "a clean exit is not a crash: \(crashes)")
        // The header shows its banner only with a text.
        XCTAssertEqual(supervisor.lastError, "quitter exited (code 0) and was not restarted — restart it from its row")
    }

    /// The banner of a clean exit asks for a restart from the row. The restart
    /// clears it, and it does not clear another error.
    func testARestartFromTheRowClearsTheCleanExitBanner() async throws {
        // The first two runs end cleanly: the start and its one automatic restart.
        let first = workDir.appendingPathComponent("first-run").path
        let second = workDir.appendingPathComponent("second-run").path
        let script = "if [ -f '\(second)' ]; then exec sleep 60; elif [ -f '\(first)' ]; then touch '\(second)'; sleep 2; exit 0; "
            + "else touch '\(first)'; sleep 2; exit 0; fi"
        let quitter = ServiceDefinition(
            id: "quitter", name: "quitter", cmd: ["sh", "-c", script], cwd: workDir.path,
            probe: nil, type: .daemon, restart: .onFailure, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        try load(quitter)
        supervisor.restartService("quitter")
        let banner = EnvironmentSupervisor.cleanExitMessage("quitter")
        let ended = await waitUntil(30) { self.state("quitter").phase == .failed && self.supervisor.lastError == banner }
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
        // The toast says why, not only "see its log".
        XCTAssertEqual(feedback, ["Stripe CLI skipped — " + StripeLauncher.unavailableCause(.login(reason: ""))])
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

    // MARK: - S2: the portal does not wait for Stripe

    /// A Stripe service whose probe waits for a webhook secret in its output.
    private func stripeWithSecretProbe(_ script: String, dependsOn: [String] = []) -> ServiceDefinition {
        ServiceDefinition(
            id: "stripe", name: "Stripe CLI", cmd: ["sh", "-c", script], cwd: workDir.path,
            probe: ProbeConfig(type: .stdoutRegex, port: nil, host: nil, url: nil,
                               pattern: "whsec_[A-Za-z0-9]+", artifact: "STRIPE_WEBHOOK_SECRET", timeout: 60),
            type: .daemon, restart: .onFailure, dependsOn: dependsOn, env: nil, phase: nil, reuseIfRunning: nil
        )
    }

    private func oneshot(_ id: String, dependsOn: [String] = []) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: id, cmd: ["true"], cwd: workDir.path, probe: nil, type: .oneshot, restart: .never,
            dependsOn: dependsOn, env: nil, phase: nil, reuseIfRunning: nil
        )
    }

    /// The portal waited for Stripe's secret: first as a dependency, then up to
    /// 30 s more. Now it starts while Stripe still waits for its secret.
    func testStartAllStartsThePortalWhileStripeWaitsForItsSecret() async throws {
        // Remote mode: the portal starts without the keys of a local stack.
        supervisor.dbMode = .remote
        _ = fakeTheOutsideOfStartAll()
        supervisor.stripeAvailability = { true }
        let web = daemon("travel-portal", webServer)
        let portal = ServiceDefinition(
            id: web.id, name: web.name, cmd: web.cmd, cwd: web.cwd, probe: web.probe, type: .daemon,
            restart: .onFailure, dependsOn: ["login"], env: nil, phase: nil, reuseIfRunning: nil
        )
        try supervisor.loadServices([
            oneshot("base"),
            oneshot("login", dependsOn: ["base"]),
            stripeWithSecretProbe("echo stripe-start; sleep 60", dependsOn: ["base"]),
            portal,
        ])

        supervisor.startAll(skipPreflight: true)

        let portalUp = await waitUntil(30) { self.state("travel-portal").phase == .running }
        XCTAssertTrue(portalUp, "travel-portal is \(state("travel-portal").phase.rawValue), error: \(supervisor.lastError ?? "none")")
        XCTAssertEqual(state("stripe").phase, .starting, "Stripe still waits for its secret")
        XCTAssertFalse(supervisor.completedPhases.contains("GATEWAY"), "Stripe, a gateway service, still starts")
        XCTAssertNotNil(supervisor.phaseTimings["PORTAL"])
        XCTAssertNil(supervisor.phaseTimings["GATEWAY"])
        let lines = await logLines("travel-portal")
        XCTAssertFalse(
            lines.contains("[travel-runner] " + EnvironmentSupervisor.noWebhookSecretLine),
            "Stripe is on its way: no warning"
        )
    }

    /// A secret that comes after the portal started restarts the portal, so Node
    /// loads it. The same secret again restarts nothing.
    func testANewWebhookSecretRestartsTheRunningPortal() async throws {
        // Remote mode: the portal starts without the keys of a local stack.
        supervisor.dbMode = .remote
        supervisor.stripeAvailability = { true }
        try supervisor.loadServices([
            stripeWithSecretProbe("echo whsec_madeUpForTheLifecycle1; sleep 30"),
            daemon("travel-portal", webServer),
        ])
        supervisor.health = .healthy

        supervisor.restartService("travel-portal")
        let portalUp = await waitUntil(20) { self.settled("travel-portal") }
        XCTAssertTrue(portalUp, "travel-portal is \(state("travel-portal").phase.rawValue)")
        let firstPid = try XCTUnwrap(state("travel-portal").pid)

        supervisor.restartService("stripe")
        let restarted = await waitUntil(30) {
            self.state("stripe").phase == .running && self.settled("travel-portal")
                && self.state("travel-portal").pid != firstPid
        }
        XCTAssertTrue(restarted, "travel-portal is \(state("travel-portal").phase.rawValue)")
        var lines = await logLines("travel-portal")
        XCTAssertEqual(lines.filter { $0 == EnvironmentSupervisor.webhookSecretChangedLine }.count, 1, lines.joined(separator: "\n"))
        let env = try String(contentsOf: workDir.appendingPathComponent(".env.local"), encoding: .utf8)
        XCTAssertTrue(env.contains("STRIPE_WEBHOOK_SECRET=whsec_madeUpForTheLifecycle1"), env)

        let secondPid = try XCTUnwrap(state("travel-portal").pid)
        supervisor.restartService("stripe")
        let stripeBack = await waitUntil(30) { self.settled("stripe") }
        XCTAssertTrue(stripeBack)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(state("travel-portal").pid, secondPid, "the same secret restarts nothing")
        lines = await logLines("travel-portal")
        XCTAssertEqual(lines.filter { $0 == EnvironmentSupervisor.webhookSecretChangedLine }.count, 1)
    }

    /// With Stripe off and no secret the portal's log says why payments will not
    /// confirm, once.
    func testThePortalSaysPaymentsWillNotConfirmWhenStripeIsOff() async throws {
        // Remote mode: the portal starts without the keys of a local stack.
        supervisor.dbMode = .remote
        supervisor.stripeAvailability = { false }
        try supervisor.loadServices([
            stripeWithSecretProbe("echo stripe-start; sleep 30"),
            daemon("travel-portal", webServer),
        ])
        supervisor.health = .healthy

        supervisor.restartService("travel-portal")
        let portalUp = await waitUntil(20) { self.settled("travel-portal") }
        XCTAssertTrue(portalUp, "travel-portal is \(state("travel-portal").phase.rawValue)")
        let warning = "[travel-runner] " + EnvironmentSupervisor.noWebhookSecretLine
        var lines = await logLines("travel-portal")
        XCTAssertFalse(lines.contains(warning), "Stripe has not been tried yet")

        supervisor.restartService("stripe")
        let skipped = await waitUntil(15) { self.state("stripe").phase == .skipped && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(skipped, "stripe is \(state("stripe").phase.rawValue)")
        lines = await logLines("travel-portal")
        XCTAssertEqual(lines.filter { $0 == warning }.count, 1, lines.joined(separator: "\n"))

        supervisor.restartService("stripe")
        _ = await waitUntil(15) { self.supervisor.actionsInFlight.isEmpty }
        lines = await logLines("travel-portal")
        XCTAssertEqual(lines.filter { $0 == warning }.count, 1, "once for each start of the portal")
    }

    /// Review of S2: a secret from an earlier Stripe run forwards nothing. With
    /// Stripe off the portal still says that payments will not confirm.
    func testThePortalWarnsWhenStripeIsOffAlthoughAnOldSecretIsKnown() async throws {
        // Remote mode: the portal starts without the keys of a local stack.
        supervisor.dbMode = .remote
        let stripeOn = OSAllocatedUnfairLock(initialState: true)
        supervisor.stripeAvailability = { stripeOn.withLock { $0 } }
        try supervisor.loadServices([
            stripeWithSecretProbe("echo whsec_madeUpOldSecret1; sleep 30"),
            daemon("travel-portal", webServer),
        ])
        supervisor.health = .healthy

        supervisor.restartService("stripe")
        let stripeUp = await waitUntil(20) { self.settled("stripe") }
        XCTAssertTrue(stripeUp, "stripe is \(state("stripe").phase.rawValue)")
        supervisor.restartService("travel-portal")
        let portalUp = await waitUntil(20) { self.settled("travel-portal") }
        XCTAssertTrue(portalUp, "travel-portal is \(state("travel-portal").phase.rawValue)")
        let warning = "[travel-runner] " + EnvironmentSupervisor.noWebhookSecretLine
        var lines = await logLines("travel-portal")
        XCTAssertFalse(lines.contains(warning), "Stripe runs")

        stripeOn.withLock { $0 = false }
        supervisor.restartService("stripe")
        let skipped = await waitUntil(15) { self.state("stripe").phase == .skipped && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(skipped, "stripe is \(state("stripe").phase.rawValue)")
        lines = await logLines("travel-portal")
        XCTAssertEqual(lines.filter { $0 == warning }.count, 1, lines.joined(separator: "\n"))
    }

    /// Review of S2: a webhook secret that restarts the portal during Start All
    /// does not let the portal's dependents start before the new portal is up.
    func testAServiceThatNeedsThePortalWaitsForItsRestartOnANewSecret() async throws {
        // Remote mode: the portal starts without the keys of a local stack.
        supervisor.dbMode = .remote
        _ = fakeTheOutsideOfStartAll()
        supervisor.stripeAvailability = { true }
        // The portal takes 3 s to listen; the secret comes after 2 s.
        let web = daemon("travel-portal", ["sh", "-c", "sleep 3; exec \(webServer.joined(separator: " "))"])
        let portal = ServiceDefinition(
            id: web.id, name: web.name, cmd: web.cmd, cwd: web.cwd, probe: web.probe, type: .daemon,
            restart: .onFailure, dependsOn: ["login"], env: nil, phase: nil, reuseIfRunning: nil
        )
        try supervisor.loadServices([
            oneshot("base"),
            oneshot("login", dependsOn: ["base"]),
            stripeWithSecretProbe("sleep 2; echo whsec_madeUpForTheRestart1; sleep 60", dependsOn: ["base"]),
            portal,
            oneshot("verify", dependsOn: ["travel-portal"]),
        ])

        supervisor.startAll(skipPreflight: true)

        var portalWhenVerifyStarted: ServicePhase?
        let verifyStarted = await waitUntil(40) {
            if self.state("verify").phase != .pending {
                portalWhenVerifyStarted = self.state("travel-portal").phase
                return true
            }
            return false
        }
        XCTAssertTrue(verifyStarted, "error: \(supervisor.lastError ?? "none")")
        XCTAssertEqual(portalWhenVerifyStarted, .running)
        let lines = await logLines("travel-portal")
        XCTAssertEqual(
            lines.filter { $0 == EnvironmentSupervisor.webhookSecretChangedLine }.count, 1,
            "the secret came while the portal started: \(lines.joined(separator: "\n"))"
        )
    }

    /// Review of S2: the database check after GROUND can reset the database, so
    /// it waits for every service of that level, also one that nothing needs.
    func testTheGroundLevelWaitsForAServiceThatNothingNeeds() async throws {
        _ = fakeTheOutsideOfStartAll()
        let slow = daemon("fork-app", ["sh", "-c", "sleep 2; exec \(webServer.joined(separator: " "))"])
        try supervisor.loadServices([
            oneshot("supabase"),
            slow,
            oneshot("next", dependsOn: ["supabase"]),
        ])

        supervisor.startAll(skipPreflight: true)

        var forkAppWhenNextStarted: ServicePhase?
        let nextStarted = await waitUntil(40) {
            if self.state("next").phase != .pending {
                forkAppWhenNextStarted = self.state("fork-app").phase
                return true
            }
            return false
        }
        XCTAssertTrue(nextStarted, "error: \(supervisor.lastError ?? "none")")
        XCTAssertEqual(forkAppWhenNextStarted, .running)
    }

    /// A Stripe service and a booking portal whose `.env` has a made-up test key.
    private func loadStripeWithTestKey(_ key: String, script: String) throws {
        let booking = workDir.appendingPathComponent("booking-portal")
        try FileManager.default.createDirectory(at: booking, withIntermediateDirectories: true)
        try "STRIPE_SECRET_KEY=\(key)\n".write(to: booking.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let portal = ServiceDefinition(
            id: "travel-portal", name: "Travel Portal", cmd: ["sleep", "1"], cwd: booking.path, probe: nil,
            type: .daemon, restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        try supervisor.loadServices([stripe(script), portal])
        supervisor.health = .healthy
    }

    /// S1: 45 tickets were an expired personal `stripe login`. With the portal's test
    /// key Stripe needs no login. The key is in the env of the check and of the
    /// process, never in a command or in the state.
    func testStripeStartsOnThePortalTestKeyWithoutALogin() async throws {
        let key = "sk_test_madeUpForTheLifecycle1"
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        // The script prints whether it got the key, not the key.
        try loadStripeWithTestKey(key, script: #"if [ "$STRIPE_API_KEY" = "\#(key)" ]; then echo key-in-env; fi; sleep 30"#)

        supervisor.restartService("stripe")

        var lines: [String] = []
        for _ in 0..<200 where !lines.contains("key-in-env") {
            try await Task.sleep(for: .milliseconds(50))
            lines = await logLines("stripe")
        }
        XCTAssertTrue(lines.contains("key-in-env"), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains(StripeMode.testKey(source: "apps/booking-portal/.env").logLine), lines.joined(separator: "\n"))
        XCTAssertEqual(state("stripe").modeNote, "Test key from apps/booking-portal/.env")

        let check = try XCTUnwrap(shell.calls.first { $0.command == StripeLauncher.availabilityCommand })
        XCTAssertEqual(check.environment, ["STRIPE_API_KEY": key])
        XCTAssertFalse(shell.calls.contains { $0.command.contains(key) }, "the key is never in a command")
        XCTAssertNil(state("stripe").definition.env, "the state keeps no key")
        XCTAssertFalse(lines.contains { $0.contains(key) }, "the log never shows the key")
    }

    /// Control: without a key the check runs on the login, with no key in its env.
    func testStripeWithoutAKeyUsesTheLogin() async throws {
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        try load(stripe("echo stripe-start; sleep 30"))

        supervisor.restartService("stripe")

        let running = await waitUntil(15) { self.state("stripe").phase == .running }
        XCTAssertTrue(running, "stripe is \(state("stripe").phase.rawValue)")
        XCTAssertEqual(state("stripe").modeNote, "Your stripe login")
        XCTAssertEqual(shell.calls.first { $0.command == StripeLauncher.availabilityCommand }?.environment, [:])
    }

    /// In test-key mode a 401 means the key is wrong; `stripe login` does not fix that.
    func testA401OnTheTestKeySaysTheKeyWasRejected() async throws {
        supervisor.shell = FakeCommandRunner()
        try loadStripeWithTestKey("sk_test_madeUpForTheLifecycle2", script: "echo 'Authorization failed, status=401'; sleep 2; exit 1")

        supervisor.restartService("stripe")

        let skipped = await waitUntil(20) { self.state("stripe").phase == .skipped }
        XCTAssertTrue(skipped, "stripe is \(state("stripe").phase.rawValue)")
        let expected = "[travel-runner] Stripe stopped: the Stripe CLI exited with code 1 — "
            + "Stripe rejected STRIPE_SECRET_KEY from apps/booking-portal/.env — import a current .env."
        var lines: [String] = []
        for _ in 0..<100 where !lines.contains(expected) {
            try await Task.sleep(for: .milliseconds(50))
            lines = await logLines("stripe")
        }
        XCTAssertTrue(lines.contains(expected), lines.joined(separator: "\n"))

        // A ticket and Report a problem give the same cause, not "run stripe login".
        let issues = workDir.appendingPathComponent("issues")
        supervisor.diagnosticsTools = { _ in [] }
        supervisor.debugTracker = DebugTracker(baseDir: issues.path, rateLimitSeconds: 0)
        await supervisor.captureDebugIssue(trigger: "manual", serviceID: "stripe", summary: "Stripe stopped")
        let causes = await supervisor.debugTracker?.listIssues(status: "open").map(\.likelyCause) ?? []
        XCTAssertEqual(causes, ["Stripe rejected STRIPE_SECRET_KEY from apps/booking-portal/.env — import a current .env."])

        let reports = workDir.appendingPathComponent("reports")
        supervisor.makeReportExporter = {
            ReportExporter(
                destination: reports, temporaryDirectory: reports.appendingPathComponent("tmp"),
                timeZone: .current, now: { Date() },
                zip: { _, archive in
                    try? Data("PK".utf8).write(to: archive)
                    return FakeCommandRunner.ok()
                }
            )
        }
        let report = try await supervisor.exportReport(focus: .service(id: "stripe"))
        XCTAssertTrue(report.summary.contains("Stripe rejected STRIPE_SECRET_KEY"), report.summary)
        XCTAssertFalse(report.summary.contains("stripe login"), report.summary)
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
        // A Stripe on the catalog command also kills the listener of the runner before S1.
        calls.reset()
        try supervisor.loadServices([service("stripe", StripeLauncher.command, port: nil)], profile: .booking)
        await supervisor.cleanupStaleProcesses()
        XCTAssertEqual(calls.patterns, StripeLauncher.stalePatterns(for: StripeLauncher.command))
        XCTAssertEqual(calls.patterns.count, 2)
        calls.reset()
        try supervisor.loadServices(services, profile: .booking)
        await supervisor.cleanupStaleProcesses()
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

    // MARK: - L1: dependency gating, start outcomes, one serial stack operation

    private func service(
        _ id: String, _ script: String, type: ServiceType = .oneshot, dependsOn: [String] = []
    ) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: id, cmd: ["sh", "-c", script], cwd: workDir.path, probe: nil, type: type,
            restart: type == .daemon ? .onFailure : .never, dependsOn: dependsOn, env: nil, phase: nil, reuseIfRunning: nil
        )
    }

    private func webDependingOn(_ dependencies: [String]) -> ServiceDefinition {
        let web = daemon("web", webServer)
        return ServiceDefinition(
            id: web.id, name: web.name, cmd: web.cmd, cwd: web.cwd, probe: web.probe, type: .daemon,
            restart: .onFailure, dependsOn: dependencies, env: nil, phase: nil, reuseIfRunning: nil
        )
    }

    private func startAllEnded() async -> Bool {
        await waitUntil(40) { self.supervisor.startupBeganAt == nil && self.supervisor.health != .starting }
    }

    /// The four gating findings: Start All went on into the services that need a
    /// failed one, and a later failure replaced the first error. Now they wait,
    /// and the first error is the headline.
    func testAFailedDependencyHoldsItsDependentsWaitingAndTheFirstErrorWins() async throws {
        _ = fakeTheOutsideOfStartAll()
        try supervisor.loadServices([
            service("base", "exit 3"),
            webDependingOn(["base"]),
            service("next", "true", dependsOn: ["web"]),
            service("ok", "true"),
            service("late", "exit 4", dependsOn: ["ok"]),
        ])

        supervisor.startAll(skipPreflight: true)

        let ended = await startAllEnded()
        XCTAssertTrue(ended)
        XCTAssertEqual(state("base").phase, .failed)
        XCTAssertEqual(state("late").phase, .failed, "a service that needs no failed one still starts")
        XCTAssertEqual(state("web").phase, .waiting)
        XCTAssertNil(state("web").lastStarted, "no process starts for a waiting service")
        XCTAssertEqual(state("web").condition?.kind, .waitingForDependency("base"))
        XCTAssertEqual(state("web").condition?.headline, "Waiting for base (failed)")
        XCTAssertEqual(state("next").phase, .waiting)
        // It waits for web, and the row names the root cause, not web.
        XCTAssertEqual(state("next").condition?.kind, .waitingForDependency("web"))
        XCTAssertEqual(state("next").condition?.headline, "Waiting for base (failed)")
        XCTAssertEqual(Self.listeners(on: port), [])
        XCTAssertEqual(supervisor.health, .degraded)
        XCTAssertEqual(supervisor.lastError, "base failed: base exited with non-zero status", "the first error wins")
        XCTAssertEqual(supervisor.rootCauseServiceID, "base")
        XCTAssertEqual(supervisor.rootCauseDescription, "2 services are waiting for it.")
    }

    /// A waiting service starts by itself when its dependency comes up.
    func testAWaitingServiceStartsWhenItsDependencyIsUp() async throws {
        _ = fakeTheOutsideOfStartAll()
        let marker = workDir.appendingPathComponent("base-ran").path
        try supervisor.loadServices([
            service("base", "if [ -f '\(marker)' ]; then exit 0; else touch '\(marker)'; exit 3; fi"),
            webDependingOn(["base"]),
        ])
        var feedback: [String] = []
        supervisor.onActionFeedback = { message, _ in feedback.append(message) }

        supervisor.startAll(skipPreflight: true)
        let ended = await startAllEnded()
        XCTAssertTrue(ended)
        XCTAssertEqual(state("web").phase, .waiting)

        supervisor.restartService("base")

        let up = await waitUntil(30) { self.settled("web") }
        XCTAssertTrue(up, "web is \(state("web").phase.rawValue)")
        XCTAssertEqual(state("base").phase, .completed)
        XCTAssertNil(state("web").condition)
        let lines = await logLines("base")
        XCTAssertTrue(lines.contains("[travel-runner] base is up — starting web"), lines.joined(separator: "\n"))
        XCTAssertEqual(feedback, ["base restarted"])
        XCTAssertEqual(supervisor.health, .healthy)
    }

    /// "Retry failed" restarted the healthy services too. Now it starts only what
    /// does not run: the port check and the port cleanup leave a running service.
    func testRetryFailedLeavesAHealthyServiceAlone() async throws {
        _ = fakeTheOutsideOfStartAll()
        let marker = workDir.appendingPathComponent("broken-ran").path
        try supervisor.loadServices([
            daemon("web", webServer),
            service("broken", "if [ -f '\(marker)' ]; then exit 0; else touch '\(marker)'; exit 3; fi"),
        ])

        supervisor.startAll(skipPreflight: true)
        var ended = await startAllEnded()
        XCTAssertTrue(ended)
        XCTAssertEqual(state("web").phase, .running)
        XCTAssertEqual(state("broken").phase, .failed)
        let pid = try XCTUnwrap(state("web").pid)
        let started = state("web").lastStarted

        supervisor.retryStartAll()

        ended = await waitUntil(40) { self.state("broken").phase == .completed && self.supervisor.startupBeganAt == nil }
        XCTAssertTrue(ended, "broken is \(state("broken").phase.rawValue), error: \(supervisor.lastError ?? "none")")
        XCTAssertEqual(state("web").pid, pid, "the healthy service keeps its process")
        XCTAssertEqual(state("web").lastStarted, started)
        XCTAssertEqual(state("web").phase, .running)
        XCTAssertEqual(try ownListener(), pid)
        XCTAssertFalse(supervisor.preflightChecks.contains { $0.id == "port-\(port)" }, "its port is its own")
        XCTAssertEqual(supervisor.health, .healthy)
        let lines = await logLines("web")
        XCTAssertEqual(lines.filter { $0.contains("Serving HTTP") }.count, 1, lines.joined(separator: "\n"))
    }

    /// Start pressed during a Stop was dropped. Now it runs after the stop.
    func testAStartDuringAStopRunsAfterTheStop() async throws {
        _ = fakeTheOutsideOfStartAll()
        try supervisor.loadServices([daemon("web", webServer)])
        supervisor.startAll(skipPreflight: true)
        let healthy = await waitUntil(40) { self.supervisor.health == .healthy }
        XCTAssertTrue(healthy)
        let firstPid = state("web").pid

        supervisor.stopAll()
        supervisor.startAll(skipPreflight: true)

        let again = await waitUntil(40) {
            self.supervisor.health == .healthy && self.state("web").phase == .running
                && self.state("web").pid != firstPid && self.supervisor.startupBeganAt == nil
        }
        XCTAssertTrue(again, "health \(supervisor.health), web \(state("web").phase.rawValue)")
        XCTAssertEqual(supervisor.currentPhase, .running)
        XCTAssertEqual(Self.listeners(on: port).count, 1)
    }

    /// A restart of a stopped stack said "restarted" and started nothing. It says
    /// what to do now.
    func testARestartOfAStoppedStackSaysPressStart() async throws {
        try supervisor.loadServices([daemon("web", webServer)])
        XCTAssertEqual(supervisor.health, .stopped)
        var feedback: [(String, Bool)] = []
        supervisor.onActionFeedback = { message, ok in feedback.append((message, ok)) }

        supervisor.restartService("web")

        let done = await waitUntil(10) { !feedback.isEmpty && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(feedback.map(\.0), ["Not started — the stack is stopped. Press Start."])
        XCTAssertEqual(feedback.map(\.1), [false])
        XCTAssertNil(state("web").lastStarted)
        XCTAssertEqual(Self.listeners(on: port), [])
    }

    /// The waiter of a process that crashed timed out while its automatic
    /// restart still started, and marked the new process FAILED.
    func testAnOldWaiterDoesNotFailTheReplacement() async throws {
        let marker = workDir.appendingPathComponent("first-run").path
        let script = "if [ -f '\(marker)' ]; then sleep 4; exec \(webServer.joined(separator: " ")); "
            + "else touch '\(marker)'; sleep 0.5; exit 1; fi"
        try load(daemon("flaky", ["sh", "-c", script], probeTimeout: 8))
        var feedback: [String] = []
        supervisor.onActionFeedback = { message, _ in feedback.append(message) }

        supervisor.restartService("flaky")

        var firstPid: Int32?
        var failedReplacement = false
        let up = await waitUntil(40) {
            let state = self.state("flaky")
            if firstPid == nil { firstPid = state.pid }
            if let pid = state.pid, pid != firstPid, state.phase == .failed { failedReplacement = true }
            return firstPid != nil && state.pid != firstPid && self.settled("flaky")
        }
        XCTAssertTrue(up, "flaky is \(state("flaky").phase.rawValue), error: \(supervisor.lastError ?? "none")")
        XCTAssertFalse(failedReplacement, "the old waiter marked the new process failed")
        XCTAssertEqual(feedback, ["flaky restarted"])
    }

    /// A oneshot that hangs ran for ever. It is stopped at its deadline and says so.
    func testAOneshotPastItsDeadlineIsStoppedAndSaysSo() async throws {
        supervisor.oneshotDeadline = .seconds(1)
        try load(service("slow", "echo slow-start; exec sleep 30"))

        supervisor.restartService("slow")

        let failed = await waitUntil(15) { self.state("slow").phase == .failed && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(failed, "slow is \(state("slow").phase.rawValue)")
        let text = "slow did not finish in 1 s and was stopped. See its log."
        XCTAssertEqual(supervisor.lastError, text)
        let lines = await logLines("slow")
        XCTAssertTrue(lines.contains("[travel-runner] " + text), lines.joined(separator: "\n"))
        let pid = try XCTUnwrap(state("slow").pid)
        let gone = await waitUntil(5) { kill(pid, 0) != 0 }
        XCTAssertTrue(gone, "the process still runs")
        XCTAssertEqual(EnvironmentSupervisor.durationText(.seconds(15 * 60)), "15 min")
    }

    /// The first error won only for errors that the start threw. A daemon that ends
    /// with 127 later wrote its own error into the banner from its exit.
    func testALaterDaemonThatCannotRunKeepsTheFirstHeadline() async throws {
        _ = fakeTheOutsideOfStartAll()
        let late = ServiceDefinition(
            id: "late", name: "late", cmd: ["/bin/sh", "-c", "sleep 2; exit 127"], cwd: workDir.path,
            probe: ProbeConfig(type: .tcp, port: port, host: nil, url: nil, pattern: nil, artifact: nil, timeout: 30),
            type: .daemon, restart: .onFailure, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        try supervisor.loadServices([service("base", "exit 3"), late])

        supervisor.startAll(skipPreflight: true)

        let ended = await startAllEnded()
        XCTAssertTrue(ended)
        XCTAssertEqual(state("late").phase, .failed)
        XCTAssertEqual(state("late").exitCode, 127)
        // The finding of the exit comes a moment later.
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(supervisor.lastError, "base failed: base exited with non-zero status", "the first error wins")
        XCTAssertNotNil(state("late").condition, "the row still says why")
    }

    /// A daemon with a probe that ends with code 0 while it starts gets its one
    /// automatic restart. The old waiter failed it first, and the headline stayed
    /// after the restart came up.
    func testAProbedDaemonThatExitsCleanlyWhileItStartsGetsItsRestartAndNoHeadline() async throws {
        _ = fakeTheOutsideOfStartAll()
        let marker = workDir.appendingPathComponent("first-run").path
        let script = "if [ -f '\(marker)' ]; then exec \(webServer.joined(separator: " ")); "
            + "else touch '\(marker)'; sleep 1; exit 0; fi"
        try supervisor.loadServices([daemon("web", ["sh", "-c", script])])

        supervisor.startAll(skipPreflight: true)

        let ended = await startAllEnded()
        XCTAssertTrue(ended)
        XCTAssertEqual(state("web").phase, .running)
        XCTAssertNil(supervisor.lastError)
        XCTAssertNil(supervisor.rootCauseServiceID)
        XCTAssertEqual(supervisor.health, .healthy)
        let lines = await logLines("web")
        XCTAssertTrue(lines.contains("[travel-runner] web exited (code 0) — restarting it once"), lines.joined(separator: "\n"))
    }

    /// A restart of a service that runs, while its dependency failed, stopped the
    /// process and left the service waiting. Now the process keeps running.
    func testARestartWhileTheDependencyFailedKeepsTheRunningProcess() async throws {
        try supervisor.loadServices([service("base", "true"), webDependingOn(["base"])])
        supervisor.health = .healthy
        state("base").phase = .completed
        supervisor.restartService("web")
        let up = await waitUntil(40) { self.settled("web") }
        XCTAssertTrue(up, "web is \(state("web").phase.rawValue)")
        let pid = try XCTUnwrap(state("web").pid)
        state("base").phase = .failed
        var feedback: [(String, Bool)] = []
        supervisor.onActionFeedback = { message, ok in feedback.append((message, ok)) }

        supervisor.restartService("web")

        let done = await waitUntil(10) { !feedback.isEmpty && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(feedback.map(\.0), ["web not restarted — waiting for base (failed); it keeps running"])
        XCTAssertEqual(feedback.map(\.1), [false])
        XCTAssertEqual(state("web").phase, .running)
        XCTAssertEqual(state("web").pid, pid)
        XCTAssertEqual(try ownListener(), pid)
    }

    /// A DB step that a person asks for during Start All waits for it, and runs
    /// after. A start that the other runner app refused ends its time too.
    func testADbStepQueuedBehindStartAllRunsAfterIt() async throws {
        try loadSupabase()
        supervisor.shell = FakeCommandRunner()
        supervisor.secretRegistryPorts = 0...0
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "", stderr: "") }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        let only = step("first", "true")
        var asked = 0
        supervisor.dbPipelineFactory = { _, _ in
            asked += 1
            return self.pipeline([only])
        }
        let gate = Gate()
        supervisor.siblingActiveServices = {
            await gate.wait()
            return ["other"]
        }
        var feedback: [String] = []
        supervisor.onActionFeedback = { message, _ in feedback.append(message) }

        supervisor.startAll(skipPreflight: true)
        supervisor.runDbSetup(profile: "reset")

        XCTAssertEqual(feedback, [EnvironmentSupervisor.dbSetupWaitsText])
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(asked, 0, "the step waits for the start")
        XCTAssertFalse(supervisor.dbResetRunning)
        XCTAssertNotNil(supervisor.startupBeganAt)

        await gate.open()

        let done = await waitUntil(30) {
            only.status == .passed && !self.supervisor.dbResetRunning && self.supervisor.stackIsIdle
        }
        XCTAssertTrue(done, "step is \(only.status.rawValue)")
        XCTAssertEqual(asked, 1)
        XCTAssertNil(supervisor.startupBeganAt, "the refused start ended its time")
    }

    /// Two stops in a row: the second waits for the first, and the stack ends
    /// stopped. A DB step that waited is dropped by the second stop, and says so.
    func testTwoStopsInARowDropTheWaitingDbStepAndSaySo() async throws {
        try loadSupabase()
        supervisor.shell = FakeCommandRunner()
        var asked = 0
        supervisor.dbPipelineFactory = { _, _ in
            asked += 1
            return self.pipeline([self.step("first", "true")])
        }
        var feedback: [(String, Bool)] = []
        supervisor.onActionFeedback = { message, ok in feedback.append((message, ok)) }

        supervisor.stopAll()
        supervisor.runDbSetup(profile: "reset")
        supervisor.stopAll()

        let stopped = await waitUntil(20) { self.supervisor.stackIsIdle && self.supervisor.health == .stopped }
        XCTAssertTrue(stopped)
        XCTAssertEqual(feedback.map(\.0), [EnvironmentSupervisor.dbSetupWaitsText, EnvironmentSupervisor.dbSetupDroppedText])
        XCTAssertEqual(feedback.map(\.1), [true, false])
        XCTAssertEqual(asked, 0, "the dropped step did not run")
        XCTAssertEqual(state("supabase").phase, .stopped)
        XCTAssertFalse(supervisor.dbResetRunning)
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

    /// Supabase and a portal that needs it. The database is empty, so Start All runs
    /// the setup pipeline of the test (`command` is its one step).
    private func startWithAnEmptyDatabase(setup command: String) throws -> ServiceDefinition {
        _ = fakeTheOutsideOfStartAll()
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "0", stderr: "") }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        supervisor.dbPipelineFactory = { _, _ in self.pipeline([self.step("load-hotels", command)]) }
        let portal = ServiceDefinition(
            id: "portal", name: "portal", cmd: ["sleep", "60"], cwd: workDir.path, probe: nil,
            type: .daemon, restart: .never, dependsOn: ["supabase"], env: nil, phase: "portal", reuseIfRunning: nil
        )
        try supervisor.loadServices([daemon("supabase", webServer), portal])
        return portal
    }

    /// Finding "the start goes on after a failed setup": the setup of an empty
    /// database failed, and the portals started on a database without tables.
    func testAFailedSetupOfAnEmptyDatabaseStopsTheStartBeforeThePortals() async throws {
        _ = try startWithAnEmptyDatabase(setup: "echo '##db:status:failed:HTTP 401'; exit 1")

        supervisor.startAll()

        let halted = await waitUntil(40) {
            self.supervisor.health == .degraded && self.supervisor.currentPhase == .idle
        }
        XCTAssertTrue(halted, "health is \(supervisor.health), phase \(supervisor.currentPhase)")
        XCTAssertEqual(
            supervisor.lastError, "Database setup failed at load-hotels: HTTP 401. Portals were not started."
        )
        XCTAssertNil(state("portal").lastStarted)
        XCTAssertFalse(supervisor.completedPhases.contains("PORTAL"), "\(supervisor.completedPhases)")
        // A later health pass keeps the start failed.
        supervisor.recalculateHealth()
        XCTAssertEqual(supervisor.health, .degraded)
    }

    /// Control: the same start with a setup that passes starts the portal.
    func testAPassedSetupOfAnEmptyDatabaseStartsThePortals() async throws {
        _ = try startWithAnEmptyDatabase(setup: "echo '##db:status:done'")

        supervisor.startAll()

        let healthy = await waitUntil(40) { self.supervisor.health == .healthy }
        XCTAssertTrue(healthy, "health is \(supervisor.health), error: \(supervisor.lastError ?? "none")")
        XCTAssertNotNil(state("portal").lastStarted)
        XCTAssertNil(supervisor.lastError)
    }

    /// A setup that cannot even begin (here: no pipeline) also halts the start, and
    /// the header says that the portals were not started.
    func testASetupThatCannotBeginStopsTheStartAndSaysSo() async throws {
        _ = try startWithAnEmptyDatabase(setup: "echo '##db:status:done'")
        supervisor.dbPipelineFactory = { _, _ in nil }

        supervisor.startAll()

        let halted = await waitUntil(40) {
            self.supervisor.health == .degraded && self.supervisor.currentPhase == .idle
        }
        XCTAssertTrue(halted, "health is \(supervisor.health), phase \(supervisor.currentPhase)")
        XCTAssertEqual(
            supervisor.lastError,
            "Database setup failed at setup: No DB setup pipeline for the profile reset. Portals were not started."
        )
        XCTAssertNil(state("portal").lastStarted)
    }

    /// After a halted start, a setup from DB Tools that passes keeps the start halted
    /// and says to click Retry. A failed one says why.
    func testASetupThatPassesAfterAHaltedStartSaysToRetry() async throws {
        _ = try startWithAnEmptyDatabase(setup: "echo '##db:status:failed:HTTP 401'; exit 1")
        supervisor.startAll()
        let halted = await waitUntil(40) {
            self.supervisor.health == .degraded && self.supervisor.currentPhase == .idle
        }
        XCTAssertTrue(halted)

        supervisor.dbPipelineFactory = { _, profile in
            self.pipeline([self.step("load-hotels", "echo '##db:status:done'")], profile: profile)
        }
        supervisor.resetDatabase()
        let done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)

        XCTAssertEqual(supervisor.lastError, DbResetPolicy.setUpAfterHaltText)
        XCTAssertTrue(supervisor.dbSetupFailedAtStart)
        XCTAssertEqual(supervisor.health, .degraded)
        XCTAssertNil(state("portal").lastStarted)
    }

    // MARK: - Hotels (D3)

    /// Findings "onboarding hotels need the shared env": after Start the hotel catalog
    /// was empty and nothing said so. The banner says it, and nothing loads or resets
    /// by itself; the portals start.
    func testAnEmptyHotelCatalogRaisesTheBannerAndStartsNothing() async throws {
        _ = fakeTheOutsideOfStartAll()
        var count = "12"
        var skipped = "false"
        var resets = 0
        supervisor.databaseQuery = { _, sql in
            if sql.contains("pg_tables") { return DbQueryResult(exitCode: 0, stdout: "42", stderr: "") }
            if sql == HotelCatalog.countSQL { return DbQueryResult(exitCode: 0, stdout: count, stderr: "") }
            if sql.contains("seed_state") {
                return DbQueryResult(exitCode: 0, stdout: #"{"scenario_id":"standard","hotels_skipped":\#(skipped)}"#, stderr: "")
            }
            return DbQueryResult(exitCode: 0, stdout: "", stderr: "")
        }
        supervisor.dbResetAction = { _ in
            resets += 1
            return true
        }
        let portal = ServiceDefinition(
            id: "portal", name: "portal", cmd: ["sleep", "60"], cwd: workDir.path, probe: nil,
            type: .daemon, restart: .never, dependsOn: ["supabase"], env: nil, phase: "portal", reuseIfRunning: nil
        )
        try supervisor.loadServices([daemon("supabase", webServer), portal])

        supervisor.startAll()

        let healthy = await waitUntil(40) { self.supervisor.health == .healthy }
        XCTAssertTrue(healthy, "health is \(supervisor.health), error: \(supervisor.lastError ?? "none")")
        XCTAssertEqual(
            supervisor.hotelCatalogNotice?.text, "Hotel catalog is empty (12 hotels) — hotel search will return nothing."
        )
        XCTAssertTrue(supervisor.hotelCatalogBannerVisible)
        XCTAssertEqual(resets, 0)
        XCTAssertNil(supervisor.dbSetupPipeline)
        XCTAssertFalse(supervisor.dbResetRunning)
        XCTAssertNotNil(state("portal").lastStarted)
        XCTAssertNil(supervisor.lastError)

        // Negative controls: a reset that left the hotels out, and a full catalog.
        skipped = "true"
        await supervisor.refreshHotelCatalog(cwd: workDir.path)
        XCTAssertNil(supervisor.hotelCatalogNotice)
        skipped = "false"
        count = "209823"
        await supervisor.refreshHotelCatalog(cwd: workDir.path)
        XCTAssertNil(supervisor.hotelCatalogNotice)
        // A dismiss holds until the catalog changes.
        count = "3"
        await supervisor.refreshHotelCatalog(cwd: workDir.path)
        supervisor.dismissHotelCatalogBanner()
        await supervisor.refreshHotelCatalog(cwd: workDir.path)
        XCTAssertFalse(supervisor.hotelCatalogBannerVisible)
        // Positive control: a changed count shows the banner again.
        count = "4"
        await supervisor.refreshHotelCatalog(cwd: workDir.path)
        XCTAssertTrue(supervisor.hotelCatalogBannerVisible)
        XCTAssertEqual(resets, 0)
    }

    /// Findings "hotel seed needs a shared env marked optional": the reset wiped the
    /// database, then the hotel download failed. Now the prerequisites stop first, and
    /// the banner offers the shared .env or a reset without hotels.
    func testAResetThatCannotGetTheHotelsStopsBeforeTheResetAndOffersAWayOut() async throws {
        try loadSupabase()
        supervisor.shell = FakeCommandRunner()
        // Another checkout built the database: the confirmation says so.
        supervisor.databaseQuery = { _, sql in
            sql.contains("seed_state")
                ? DbQueryResult(exitCode: 0, stdout: #"{"checkout_path":"/elsewhere/mono","branch":"dev"}"#, stderr: "")
                : DbQueryResult(exitCode: 0, stdout: "", stderr: "")
        }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        let marker = workDir.appendingPathComponent("reset-ran")
        let line = "Hotels cannot be downloaded yet: No dev credentials: apps/booking-portal/.env is missing "
            + "AMATEUR_SUPABASE_URL / ANON_KEY / SIGNING_KEY. Nothing was reset."
        var prerequisites = "echo '##db:health:fail:\(line)'; echo '##db:status:failed:\(line)'; exit 10"
        var profiles: [String] = []
        supervisor.dbPipelineFactory = { _, profile in
            profiles.append(profile)
            let command = profile == HotelCatalog.withoutHotelsProfile ? "echo '##db:status:done'" : prerequisites
            return self.pipeline(
                [self.step("check-prerequisites", command), self.step("reset-database", "touch '\(marker.path)'")],
                profile: profile
            )
        }

        supervisor.resetDatabase()
        let stopped = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(stopped)

        XCTAssertEqual(supervisor.hotelSourceNotice?.text, line)
        XCTAssertEqual(supervisor.hotelSourceNotice?.beforeReset, true)
        let confirmation = try XCTUnwrap(supervisor.hotelSourceNotice?.resetConfirmation)
        XCTAssertTrue(confirmation.hasPrefix(DbResetPolicy.resetConfirmationBody), confirmation)
        XCTAssertTrue(confirmation.contains("This database was last built from /elsewhere/mono (dev)."), confirmation)
        XCTAssertEqual(supervisor.lastError, "DB setup failed at check-prerequisites: \(line)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "nothing was reset")

        supervisor.resetWithoutHotels()
        let reset = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(reset)
        XCTAssertEqual(profiles, ["reset", HotelCatalog.withoutHotelsProfile])
        XCTAssertNil(supervisor.hotelSourceNotice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // Negative control: a missing tool (exit 1) is no hotel banner.
        prerequisites = "echo '##db:status:failed:Missing: Docker is not running'; exit 1"
        supervisor.resetDatabase()
        let failed = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(failed)
        XCTAssertNil(supervisor.hotelSourceNotice)
        XCTAssertEqual(supervisor.lastError, "DB setup failed at check-prerequisites: Missing: Docker is not running")
    }

    /// Review of D3: the guard that refuses a branch with no `fast` profile. Without it
    /// the loader would run `reset`, hotels and all.
    func testResetWithoutHotelsOnABranchWithoutTheFastProfileChangesNothing() async throws {
        try loadSupabase()
        let fake = try checkoutLackingAMigration(profiles: ["reset"])
        supervisor.dbResetAction = nil
        supervisor.dbPipelineFactory = nil
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })

        supervisor.resetWithoutHotels()

        XCTAssertEqual(supervisor.lastError, HotelCatalog.noWithoutHotelsProfileText)
        XCTAssertNil(supervisor.dbSetupPipeline)
        XCTAssertFalse(supervisor.dbResetRunning)
        XCTAssertEqual(fake.resets(), 0)

        // Positive control: with the profile the guard lets it through; this checkout
        // has no seed scenario, so the next guard stops it.
        _ = try checkoutLackingAMigration(profiles: ["reset", HotelCatalog.withoutHotelsProfile])
        supervisor.dbResetAction = nil
        supervisor.lastError = nil
        supervisor.resetWithoutHotels()
        XCTAssertNotNil(supervisor.lastError)
        XCTAssertNotEqual(supervisor.lastError, HotelCatalog.noWithoutHotelsProfileText)
    }

    /// "Load hotels" runs the load step alone, never the reset, also when the pipeline
    /// on screen has no load step. The banner goes once the catalog is full.
    func testLoadHotelsRunsOnlyTheLoadStep() async throws {
        try loadSupabase()
        supervisor.shell = FakeCommandRunner()
        var count = "0"
        supervisor.databaseQuery = { _, sql in
            if sql == HotelCatalog.countSQL { return DbQueryResult(exitCode: 0, stdout: count, stderr: "") }
            if sql.contains("seed_state") { return DbQueryResult(exitCode: 0, stdout: #"{"hotels_skipped":false}"#, stderr: "") }
            return DbQueryResult(exitCode: 0, stdout: "", stderr: "")
        }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        let marker = workDir.appendingPathComponent("reset-ran")
        supervisor.dbPipelineFactory = { _, profile in
            self.pipeline(
                [self.step("reset-database", "touch '\(marker.path)'"), self.step("load-hotels", "echo '##db:status:done'")],
                profile: profile
            )
        }
        supervisor.dbSetupPipeline = pipeline([step("reset-database", "true")], profile: HotelCatalog.withoutHotelsProfile)
        await supervisor.refreshHotelCatalog(cwd: workDir.path)
        XCTAssertNotNil(supervisor.hotelCatalogNotice)

        count = "209823"
        supervisor.loadHotels()
        let done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)

        let pipeline = try XCTUnwrap(supervisor.dbSetupPipeline)
        XCTAssertEqual(pipeline.steps.map(\.id), ["load-hotels"], "the pipeline holds only the load")
        XCTAssertEqual(pipeline.steps.first?.status, .passed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "nothing was reset")
        XCTAssertNil(supervisor.lastError)
        XCTAssertNil(supervisor.hotelCatalogNotice)
    }

    /// Review of D3/D5: with no valid cached dump, "Load hotels" downloads first as its
    /// own step with the download's time limit, then loads. It never resets. With a
    /// cached dump it runs the load alone.
    func testLoadHotelsWithNoCachedDumpDownloadsFirstInItsOwnStep() async throws {
        try loadSupabase()
        supervisor.shell = FakeCommandRunner()
        supervisor.hotelDumpPath = workDir.appendingPathComponent("hotels/travel_organizations.sql").path
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "", stderr: "") }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        let marker = workDir.appendingPathComponent("reset-ran")
        supervisor.dbPipelineFactory = { _, profile in
            self.pipeline([
                self.step("check-prerequisites", "true"),
                self.step(HotelCatalog.fetchStepID, "echo fetch"),
                self.step("reset-database", "touch '\(marker.path)'"),
                self.step(HotelCatalog.loadStepID, "echo load"),
            ], profile: profile)
        }

        supervisor.hotelDump = .missing
        supervisor.loadHotels()
        var done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)
        var pipeline = try XCTUnwrap(supervisor.dbSetupPipeline)
        XCTAssertEqual(pipeline.steps.map(\.id), [HotelCatalog.fetchStepID, HotelCatalog.loadStepID])
        XCTAssertEqual(pipeline.steps.map(\.status), [.passed, .passed])
        XCTAssertEqual(pipeline.steps.first?.hardCapSeconds, 1800, "the download has its own cap")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "nothing was reset")
        XCTAssertNil(supervisor.lastError)

        // Control: a valid cached dump loads at once.
        supervisor.hotelDump = .cached("209823 hotels")
        supervisor.loadHotels()
        done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)
        pipeline = try XCTUnwrap(supervisor.dbSetupPipeline)
        XCTAssertEqual(pipeline.steps.map(\.id), [HotelCatalog.loadStepID])
        XCTAssertEqual(pipeline.steps.first?.status, .passed)
    }

    /// A failed load after the download: Retry runs the load again, not the download.
    func testRetryOfAFailedLoadAfterTheDownloadSkipsTheDownload() async throws {
        try loadSupabase()
        supervisor.shell = FakeCommandRunner()
        supervisor.hotelDumpPath = workDir.appendingPathComponent("hotels/travel_organizations.sql").path
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "", stderr: "") }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        let fetches = workDir.appendingPathComponent("fetches")
        let loadOK = workDir.appendingPathComponent("load-ok")
        supervisor.dbPipelineFactory = { _, profile in
            self.pipeline([
                self.step(HotelCatalog.fetchStepID, "echo x >> '\(fetches.path)'"),
                self.step(HotelCatalog.loadStepID, "test -f '\(loadOK.path)'"),
            ], profile: profile)
        }

        supervisor.hotelDump = .missing
        supervisor.loadHotels()
        var done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)
        XCTAssertEqual(supervisor.dbSetupPipeline?.firstFailed?.id, HotelCatalog.loadStepID)

        FileManager.default.createFile(atPath: loadOK.path, contents: nil)
        supervisor.runDbSetup(from: HotelCatalog.loadStepID)
        done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)
        let pipeline = try XCTUnwrap(supervisor.dbSetupPipeline)
        XCTAssertEqual(pipeline.steps.map(\.status), [.passed, .passed])
        let runs = try String(contentsOf: fetches, encoding: .utf8).split(separator: "\n").count
        XCTAssertEqual(runs, 1, "the retry did not download again")
    }

    /// Positive control of the guard against the loader's fallback to `reset`: a
    /// manifest with a `migrate` profile runs only the migrate steps, with no seed
    /// scenario selected.
    func testApplyMigrationsRunsTheMigrateProfileOfTheManifest() async throws {
        let tracker = captureIssues()
        try loadSupabase()
        _ = try checkoutLackingAMigration()
        let folder = workDir.appendingPathComponent("scripts/db")
        let manifest = #"""
        {"version":4,"steps":[
          {"id":"reset-database","command":"echo '##db:status:done'"},
          {"id":"apply-migrations","command":"echo '##db:status:done'"},
          {"id":"verify-data","command":"echo '##db:status:done'"}
        ],"profiles":{"reset":["reset-database","verify-data"],"migrate":["apply-migrations"]}}
        """#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        supervisor.dbResetAction = nil
        supervisor.dbPipelineFactory = nil
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        XCTAssertNil(supervisor.selectedDbSeedScenario)

        supervisor.applyMigrations()
        let done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)

        let pipeline = try XCTUnwrap(supervisor.dbSetupPipeline, supervisor.lastError ?? "no pipeline")
        XCTAssertEqual(pipeline.profile, "migrate")
        XCTAssertEqual(pipeline.steps.map(\.id), ["apply-migrations"])
        XCTAssertEqual(pipeline.seedScenario, DbResetPolicy.noScenario)
        XCTAssertNil(supervisor.lastError)
        XCTAssertEqual(supervisor.migrationsAppliedNotice, DbResetPolicy.appliedText)
        let resets = await events("db_reset", in: tracker)
        XCTAssertEqual(resets.map(\.message), ["origin: apply-migrations, profile: migrate"])
    }

    /// One step from DB Tools goes through the same entry point: a db_reset event,
    /// the error, and an issue for a failed step.
    func testOneStepFromDbToolsIsRecordedLikeEverySetup() async throws {
        let tracker = captureIssues()
        try loadSupabase()
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "", stderr: "") }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        var ran: [String] = []
        supervisor.dbPipelineFactory = { _, profile in
            self.pipeline([
                self.step("first", "echo first"),
                self.step("reset-database", "echo '##db:status:failed:boom'; exit 1"),
                self.step("verify-data", "echo verify"),
            ], profile: profile)
        }

        supervisor.runDbSetupStep("reset-database")
        let done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)

        let pipeline = try XCTUnwrap(supervisor.dbSetupPipeline)
        ran = pipeline.steps.filter { $0.status != .pending }.map(\.id)
        XCTAssertEqual(ran, ["reset-database"], "only the one step runs")
        XCTAssertEqual(supervisor.lastError, "DB setup failed at reset-database: boom")
        let resets = await events("db_reset", in: tracker)
        XCTAssertEqual(resets.map(\.message), ["origin: single-step, profile: full, step: reset-database"])
        let issues = await tracker.listOpenIssues()
        XCTAssertEqual(issues.count, 1)

        // A step that the pipeline does not have runs nothing.
        supervisor.runDbSetupStep("no-such-step")
        XCTAssertFalse(supervisor.dbResetRunning)
    }

    // MARK: - D5: DB Tools confirm, choose, recover

    /// "Re-download hotels" runs the fetch step alone with `--force`, never the reset.
    func testReDownloadHotelsRunsOnlyTheFetchWithForce() async throws {
        try loadSupabase()
        supervisor.shell = FakeCommandRunner()
        supervisor.hotelDumpPath = workDir.appendingPathComponent("hotels/travel_organizations.sql").path
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "", stderr: "") }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        let marker = workDir.appendingPathComponent("reset-ran")
        supervisor.dbPipelineFactory = { _, profile in
            self.pipeline([
                self.step("reset-database", "touch '\(marker.path)'"),
                self.step(HotelCatalog.fetchStepID, "echo fetch"),
            ], profile: profile)
        }

        supervisor.redownloadHotels()
        let done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)

        let pipeline = try XCTUnwrap(supervisor.dbSetupPipeline)
        let fetch = try XCTUnwrap(pipeline.steps.first { $0.id == HotelCatalog.fetchStepID })
        XCTAssertEqual(fetch.status, .passed)
        XCTAssertEqual(fetch.command, "echo fetch --force")
        XCTAssertEqual(fetch.logEntries.map(\.text), ["fetch --force"])
        XCTAssertEqual(pipeline.steps.map(\.id), [HotelCatalog.fetchStepID], "the pipeline holds only the fetch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "nothing was reset")
        XCTAssertEqual(supervisor.hotelDump, .missing, "the dump is read again after a fetch")

        // Control: "Load hotels only" adds no flag.
        supervisor.dbPipelineFactory = { _, profile in
            self.pipeline([self.step(HotelCatalog.loadStepID, "echo load")], profile: profile)
        }
        supervisor.loadHotels()
        let loaded = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(loaded)
        XCTAssertEqual(supervisor.dbSetupPipeline?.steps.first?.command, "echo load")
    }

    /// A failed "Re-download hotels" shows Retry and Run All. Both rerun only the
    /// fetch: neither goes on to the reset. Before, the stored pipeline was the whole
    /// `reset` profile, so one click wiped the database with no confirmation.
    func testRetryAndRunAllAfterAFailedReDownloadNeverReset() async throws {
        try loadSupabase()
        supervisor.shell = FakeCommandRunner()
        supervisor.hotelDumpPath = workDir.appendingPathComponent("hotels/travel_organizations.sql").path
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "", stderr: "") }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        let marker = workDir.appendingPathComponent("reset-ran")
        supervisor.dbPipelineFactory = { _, profile in
            self.pipeline([
                self.step("check-prerequisites", "true"),
                self.step(HotelCatalog.fetchStepID, "f() { echo fetch $@; return 12 }; f"),
                self.step("reset-database", "touch '\(marker.path)'"),
                self.step(HotelCatalog.loadStepID, "true"),
            ], profile: profile)
        }

        supervisor.redownloadHotels()
        var done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)
        let shown = try XCTUnwrap(supervisor.dbSetupPipeline)
        XCTAssertEqual(shown.firstFailed?.id, HotelCatalog.fetchStepID)

        // Retry of the failed row, then Run All: each runs the fetch again, with --force.
        for stepID in [HotelCatalog.fetchStepID, shown.steps.first?.id ?? ""] {
            supervisor.runDbSetup(from: stepID)
            done = await waitUntil(30) { !self.supervisor.dbResetRunning }
            XCTAssertTrue(done)
            let pipeline = try XCTUnwrap(supervisor.dbSetupPipeline)
            XCTAssertEqual(pipeline.steps.map(\.id), [HotelCatalog.fetchStepID])
            XCTAssertEqual(pipeline.steps.first?.logEntries.map(\.text), ["fetch --force"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "nothing was reset")
        }

        // The fetch from DB Tools is a new run of the step, with no --force.
        supervisor.runDbSetupStep(HotelCatalog.fetchStepID)
        done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)
        XCTAssertEqual(supervisor.dbSetupPipeline?.steps.first?.logEntries.map(\.text), ["fetch"])

        // Negative control: Run All of a full pipeline does reach the reset.
        supervisor.dbPipelineFactory = { _, profile in
            self.pipeline([self.step("reset-database", "touch '\(marker.path)'")], profile: profile)
        }
        supervisor.dbSetupPipeline = nil
        supervisor.runDbSetup(from: "reset-database")
        done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    /// One step from DB Tools reads its step from a profile the branch has. A branch
    /// with no `full` profile used to stop with "Profile 'full' is not defined".
    func testOneStepFromDbToolsUsesAProfileThatHasTheStep() async throws {
        try loadSupabase()
        let folder = workDir.appendingPathComponent("scripts/db")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest = #"""
        {"version":4,"steps":[
          {"id":"reset-database","command":"echo reset"},
          {"id":"verify-data","command":"echo '##db:status:done'"}
        ],"profiles":{"reset":["reset-database","verify-data"]}}
        """#
        try Data(manifest.utf8).write(to: folder.appendingPathComponent("manifest.json"))
        supervisor.dbResetAction = nil
        supervisor.dbPipelineFactory = nil
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "", stderr: "") }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        // A checkout with no seed scenarios seeds supabase/seed.sql.
        let supabase = workDir.appendingPathComponent("supabase")
        try FileManager.default.createDirectory(at: supabase, withIntermediateDirectories: true)
        try Data().write(to: supabase.appendingPathComponent("seed.sql"))

        supervisor.runDbSetupStep("verify-data")
        // The step is a stack operation until its last refresh ends.
        let done = await waitUntil(30) {
            !self.supervisor.dbResetRunning && self.supervisor.stackIsIdle
        }
        XCTAssertTrue(done)

        let pipeline = try XCTUnwrap(supervisor.dbSetupPipeline, supervisor.lastError ?? "no pipeline")
        XCTAssertEqual(pipeline.profile, "reset")
        XCTAssertEqual(pipeline.steps.map(\.id), ["verify-data"])
        XCTAssertEqual(pipeline.steps.first?.status, .passed)

        // Control: a profile the person chose still has to exist.
        supervisor.dbSetupPipeline = nil
        supervisor.runDbSetup(profile: "full")
        XCTAssertFalse(supervisor.dbResetRunning)
        XCTAssertEqual(supervisor.lastError, "Profile 'full' is not defined on this branch")
    }

    /// Finding seed-no-post-reset-refresh: after a reset the running portals hold the
    /// old data. The runner says so and offers "Restart portals".
    func testAResetWhilePortalsRunOffersToRestartThem() async throws {
        let portal = ServiceDefinition(
            id: "travel-portal", name: "Travel Portal", cmd: ["sleep", "60"], cwd: workDir.path, probe: nil,
            type: .daemon, restart: .never, dependsOn: [], env: nil, phase: "portal", reuseIfRunning: nil
        )
        try supervisor.loadServices([daemon("supabase", ["sleep", "60"]), portal])
        state("supabase").phase = .running
        state("travel-portal").phase = .running
        supervisor.shell = FakeCommandRunner()
        supervisor.hotelDumpPath = workDir.appendingPathComponent("hotels/travel_organizations.sql").path
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "", stderr: "") }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        supervisor.dbPipelineFactory = { _, profile in
            self.pipeline([self.step("reset-database", "true")], profile: profile)
        }

        supervisor.resetDatabase()
        let done = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(done)
        XCTAssertEqual(supervisor.portalRestartNotice, "Database reset — restart portals to pick up fresh data")
        XCTAssertEqual(supervisor.runningPortalIDs, ["travel-portal"])

        // Negative control: with no portal running there is nothing to restart.
        state("travel-portal").phase = .stopped
        supervisor.resetDatabase()
        XCTAssertNil(supervisor.portalRestartNotice, "a new setup clears the old notice")
        let again = await waitUntil(30) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(again)
        XCTAssertNil(supervisor.portalRestartNotice)
    }

    /// Finding seed-reset-button-ux: Reset Database asks first. The question names the
    /// scenario, the hotels and another checkout's data, and runs nothing.
    func testTheResetButtonAsksFirstAndNamesWhatHappens() async throws {
        try loadSupabase()
        _ = try checkoutLackingAMigration(
            profiles: ["reset", HotelCatalog.withoutHotelsProfile],
            builtFrom: #"{"checkout_path":"/elsewhere/mono","branch":"dev"}"#
        )
        supervisor.dbSeedScenarios = [DbSeedScenario(
            id: "sold-out", name: "Sold out", description: "", fileSummary: "", variables: []
        )]
        supervisor.selectedDbSeedScenarioID = "sold-out"
        supervisor.hotelDump = .cached("Cached — 209,823 rows, 2026-08-11")

        supervisor.askToResetDatabase()
        let asked = await waitUntil(10) { self.supervisor.resetConfirmation != nil }
        XCTAssertTrue(asked)

        let request = try XCTUnwrap(supervisor.resetConfirmation)
        XCTAssertTrue(request.message.hasPrefix(
            "Every local booking, block and user is deleted. Scenario: Sold out. Hotels: reload from cache (about 3 min)."
        ), request.message)
        XCTAssertTrue(request.message.contains("This database was last built from /elsewhere/mono (dev)."), request.message)
        XCTAssertTrue(request.offersWithoutHotels)
        XCTAssertFalse(supervisor.dbResetRunning, "a question runs nothing")
        XCTAssertNil(supervisor.dbSetupPipeline)

        supervisor.cancelResetConfirmation()
        XCTAssertNil(supervisor.resetConfirmation)

        // Control: a branch without the fast profile offers no reset without hotels,
        // and a dump that is not cached is downloaded first.
        _ = try checkoutLackingAMigration(profiles: ["reset"])
        supervisor.hotelDump = .missing
        supervisor.askToResetDatabase()
        let askedAgain = await waitUntil(10) { self.supervisor.resetConfirmation != nil }
        XCTAssertTrue(askedAgain)
        XCTAssertEqual(supervisor.resetConfirmation?.offersWithoutHotels, false)
        XCTAssertEqual(
            supervisor.resetConfirmation?.message,
            "Every local booking, block and user is deleted. Scenario: Sold out. Hotels: download from dev, then load (about 8 min)."
        )
    }

    // MARK: - DB setup with a pipeline from the test

    private func pipeline(_ steps: [DbSetupStep], profile: String = "reset") -> DbSetupPipeline {
        let scenario = DbSeedScenario(id: "test", name: "Test", description: "", fileSummary: "", variables: [])
        let pipeline = DbSetupPipeline(profile: profile, seedScenario: scenario)
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

    /// A DB setup whose step starts a child that writes its pid to `child` and waits.
    /// The step runs in a shell that reads no startup files.
    private func runChildStep(
        _ command: String = "sleep 60 & echo $! > child; wait"
    ) async throws -> (step: DbSetupStep, child: pid_t) {
        try loadSupabase()
        supervisor.shell = FakeCommandRunner()
        supervisor.databaseQuery = { _, _ in DbQueryResult(exitCode: 0, stdout: "", stderr: "") }
        supervisor.dbStepLauncher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        let running = step("load-hotels", command)
        supervisor.dbPipelineFactory = { _, _ in self.pipeline([running, self.step("verify-data", "true")]) }

        supervisor.runDbSetup(profile: "reset")
        let file = workDir.appendingPathComponent("child").path
        var child: pid_t?
        for _ in 0..<200 where child == nil {
            child = (try? String(contentsOfFile: file, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if child == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        return (running, try XCTUnwrap(child, "the step did not start its child"))
    }

    /// Ends a child of `runChildStep` that is still there. Only a process in the
    /// test's folder: the pid may belong to another process by now.
    private func reapChild(_ pid: pid_t) {
        if kill(pid, 0) == 0, Self.process(pid, runsIn: workDir.lastPathComponent) { kill(pid, SIGKILL) }
    }

    /// Findings "Cancel reported as failure; UI unlocks early" and "Timeout and
    /// Cancel kill only the wrapper": Cancel ends the step's tree, the DB controls
    /// stay locked until it is gone, and a cancel sets no error and files no issue.
    func testCancelEndsTheStepTreeAndIsNotAFailure() async throws {
        let tracker = captureIssues()
        let (step, child) = try await runChildStep()
        defer { reapChild(child) }

        supervisor.cancelDbSetup()
        XCTAssertTrue(supervisor.dbResetRunning, "the controls unlock only when the processes are gone")
        let unlocked = await waitUntil(10) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(unlocked)

        XCTAssertNotEqual(kill(child, 0), 0, "the child of the step still runs")
        let ended = await waitUntil(10) { self.supervisor.dbSetupPipeline?.isRunning == false }
        XCTAssertTrue(ended)
        XCTAssertEqual(step.status, .cancelled)
        XCTAssertNil(step.errorMessage)
        XCTAssertNil(supervisor.lastError)
        let issues = await tracker.listOpenIssues()
        XCTAssertTrue(issues.isEmpty, "a cancel filed an issue")
    }

    /// The root of the step dies on SIGTERM, but its child ignores it and keeps the
    /// pipe open until the SIGKILL. The controls stay locked and the pipeline runs
    /// until the child is gone. The stop waits 30 s before SIGKILL here, and the
    /// test ends the child itself, so no timing decides the result.
    func testCancelKeepsTheControlsLockedWhileAChildHandlesSigterm() async throws {
        supervisor.dbStepKillGrace = .seconds(30)
        let (step, child) = try await runChildStep("(trap '' TERM; exec sleep 60) & echo $! > child; wait")
        defer { reapChild(child) }

        supervisor.cancelDbSetup()
        // Past the pipe grace of 1 s.
        try await Task.sleep(for: .milliseconds(1_500))
        XCTAssertEqual(kill(child, 0), 0, "the child did not outlive SIGTERM")
        XCTAssertTrue(supervisor.dbResetRunning, "the controls unlocked while the child runs")
        XCTAssertEqual(supervisor.dbSetupPipeline?.isRunning, true)
        XCTAssertEqual(step.status, .running)

        reapChild(child)
        let unlocked = await waitUntil(10) { !self.supervisor.dbResetRunning }
        XCTAssertTrue(unlocked)
        XCTAssertNotEqual(kill(child, 0), 0, "the controls unlocked while the child runs")
        let ended = await waitUntil(10) { self.supervisor.dbSetupPipeline?.isRunning == false }
        XCTAssertTrue(ended)
        XCTAssertEqual(step.status, .cancelled)
    }

    /// Stop All ends a DB step that runs, with its child processes.
    func testStopAllEndsTheRunningDbStep() async throws {
        let (step, child) = try await runChildStep()
        defer { reapChild(child) }

        supervisor.stopAll()
        let stopped = await waitUntil(15) { self.supervisor.health == .stopped && step.status == .cancelled }
        XCTAssertTrue(stopped, "step is \(step.status.rawValue)")
        XCTAssertNotEqual(kill(child, 0), 0, "the child of the step still runs")
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
    /// services.json, no control port 19900, no tickets folder, no other app and
    /// no git or npm watcher.
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
                        id: id, name: nil, cmd: ["sleep", "30"], cwd: loads.cwd, probe: nil, type: .daemon,
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
            startsWatchers: false
        )
        supervisor.siblingActiveServices = { [] }
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

    // MARK: - The other app at a config load

    /// Finding "Blocking calls on main": the launch asked the other runner app
    /// and held the main thread until the answer came. Now the load ends first,
    /// and the env reset follows the answer.
    func testAConfigLoadDoesNotWaitForTheOtherApp() async throws {
        let loads = fakeConfigHost(services: ["first"])
        let gate = Gate()
        supervisor.siblingActiveServices = {
            await gate.wait()
            return []
        }
        // The reset sets the database mode to local: that is how the test sees it.
        supervisor.dbMode = .remote

        supervisor.loadConfig()

        XCTAssertEqual(supervisor.sortedServiceIDs, ["first"], "the config is loaded before the other app answers")
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(supervisor.dbMode, .remote, "no reset before the answer")

        await gate.open()
        await supervisor.envResetAfterLoad?.value
        XCTAssertEqual(supervisor.dbMode, .local, "the other app runs nothing: the env is reset")
        await loads.stopControlServers()
    }

    /// The env file of the login is one file for the two apps. While the other
    /// app runs a stack, a load here leaves it alone.
    func testAConfigLoadKeepsTheEnvWhileTheOtherAppRunsAStack() async throws {
        let loads = fakeConfigHost(services: ["first"])
        supervisor.siblingActiveServices = { ["supabase", "travel-portal"] }
        supervisor.dbMode = .remote

        supervisor.loadConfig()
        await supervisor.envResetAfterLoad?.value

        XCTAssertEqual(supervisor.dbMode, .remote)
        await loads.stopControlServers()
    }

    /// A start right after the load ("Save & Start") must not start a service
    /// before the env files of the load are written.
    func testAStartWaitsForTheEnvResetOfTheLoad() async throws {
        _ = fakeTheOutsideOfStartAll()
        let loads = fakeConfigHost(services: ["first"])
        let gate = Gate()
        let asks = SiblingAsks()
        // The first ask is the one of the load and waits for the gate. The ask of
        // the start comes after the env wait, so it notes the database mode then.
        supervisor.siblingActiveServices = { [supervisor] in
            let first = await MainActor.run { asks.note(supervisor!.dbMode) }
            if first { await gate.wait() }
            return []
        }
        supervisor.dbMode = .remote

        supervisor.loadConfig()
        supervisor.startAll()

        // Without the env wait the start asks at once, with the env not reset.
        let askedEarly = await waitUntil(2) { asks.modes.count > 1 || self.supervisor.currentPhase == .preflight }
        XCTAssertFalse(askedEarly, "the start went on before the answer of the other app")
        XCTAssertNil(state("first").lastStarted)

        await gate.open()
        let started = await waitUntil(20) { self.state("first").lastStarted != nil }
        XCTAssertTrue(started, "error: \(supervisor.lastError ?? "none")")
        XCTAssertEqual(asks.modes, [.remote, .local], "the reset ran before the start went on")
        await loads.stopControlServers()
    }

    /// A restart, like a start, waits for the env reset of the load.
    func testARestartWaitsForTheEnvResetOfTheLoad() async throws {
        let shell = FakeCommandRunner { _ in FakeCommandRunner.ok() }
        supervisor.shell = shell
        let loads = fakeConfigHost(services: ["first"])
        let gate = Gate()
        supervisor.siblingActiveServices = {
            await gate.wait()
            return []
        }
        supervisor.dbMode = .remote
        supervisor.loadConfig()
        let reset = try XCTUnwrap(supervisor.envResetAfterLoad)
        // A stopped stack starts nothing on a restart: the stack counts as up.
        supervisor.health = .healthy

        supervisor.restartService("first")

        let startedEarly = await waitUntil(2) { self.state("first").lastStarted != nil }
        XCTAssertFalse(startedEarly, "the restart went on before the answer of the other app")

        await gate.open()
        await reset.value
        XCTAssertEqual(supervisor.dbMode, .local)
        let started = await waitUntil(20) { self.state("first").lastStarted != nil }
        XCTAssertTrue(started, "error: \(supervisor.lastError ?? "none")")
        await loads.stopControlServers()
    }

    /// A newer load replaces the reset of the load before it: an old answer must
    /// not write the env after the new config decided to keep it.
    func testANewerLoadReplacesTheEnvResetOfTheLoadBefore() async throws {
        let loads = fakeConfigHost(services: ["first"])
        let gate = Gate()
        supervisor.siblingActiveServices = {
            await gate.wait()
            return []
        }
        supervisor.loadConfig()
        let first = try XCTUnwrap(supervisor.envResetAfterLoad)
        supervisor.dbMode = .remote

        // Now the other app runs a stack.
        supervisor.siblingActiveServices = { ["supabase"] }
        let result = await supervisor.reconfigure()
        XCTAssertEqual(result, .applied)
        await supervisor.envResetAfterLoad?.value

        await gate.open()
        await first.value
        XCTAssertEqual(supervisor.dbMode, .remote, "the late answer for the old load resets nothing")
        await loads.stopControlServers()
    }

    /// The person switches to the hosted database while the other app has not
    /// answered yet. The late reset must not switch back to local.
    func testADatabaseModeChoiceWinsOverTheEnvResetOfTheLoad() async throws {
        let app = workDir.appendingPathComponent("booking")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try "AMATEUR_SUPABASE_URL=https://hosted.example.test\n"
            .write(to: app.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let loads = fakeConfigHost(services: ["travel-portal"])
        loads.cwd = app.path
        let gate = Gate()
        supervisor.siblingActiveServices = {
            await gate.wait()
            return []
        }
        supervisor.loadConfig()
        let reset = try XCTUnwrap(supervisor.envResetAfterLoad)

        supervisor.toggleDatabaseMode()
        XCTAssertEqual(supervisor.dbMode, .remote, "error: \(supervisor.lastError ?? "none")")

        await gate.open()
        await reset.value
        XCTAssertEqual(supervisor.dbMode, .remote)
        await loads.stopControlServers()
    }

    // MARK: - L4: the Supabase stack

    /// The Supabase service of the catalog: its launcher ends, its containers run on.
    private func supabaseStack(_ cmd: [String], probeTimeout: Int = 30) -> ServiceDefinition {
        daemon("supabase", cmd, probeTimeout: probeTimeout, reuse: true)
    }

    /// Listens on the test's port in this process, as a running database would.
    private func holdPort() throws -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(sock, 0)
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        addr.sin_port = UInt16(port).bigEndian
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(sock, 16) == 0 else {
            close(sock)
            throw XCTSkip("the test's port was taken")
        }
        return sock
    }

    /// The health that the fake check gives, and how often it was asked.
    private func fakeStackHealth(_ health: SupabaseStackHealth) -> OSAllocatedUnfairLock<(health: SupabaseStackHealth, asks: Int)> {
        let box = OSAllocatedUnfairLock(initialState: (health: health, asks: 0))
        supervisor.supabaseHealthCheck = { _, _ in
            box.withLock { value in
                value.asks += 1
                return value.health
            }
        }
        return box
    }

    private func stackStops(_ shell: FakeCommandRunner) -> Int {
        shell.commands.filter { $0 == "pnpm db:stop" }.count
    }

    /// health-supabase-ready-is-db-port-only: an open database port with Kong and auth
    /// down was reused as a running stack. A start now stops it and runs db:start.
    func testAPartlyUpSupabaseIsStoppedAndStartedAgain() async throws {
        let held = try holdPort()
        defer { close(held) }
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        let health = fakeStackHealth(.partial(missing: ["kong", "auth"]))
        // db:stop brings the stack down; db:start makes it whole.
        shell.respond { call in
            if call.command == "pnpm db:stop" { health.withLock { $0.health = .healthy } }
            return FakeCommandRunner.ok()
        }
        try load(supabaseStack(["sh", "-c", "echo db-start; exit 0"]))

        supervisor.restartService("supabase")

        let up = await waitUntil(20) { self.settled("supabase") }
        XCTAssertTrue(up, "supabase is \(state("supabase").phase.rawValue)")
        // The service can be running before the output of db:start reaches the log.
        let lines = await waitForLog("supabase", containing: "db-start")
        XCTAssertTrue(lines.contains(SupabaseStackHealth.partialRepairLine(["kong", "auth"])), lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains("db-start"), "db:start must run")
        XCTAssertEqual(stackStops(shell), 1)
    }

    /// A healthy stack is reused: no db:stop and no db:start. A negative control for
    /// the test above.
    func testAHealthySupabaseIsReusedWithoutAStart() async throws {
        let held = try holdPort()
        defer { close(held) }
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        let health = fakeStackHealth(.healthy)
        try load(supabaseStack(["sh", "-c", "echo db-start; exit 0"]))

        supervisor.restartService("supabase")

        let up = await waitUntil(20) { self.settled("supabase") }
        XCTAssertTrue(up, "supabase is \(state("supabase").phase.rawValue)")
        let lines = await logLines("supabase")
        XCTAssertFalse(lines.contains("db-start"))
        XCTAssertEqual(stackStops(shell), 0)
        XCTAssertEqual(health.withLock { $0.asks }, 1)
    }

    /// lifecycle-supabase-restart-is-noop: a restart from the row or the API reused the
    /// running containers. It now stops them and starts them again.
    func testARestartOfSupabaseStopsAndStartsItsContainers() async throws {
        let held = try holdPort()
        defer { close(held) }
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        let health = fakeStackHealth(.healthy)
        try load(supabaseStack(["sh", "-c", "echo db-start; exit 0"]))
        // After db:stop the first check finds the stack down; db:start makes it whole.
        shell.respond { call in
            if call.command == "pnpm db:stop" { health.withLock { $0.health = .down } }
            return FakeCommandRunner.ok()
        }
        supervisor.supabaseHealthCheck = { _, _ in
            health.withLock { value in
                let answer = value.health
                if answer == .down { value.health = .healthy }
                return answer
            }
        }

        supervisor.restartService("supabase", stopsStack: true)

        let lines = await waitForLog("supabase", containing: "db-start")
        XCTAssertTrue(lines.contains("db-start"), lines.joined(separator: "\n"))
        XCTAssertEqual(stackStops(shell), 1)
        XCTAssertTrue(lines.contains { $0.contains("Stopping the Supabase containers (pnpm db:stop). Data is kept.") })
    }

    /// A db:stop that fails leaves the stack running: the toast says so, not "restarted".
    func testARestartWhoseDbStopFailsSaysSupabaseDidNotStop() async throws {
        let held = try holdPort()
        defer { close(held) }
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        _ = fakeStackHealth(.healthy)
        shell.respond { call in
            call.command == "pnpm db:stop" ? FakeCommandRunner.failed(1, stderr: "stop failed") : FakeCommandRunner.ok()
        }
        var feedback: [(String, Bool)] = []
        supervisor.onActionFeedback = { message, ok in feedback.append((message, ok)) }
        try load(supabaseStack(["sh", "-c", "echo db-start; exit 0"]))

        supervisor.restartService("supabase", stopsStack: true)

        let done = await waitUntil(20) { !feedback.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(stackStops(shell), 1)
        XCTAssertEqual(feedback.first?.0, "Supabase did not stop — see its log")
        XCTAssertEqual(feedback.first?.1, false)
    }

    /// The same for a restart with dependents.
    func testACascadeRestartWhoseDbStopFailsSaysSupabaseDidNotStop() async throws {
        let held = try holdPort()
        defer { close(held) }
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        _ = fakeStackHealth(.healthy)
        shell.respond { call in
            call.command == "pnpm db:stop" ? FakeCommandRunner.failed(1, stderr: "stop failed") : FakeCommandRunner.ok()
        }
        var feedback: [(String, Bool)] = []
        supervisor.onActionFeedback = { message, ok in feedback.append((message, ok)) }
        try load(supabaseStack(["sh", "-c", "echo db-start; exit 0"]))
        // The reset check after Supabase asks the database once.
        supervisor.databaseProbeRetry = (.milliseconds(10), .zero)

        supervisor.restartCascade("supabase")

        let done = await waitUntil(20) { !feedback.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(stackStops(shell), 1)
        XCTAssertEqual(feedback.first?.0, "Supabase did not stop — see its log")
    }

    /// Another project's database that takes the port during the start stops the
    /// wait at once with the reason, not at the probe timeout.
    func testAnotherProjectsStackFoundWhileStartingFailsAtOnce() async throws {
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        _ = fakeStackHealth(.foreign(container: "supabase_db_fb-travel-data"))
        try load(supabaseStack(webServer, probeTimeout: 120))

        supervisor.restartService("supabase")

        let failed = await waitUntil(20) {
            self.supervisor.lastError?.contains("held by another Supabase stack (supabase_db_fb-travel-data)") == true
        }
        XCTAssertTrue(failed, "supabase is \(state("supabase").phase.rawValue), error: \(supervisor.lastError ?? "nil")")
        XCTAssertEqual(stackStops(shell), 0)
    }

    /// A restart from the panel asks first; the confirmation restarts the stack.
    func testARestartOfSupabaseFromThePanelAsksFirst() async throws {
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        _ = fakeStackHealth(.healthy)
        try load(supabaseStack(["sh", "-c", "exit 0"]))
        state("supabase").phase = .running

        supervisor.requestRestart("supabase")
        XCTAssertEqual(supervisor.supabaseRestartConfirmation, .service)
        supervisor.cancelSupabaseRestart()
        XCTAssertNil(supervisor.supabaseRestartConfirmation)
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(stackStops(shell), 0, "a cancelled question stops nothing")
        XCTAssertEqual(state("supabase").phase, .running)

        // Another service restarts without a question.
        supervisor.requestRestart("anchor")
        XCTAssertNil(supervisor.supabaseRestartConfirmation)

        supervisor.requestCascadeRestart("supabase")
        XCTAssertEqual(supervisor.supabaseRestartConfirmation, .withDependents)
        supervisor.cancelSupabaseRestart()
        XCTAssertEqual(SupabaseStackHealth.restartConfirmationTitle + " " + SupabaseStackHealth.restartConfirmationMessage,
                       "Restart Supabase? This stops and starts the local containers (about 1 min). Data is kept.")
    }

    /// Ready means the whole stack answers, not only the database port.
    func testSupabaseIsNotRunningUntilItsWholeStackAnswers() async throws {
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        let health = fakeStackHealth(.partial(missing: ["auth"]))
        try load(supabaseStack(webServer))

        supervisor.restartService("supabase")

        // The port opens; the stack is still partly up.
        let portOpen = await waitUntil(20) { !Self.listeners(on: self.port).isEmpty }
        XCTAssertTrue(portOpen)
        try await Task.sleep(for: .seconds(3))
        XCTAssertEqual(state("supabase").phase, .starting)
        XCTAssertEqual(state("supabase").lastProbe, .other("the database port is open; auth not answering"))

        health.withLock { $0.health = .healthy }
        let up = await waitUntil(20) { self.settled("supabase") }
        XCTAssertTrue(up, "supabase is \(state("supabase").phase.rawValue)")
        XCTAssertEqual(stackStops(shell), 0, "the port was free: a plain db:start")
    }

    /// One repair for each start: a stack that stays partly up fails with the reason,
    /// and the automatic restart does not stop the containers again.
    func testAStackThatStaysPartlyUpFailsAfterOneRepair() async throws {
        let held = try holdPort()
        defer { close(held) }
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        _ = fakeStackHealth(.partial(missing: ["rest"]))
        // db:start fails; the automatic restart finds the stack partly up again.
        try load(supabaseStack(["sh", "-c", "echo db-start; exit 3"]))

        supervisor.restartService("supabase")

        let failed = await waitUntil(30) {
            self.state("supabase").phase == .failed && self.supervisor.lastError?.contains("still only partly up") == true
        }
        XCTAssertTrue(failed, "supabase is \(state("supabase").phase.rawValue), error: \(supervisor.lastError ?? "none")")
        try await Task.sleep(for: .seconds(4))
        XCTAssertEqual(stackStops(shell), 1)
        XCTAssertEqual(
            supervisor.lastError,
            "Supabase is still only partly up (rest not answering) after db:stop and db:start — restart Supabase, and see its log"
        )
    }

    /// Another project's database on the port is never reused or stopped.
    func testAnotherProjectsStackOnThePortStopsTheStart() async throws {
        let held = try holdPort()
        defer { close(held) }
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        _ = fakeStackHealth(.foreign(container: "supabase_db_fb-travel-data"))
        try load(supabaseStack(["sh", "-c", "echo db-start; exit 0"]))

        supervisor.restartService("supabase")

        let failed = await waitUntil(20) { self.state("supabase").phase == .failed && self.supervisor.actionsInFlight.isEmpty }
        XCTAssertTrue(failed, "supabase is \(state("supabase").phase.rawValue)")
        XCTAssertTrue(supervisor.lastError?.contains("held by another Supabase stack (supabase_db_fb-travel-data)") == true,
                      supervisor.lastError ?? "nil")
        let lines = await logLines("supabase")
        XCTAssertFalse(lines.contains("db-start"))
        XCTAssertEqual(stackStops(shell), 0)
    }

    /// The liveness loop never restarts Supabase by itself: a restart stops its
    /// containers. The row offers Restart instead.
    func testAWakeCheckNeverRestartsSupabaseByItself() async throws {
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        let health = fakeStackHealth(.healthy)
        try load(supabaseStack(["sh", "-c", "echo db-start; exit 0"], probeTimeout: 5))
        // "Running" for the supervisor, but nothing listens: the probe after wake fails.
        state("supabase").phase = .running
        state("supabase").lastStarted = Date().addingTimeInterval(-3600)

        supervisor.handleWake()

        let failed = await waitUntil(30) { self.state("supabase").phase == .failed }
        XCTAssertTrue(failed, "supabase is \(state("supabase").phase.rawValue)")
        try await Task.sleep(for: .seconds(5))
        XCTAssertEqual(state("supabase").phase, .failed)
        XCTAssertEqual(state("supabase").restartCount, 0)
        XCTAssertEqual(state("supabase").condition?.actions.first, .restart)
        let lines = await logLines("supabase")
        XCTAssertFalse(lines.contains("db-start"))
        XCTAssertEqual(stackStops(shell), 0)
        XCTAssertEqual(health.withLock { $0.asks }, 0)
    }

    /// "Stop Supabase" runs db:stop, and only while the stack is stopped.
    func testStopSupabaseRunsDbStopOnlyWhileTheStackIsStopped() async throws {
        let shell = FakeCommandRunner()
        supervisor.shell = shell
        var feedback: [(String, Bool)] = []
        supervisor.onActionFeedback = { message, ok in feedback.append((message, ok)) }
        try load(supabaseStack(["sh", "-c", "exit 0"]))
        XCTAssertTrue(supervisor.hasSupabaseStack)

        // The stack runs: the portals would lose their database.
        XCTAssertFalse(supervisor.canStopSupabase)
        supervisor.stopSupabase()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(stackStops(shell), 0)

        supervisor.health = .stopped
        XCTAssertTrue(supervisor.canStopSupabase)
        supervisor.stopSupabase()
        let done = await waitUntil(10) { !feedback.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(stackStops(shell), 1)
        XCTAssertEqual(feedback.first?.0, "Supabase stopped")
        XCTAssertEqual(state("supabase").phase, .stopped)
        XCTAssertEqual(shell.calls.first { $0.command == "pnpm db:stop" }?.cwd, workDir.path)
    }

    /// Supabase keeps running after quit unless the setting is on.
    func testQuittingStopsSupabaseOnlyWhenTheSettingIsOn() throws {
        try load(supabaseStack(["sh", "-c", "exit 0"]))
        XCTAssertFalse(supervisor.stopSupabaseOnQuit)
        XCTAssertNil(supervisor.supabaseStopAtQuit)

        supervisor.stopSupabaseOnQuit = true
        let stop = try XCTUnwrap(supervisor.supabaseStopAtQuit)
        XCTAssertEqual(stop.resolvedStopCmd, ["pnpm", "db:stop"])
        XCTAssertEqual(stop.resolvedCwd, workDir.path)
    }

    /// Waits for a line with `text` in the log of the service, and returns the log.
    private func waitForLog(_ id: String, containing text: String, seconds: Double = 20) async -> [String] {
        let deadline = Date().addingTimeInterval(seconds)
        var lines: [String] = []
        repeat {
            lines = await logLines(id)
            if lines.contains(where: { $0.contains(text) }) { return lines }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return lines
    }
}

/// The database mode at each ask of the other app.
@MainActor
private final class SiblingAsks {
    var modes: [EnvironmentSupervisor.DatabaseMode] = []

    /// True for the first ask.
    func note(_ mode: EnvironmentSupervisor.DatabaseMode) -> Bool {
        modes.append(mode)
        return modes.count == 1
    }
}

/// What the supervisor asked of the fake config host.
@MainActor
private final class ConfigLoads {
    var count = 0
    /// The services of the config that the next load gives.
    var serviceIDs: [String] = []
    var error: (any Error)?
    /// The folder of each service. Nil: no folder, so no env file and no watcher.
    var cwd: String?
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

/// The pids that a fake install saw on the port of the test.
private final class LockedPids: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [pid_t] = []
    var pids: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set(_ pids: [pid_t]) {
        lock.lock()
        stored = pids
        lock.unlock()
    }
}
