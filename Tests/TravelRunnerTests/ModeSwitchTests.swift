import Foundation
import XCTest
@testable import TravelRunner

/// The database mode and the LAN mode, one row per switch a teammate makes. The
/// apps are `sleep` processes in folders of the test. The shell, the port tools
/// and the other app are fakes, so no row reads the tools of this Mac, opens a
/// port or touches a database.
@MainActor
final class ModeSwitchTests: XCTestCase {
    private var root: URL!
    private var supervisor: EnvironmentSupervisor!
    private var feedback: [(text: String, ok: Bool)] = []
    /// The defaults suites of the test, removed in tearDown.
    private var suites: [String] = []

    /// What the fake `local-db.sh status -o env` prints. Test values, not keys.
    private nonisolated static let statusEnv = "ANON_KEY=anon-test\nSERVICE_ROLE_KEY=service-test\nJWT_SECRET=secret-test\n"
    private nonisolated static let lanIP = "192.0.2.50"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ModeSwitchTests-\(UUID().uuidString)")
        for name in ["monolith", "booking", "partner", "login", "worker"] {
            try FileManager.default.createDirectory(at: folder(name), withIntermediateDirectories: true)
        }
        feedback = []
        suites = []
    }

    override func tearDown() async throws {
        if let supervisor {
            await stop(supervisor)
        }
        try? FileManager.default.removeItem(at: root)
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    // MARK: - Helpers

    private func folder(_ name: String) -> URL { root.appendingPathComponent(name) }

    private func daemon(_ id: String, _ folderName: String) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: id, cmd: ["sleep", "60"], cwd: folder(folderName).path, probe: nil, type: .daemon,
            restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
    }

    /// The shared dev file of an app, as `pnpm env:pull` writes it.
    private func sharedEnv(_ folderName: String, _ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n")
            .write(to: folder(folderName).appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    }

    private func envLocal(_ folderName: String) -> String {
        (try? String(contentsOf: folder(folderName).appendingPathComponent(".env.local"), encoding: .utf8)) ?? ""
    }

    /// A supervisor with the apps of `profile`. `running` marks every service as
    /// running and the stack healthy, with no process: a switch then starts the
    /// processes it restarts.
    private func makeSupervisor(profile: RunProfile = .both, running: Bool) throws {
        let suite = "ModeSwitchTests-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        supervisor = EnvironmentSupervisor(
            userDefaults: defaults, tools: .shared,
            logSink: LogFileSink(directory: root.appendingPathComponent("logs"), version: "9.9.9")
        )
        supervisor.portTools = PortTools(listeners: { _ in [] }, kill: { _ in }, killCommands: { _ in })
        supervisor.diagnosticsTools = { _ in [] }
        supervisor.siblingActiveServices = { [] }
        supervisor.dependencyRecord = DependencyRecord(path: root.appendingPathComponent("config/deps.json").path)
        supervisor.shell = FakeCommandRunner { call in
            if call.command.contains("local-db.sh status") { return FakeCommandRunner.ok(Self.statusEnv) }
            return FakeCommandRunner.ok()
        }
        supervisor.findLanAddress = { LanAddress(interface: "en0", ip: Self.lanIP) }
        supervisor.onFeedback = { [weak self] in self?.feedback.append(($0.message, $0.style != .error)) }

        try supervisor.loadServices([
            daemon("supabase", "monolith"),
            daemon("travel-portal", "booking"),
            daemon("partner-portal", "partner"),
            daemon("universal-login", "login"),
            daemon("worker", "worker"),
        ], profile: profile)
        guard running else { return }
        for id in supervisor.serviceStates.keys { supervisor.serviceStates[id]?.phase = .running }
        supervisor.health = .healthy
    }

    private func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    /// Stops the stack and waits for the stop to end. The stop task sets health to
    /// stopped and then writes the env files in the same turn, so health is moved off
    /// stopped first: seeing it stopped again means that write is done.
    private func stop(_ supervisor: EnvironmentSupervisor) async {
        supervisor.health = .degraded
        supervisor.stopAll()
        let stopped = await waitUntil(10) { supervisor.health == .stopped }
        XCTAssertTrue(stopped, "stop did not end")
    }

    /// Waits a short time for a switch that should start nothing, then checks that it
    /// did not: its task runs only after the call returns.
    private func assertNothingStarted(_ name: String) async {
        let started = await waitUntil(1) {
            !self.restarted.isEmpty || !self.feedback.isEmpty || !self.supervisor.actionsInFlight.isEmpty
        }
        XCTAssertFalse(started, name)
        XCTAssertEqual(restarted, [], name)
        XCTAssertTrue(feedback.isEmpty, name)
        XCTAssertTrue(supervisor.actionsInFlight.isEmpty, name)
    }

    /// The services a switch started a process for.
    private var restarted: [String] {
        supervisor.serviceStates.values.filter { $0.lastStarted != nil }.map(\.id).sorted()
    }

    /// Waits for the switch to end. Its task begins after the call returns, and
    /// its last act is the feedback.
    private func settle(_ key: String) async {
        let done = await waitUntil(20) { !self.feedback.isEmpty && !self.supervisor.actionsInFlight.contains(key) }
        XCTAssertTrue(done, "\(key) did not end")
    }

    /// The database control: a switch to the other mode (E3 `setDatabaseMode`).
    private func toggleDatabaseMode() {
        supervisor.setDatabaseMode(supervisor.dbMode == .local ? .remote : .local)
    }

    private func hostedEnvFiles() throws {
        try sharedEnv("booking", ["AMATEUR_SUPABASE_URL=https://hosted.example.test"])
        try sharedEnv("partner", [
            "AMATEUR_SUPABASE_URL=https://hosted.example.test",
            "LOGIN_URL=https://login.example.test/login/init",
        ])
    }

    // MARK: - Database mode

    /// A switch that cannot happen changes nothing: no mode, no env file, no process.
    func testEachRefusedDatabaseSwitchChangesNothing() async throws {
        let hosted = "https://hosted.example.test"
        // `urls`: the AMATEUR_SUPABASE_URL of each app's shared .env.
        let rows: [(name: String, profile: RunProfile, urls: [String: String], health: HealthStatus, error: String)] = [
            ("the booking portal has no shared .env", .booking, [:], .stopped,
             "Hosted dev values are missing from apps/booking-portal/.env — import the shared file "
                + "(Settings → Reconfigure Repos… → Environment Check), then switch again"),
            ("both portals have no shared .env", .both, [:], .stopped,
             "Hosted dev values are missing from apps/booking-portal/.env and apps/partner-portal/.env — import the shared file "
                + "(Settings → Reconfigure Repos… → Environment Check), then switch again"),
            ("the partner portal's shared .env has no hosted URL", .both, ["booking": hosted, "partner": ""], .stopped,
             "Hosted dev values are missing from apps/partner-portal/.env — import the shared file "
                + "(Settings → Reconfigure Repos… → Environment Check), then switch again"),
        ]
        for row in rows {
            try? FileManager.default.removeItem(at: folder("booking").appendingPathComponent(".env"))
            try? FileManager.default.removeItem(at: folder("partner").appendingPathComponent(".env"))
            for (name, url) in row.urls { try sharedEnv(name, ["AMATEUR_SUPABASE_URL=\(url)"]) }
            try makeSupervisor(profile: row.profile, running: false)
            supervisor.health = row.health

            toggleDatabaseMode()

            XCTAssertEqual(supervisor.dbMode, .local, row.name)
            XCTAssertEqual(supervisor.lastError, row.error, row.name)
            XCTAssertEqual(envLocal("booking"), "", row.name)
            XCTAssertEqual(envLocal("login"), "", row.name)
            await assertNothingStarted(row.name)
            supervisor.health = .stopped
        }
    }

    /// Stopped: the switch writes the env files for the next start and starts nothing.
    func testASwitchWhileStoppedWritesTheEnvAndStartsNothing() async throws {
        try hostedEnvFiles()
        try makeSupervisor(running: false)

        toggleDatabaseMode()

        XCTAssertEqual(supervisor.dbMode, .remote, supervisor.lastError ?? "")
        XCTAssertNil(supervisor.lastError)
        let booking = envLocal("booking")
        XCTAssertTrue(booking.contains(RunnerEnv.beginMarker), booking)
        XCTAssertFalse(booking.contains("AMATEUR_SUPABASE_URL"), "dev mode leaves Supabase to the shared .env")
        XCTAssertFalse(booking.contains("NEXT_PUBLIC_LOCAL_DEV"), booking)
        XCTAssertTrue(booking.contains("LOGIN_URL=https://login.example.test/login/init"), "booking borrows partner's login")
        XCTAssertTrue(envLocal("login").contains("AMATEUR_SUPABASE_URL=https://hosted.example.test"))
        await assertNothingStarted("to dev")
        XCTAssertEqual(supervisor.health, .stopped)

        // And back: the local block returns, still with no start.
        toggleDatabaseMode()

        XCTAssertEqual(supervisor.dbMode, .local)
        let local = envLocal("booking")
        XCTAssertTrue(local.contains("NEXT_PUBLIC_LOCAL_DEV=true"), local)
        XCTAssertTrue(local.contains("LOGIN_URL=http://localhost:3000/login/init"), local)
        await assertNothingStarted("to local")
        XCTAssertEqual(supervisor.health, .stopped)
    }

    /// Running: each switch restarts the apps that read the database, and only them.
    func testEachSwitchWhileRunningRestartsTheAppsOfTheProfile() async throws {
        try hostedEnvFiles()
        let rows: [(name: String, profile: RunProfile, from: EnvironmentSupervisor.DatabaseMode,
                    restarts: [String], feedback: String)] = [
            ("local to dev, both portals", .both, .local,
             ["partner-portal", "travel-portal", "universal-login"], "Database mode: dev"),
            ("local to dev, booking only", .booking, .local,
             ["travel-portal", "universal-login"], "Database mode: dev"),
            ("dev to local, both portals", .both, .remote,
             ["partner-portal", "travel-portal", "universal-login"], "Database mode: local"),
        ]
        for row in rows {
            try makeSupervisor(profile: row.profile, running: true)
            supervisor.dbMode = row.from

            toggleDatabaseMode()
            await settle("db-mode")

            XCTAssertEqual(supervisor.dbMode, row.from == .local ? .remote : .local, row.name)
            XCTAssertEqual(restarted, row.restarts, row.name)
            for id in row.restarts {
                XCTAssertEqual(supervisor.serviceStates[id]?.phase, .running, "\(row.name): \(id)")
            }
            XCTAssertEqual(supervisor.serviceStates["worker"]?.phase, .running, row.name)
            XCTAssertEqual(feedback.map(\.text), [row.feedback], row.name)
            XCTAssertEqual(feedback.map(\.ok), [true], row.name)
            XCTAssertNil(supervisor.lastError, row.name)
            if row.from == .remote {
                // The portal does not start without the local stack's keys; the switch read them.
                XCTAssertTrue(envLocal("booking").contains("LOCAL_SUPABASE_ANON_KEY=anon-test"), row.name)
            }
            await stop(supervisor)
            feedback = []
        }
    }

    /// A portal that cannot restart in the new mode fails with the cause, and the
    /// feedback says the switch hit errors.
    func testASwitchToLocalWithoutTheLocalKeysFailsThePortals() async throws {
        try makeSupervisor(profile: .booking, running: true)
        supervisor.shell = FakeCommandRunner { _ in FakeCommandRunner.failed(1) }
        supervisor.dbMode = .remote

        toggleDatabaseMode()
        await settle("db-mode")

        XCTAssertEqual(supervisor.dbMode, .local)
        XCTAssertEqual(supervisor.serviceStates["travel-portal"]?.phase, .failed)
        XCTAssertEqual(supervisor.serviceStates["universal-login"]?.phase, .running)
        XCTAssertTrue(
            supervisor.lastError?.hasPrefix("DB mode switch failed for travel-portal:") == true,
            supervisor.lastError ?? "nil"
        )
        XCTAssertEqual(feedback.map(\.text), ["Database mode switch hit errors — check Status"])
        XCTAssertEqual(feedback.map(\.ok), [false])
    }

    // MARK: - LAN mode

    /// LAN on writes the address of this Mac into the env, LAN off writes localhost,
    /// and each restarts the apps that serve pages.
    func testEachLanSwitchWritesTheHostAndRestartsTheApps() async throws {
        try makeSupervisor(profile: .both, running: true)
        // The local stack's keys, so the portals start in local mode.
        await supervisor.refreshLocalSupabaseKeys()
        let rows: [(name: String, host: String, feedback: String, log: String)] = [
            ("on", Self.lanIP, "LAN mode on — open http://\(Self.lanIP):3002 on your phone",
             "[travel-runner] Network mode ON — http://\(Self.lanIP)"),
            ("off", "localhost", "LAN mode off — localhost only", "[travel-runner] Network mode OFF — localhost only"),
        ]
        for row in rows {
            for id in supervisor.serviceStates.keys { supervisor.serviceStates[id]?.lastStarted = nil }
            feedback = []

            supervisor.toggleNetworkMode()
            await settle("lan-mode")

            XCTAssertEqual(supervisor.networkMode, row.name == "on", row.name)
            XCTAssertEqual(restarted, ["partner-portal", "travel-portal", "universal-login"], row.name)
            XCTAssertTrue(envLocal("booking").contains("NEXT_PUBLIC_WEBAPP_URL=http://\(row.host):3002"), row.name)
            XCTAssertTrue(envLocal("partner").contains("NEXT_PUBLIC_WEBAPP_URL=http://\(row.host):3006"), row.name)
            XCTAssertTrue(envLocal("login").contains("NEXT_PUBLIC_SITE_URL=http://\(row.host):3000"), row.name)
            XCTAssertEqual(feedback.map(\.text), [row.feedback], row.name)
            let lines = await supervisor.logStore.entries(for: "travel-portal").map(\.text)
            XCTAssertTrue(lines.contains(row.log), "\(row.name): \(lines)")
        }
    }
}
