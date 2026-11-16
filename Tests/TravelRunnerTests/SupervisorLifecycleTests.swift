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
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SupervisorLifecycleTests-\(UUID().uuidString)"))
        supervisor = EnvironmentSupervisor(userDefaults: defaults)
        port = Self.freePort()
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("SupervisorLifecycleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        crashes = []
        supervisor.onServiceCrash = { [weak self] name, code in
            self?.crashes.append((name, code))
        }
    }

    override func tearDown() async throws {
        supervisor.stopAll()
        _ = await waitUntil(10) { self.supervisor.health == .stopped }
        for pid in Self.listeners(on: port) { kill(pid, SIGKILL) }
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

    // MARK: - Tests

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

    /// Tickets with 32 and 41 recurrences: each automatic restart cleared the failure
    /// history, so the circuit breaker never saw three failures.
    func testACrashLoopStopsAtTheThirdFailure() async throws {
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

        let expected = "toolless cannot start: \(tool) was not found. Travel Runner looked in: "
        let named = await waitUntil(30) {
            self.state("toolless").phase == .failed && self.supervisor.lastError?.hasPrefix(expected) == true
        }
        XCTAssertTrue(named, supervisor.lastError ?? "nil")
        XCTAssertTrue(supervisor.lastError?.contains("/usr/bin") == true, supervisor.lastError ?? "nil")
        XCTAssertEqual(state("toolless").restartCount, 0)
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
            lines.contains { $0.hasPrefix("[travel-runner] Stripe stopped: the Stripe CLI exited with code 1") },
            lines.joined(separator: "\n")
        )
        XCTAssertEqual(lines.filter { $0 == "stripe-start" }.count, 1, "it is not restarted")
        XCTAssertEqual(state("stripe").phase, .skipped)
        XCTAssertEqual(supervisor.health, .healthy, "Stripe is optional")
        XCTAssertTrue(crashes.isEmpty, "\(crashes)")
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

        // The partner profile: now the partner portal is in, and Stripe is out.
        calls.reset()
        try supervisor.loadServices(services, profile: .partner)
        await supervisor.cleanupStaleProcesses()
        XCTAssertEqual(calls.kills, [pid_t(outside.port)])
        XCTAssertEqual(calls.patterns, [], "Stripe is outside the profile")
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
