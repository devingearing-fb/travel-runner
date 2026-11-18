import Foundation
import XCTest
@testable import TravelRunner

/// Start All, one row per way that a teammate's start went wrong. Each row runs
/// a whole Start All of a small stack: a stand-in for Supabase and a service that
/// needs it, both `sleep`. The shell, the database, the reset and the other app
/// are fakes, so no row reads the tools of this Mac, opens a fixed port or
/// touches a database.
@MainActor
final class StartAllTests: XCTestCase {
    private var container: URL!
    private var monorepo: URL!
    private var supervisor: EnvironmentSupervisor!

    override func setUp() async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent("StartAllTests-\(UUID().uuidString)")
        monorepo = container.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith")
        // The backend baseline beside the checkout, with the bootstraps under their real names.
        let backend = container.appendingPathComponent("TRAVEL BOOKING/fb-amateur-backend")
        for name in ["20260909144500_customer_detail_from_checkout.sql", "20260909184456_init-roles.sql",
                     "20260909184457_init-schema.sql", "20261001000000_base.sql"] {
            try migration(name, in: backend)
        }
        try migration("20261014000000_change.sql", in: monorepo)
        try FileManager.default.createDirectory(at: container.appendingPathComponent("web"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        await stop()
        try? FileManager.default.removeItem(at: container)
    }

    // MARK: - Helpers

    private func migration(_ name: String, in checkout: URL) throws {
        let dir = checkout.appendingPathComponent("supabase/migrations")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("select 1;".utf8).write(to: dir.appendingPathComponent(name))
    }

    /// The applied versions of a database that `scripts/local-db.sh` built from
    /// this baseline: the bootstraps under their local versions.
    private let builtByLocalDb: Set<String> = [
        "00000000000000", "00000000000001", "20260909144500", "20261001000000", "20261014000000",
    ]

    /// What one Start All met, and what the fakes saw.
    private final class Run {
        var queries: [String] = []
        var resets = 0
    }

    private struct Setup {
        var node = FakeCommandRunner.ok("v22.3.0\n")
        var dockerAnswers = true
        var siblingServices: [String] = []
        var webFolder = "web"
        var tables = DbQueryResult(exitCode: 0, stdout: "42", stderr: "")
        var applied: Set<String> = []
    }

    private func daemon(_ id: String, cwd: String, phase: String, dependsOn: [String] = []) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: id, cmd: ["sleep", "60"], cwd: cwd, probe: nil, type: .daemon, restart: .never,
            dependsOn: dependsOn, env: nil, phase: phase, reuseIfRunning: nil
        )
    }

    /// A supervisor with the fakes of `setup`, after its Start All has ended.
    private func startAll(_ setup: Setup) async throws -> (run: Run, shell: FakeCommandRunner) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StartAllTests-\(UUID().uuidString)"))
        supervisor = EnvironmentSupervisor(
            userDefaults: defaults, tools: .shared,
            logSink: LogFileSink(directory: container.appendingPathComponent("logs"), version: "9.9.9")
        )
        // No row kills a process or reads the listeners of this Mac.
        supervisor.portTools = PortTools(listeners: { _ in [] }, kill: { _ in }, killCommands: { _ in })
        supervisor.diagnosticsTools = { _ in [] }
        supervisor.secretRegistryPorts = 0...0
        let siblingServices = setup.siblingServices
        supervisor.siblingActiveServices = { siblingServices }
        let (node, docker) = (setup.node, setup.dockerAnswers)
        let shell = FakeCommandRunner { call in
            if call.command == "node --version" { return node }
            if call.command.hasPrefix("docker ps") { return docker ? FakeCommandRunner.ok() : FakeCommandRunner.failed(1) }
            return FakeCommandRunner.ok()
        }
        supervisor.shell = shell
        // A database that does not answer is asked once.
        supervisor.databaseProbeRetry = (.milliseconds(10), .zero)
        let run = Run()
        let (tables, applied) = (setup.tables, setup.applied)
        supervisor.databaseQuery = { _, sql in
            run.queries.append(sql)
            if sql.contains("schema_migrations") {
                return DbQueryResult(exitCode: 0, stdout: applied.sorted().joined(separator: "\n"), stderr: "")
            }
            return tables
        }
        supervisor.dbResetAction = { _ in
            run.resets += 1
            return true
        }
        // The wait for a runtime that does not come up takes no real time.
        if !setup.dockerAnswers { supervisor.clock = FakeClock().clock }

        try supervisor.loadServices([
            daemon("supabase", cwd: monorepo.path, phase: "ground"),
            daemon("web", cwd: container.appendingPathComponent(setup.webFolder).path, phase: "portal", dependsOn: ["supabase"]),
        ])
        supervisor.startAll()
        let ended = await waitUntil(30) {
            self.supervisor.currentPhase == .running
                || (self.supervisor.health == .degraded && self.supervisor.currentPhase == .idle)
        }
        XCTAssertTrue(ended, "Start All did not end: \(supervisor.health), \(supervisor.currentPhase)")
        return (run, shell)
    }

    private func stop() async {
        guard let supervisor else { return }
        supervisor.stopAll()
        _ = await waitUntil(10) { supervisor.health == .stopped }
    }

    private func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private var started: [String] {
        supervisor.serviceStates.values.filter { $0.lastStarted != nil }.map(\.id).sorted()
    }

    // MARK: - Starts that stop before anything runs

    /// Nothing starts, nothing is killed, and the database is not asked.
    func testEachRefusalStartsNothingAndNamesTheCause() async throws {
        let runtime = ContainerRuntime.detect()
        let rows: [(name: String, setup: Setup, error: String)] = [
            ("the other app runs a stack",
             Setup(siblingServices: ["supabase", "travel-portal"]),
             SiblingRunner.refusal(activeServices: ["supabase", "travel-portal"])),
            ("no Node on the PATH of the shell (nvm, fnm, Volta)",
             Setup(node: FakeCommandRunner.failed(127, stderr: "zsh:1: command not found: node")),
             "Preflight failed — Node.js 22+: Node.js not found"),
            ("a Node that hangs",
             Setup(node: FakeCommandRunner.timedOut),
             "Preflight failed — Node.js 22+: node --version did not answer in 20 s"),
            ("a Node that is too old",
             Setup(node: FakeCommandRunner.ok("v16.20.2\n")),
             "Preflight failed — Node.js 22+: v16.20.2 — need 22+"),
            // The Environment Check said "need 22+" and the preflight let Node 20 start: one threshold now.
            ("Node 20",
             Setup(node: FakeCommandRunner.ok("v20.11.1\n")),
             "Preflight failed — Node.js 22+: v20.11.1 — need 22+"),
            ("a container runtime that does not come up",
             Setup(dockerAnswers: false),
             "Preflight failed — \(runtime.displayName): \(runtime.displayName) not responding"),
            ("a service folder that is not there",
             Setup(webFolder: "web-moved"),
             "Preflight failed — web-moved exists: Directory not found — open Settings → Reconfigure Repos"),
            ("two checks fail",
             Setup(node: FakeCommandRunner.ok(""), webFolder: "web-moved"),
             "Preflight failed — Node.js 22+: Node.js not found · web-moved exists: Directory not found — open Settings → Reconfigure Repos"),
        ]
        for row in rows {
            let (run, shell) = try await startAll(row.setup)

            XCTAssertEqual(supervisor.health, .degraded, row.name)
            XCTAssertEqual(supervisor.lastError, row.error, row.name)
            XCTAssertEqual(started, [], row.name)
            XCTAssertEqual(run.queries, [], row.name)
            XCTAssertEqual(run.resets, 0, row.name)
            if row.setup.siblingServices.isEmpty {
                XCTAssertTrue(supervisor.completedPhases.contains("PREFLIGHT"), row.name)
            } else {
                // The other app is asked first: no check runs.
                XCTAssertEqual(shell.commands, [], row.name)
                XCTAssertTrue(supervisor.preflightChecks.isEmpty, row.name)
            }
            await stop()
        }
    }

    // MARK: - Starts that run

    /// The stack starts; only an empty database is set up, and a database that
    /// cannot be read is never reset.
    func testEachDatabaseStateAfterGround() async throws {
        // The baseline of the test is the one beside the checkout.
        try XCTSkipIf(ProcessInfo.processInfo.environment["FB_AMATEUR_BACKEND_DIR"] != nil,
                      "FB_AMATEUR_BACKEND_DIR names another backend baseline")
        let unreadable = DbProbe.unreadableMessage
        let rows: [(name: String, setup: Setup, resets: Int, error: String?)] = [
            ("a database that local-db.sh built",
             Setup(applied: builtByLocalDb), 0, nil),
            ("a database built before local-db.sh renamed the bootstraps",
             Setup(applied: builtByLocalDb.subtracting(["00000000000000", "00000000000001"])
                .union(["20260909184456", "20260909184457"])), 0, nil),
            ("a database ahead of the branch",
             Setup(applied: builtByLocalDb.union(["20270101000000"])), 0, nil),
            ("an empty database",
             Setup(tables: DbQueryResult(exitCode: 0, stdout: "0", stderr: ""), applied: builtByLocalDb), 1, nil),
            ("Docker is down when the database is asked",
             Setup(tables: DbQueryResult(exitCode: 1, stdout: "", stderr: "Cannot connect to the Docker daemon"),
                   applied: builtByLocalDb),
             0, unreadable("Cannot connect to the Docker daemon")),
            ("the database query hangs",
             Setup(tables: DbQueryResult(exitCode: -1, stdout: "", stderr: "The database did not answer in 20 s."),
                   applied: builtByLocalDb),
             0, unreadable("The database did not answer in 20 s.")),
            ("a login profile prints before the answer",
             Setup(tables: DbQueryResult(exitCode: 0, stdout: "compinit: insecure directories\n42", stderr: ""),
                   applied: builtByLocalDb), 0, nil),
        ]
        for row in rows {
            let (run, _) = try await startAll(row.setup)

            XCTAssertEqual(supervisor.health, .healthy, row.name)
            XCTAssertEqual(supervisor.currentPhase, .running, row.name)
            XCTAssertEqual(started, ["supabase", "web"], row.name)
            XCTAssertEqual(run.resets, row.resets, row.name)
            XCTAssertEqual(supervisor.lastError, row.error, row.name)
            XCTAssertFalse(run.queries.isEmpty, row.name)
            XCTAssertEqual(supervisor.pendingMigrations, [], row.name)
            await stop()
        }
    }

    /// Answers of the checks that warn and let the stack start.
    func testEachWarningLetsTheStackStart() async throws {
        let rows: [(name: String, setup: Setup)] = [
            ("a login profile that prints before the Node version",
             Setup(node: FakeCommandRunner.ok("Now using node v22.3.0 (npm v10.8.1)\nv22.3.0\n"), applied: builtByLocalDb)),
        ]
        for row in rows {
            _ = try await startAll(row.setup)

            XCTAssertEqual(supervisor.health, .healthy, "\(row.name): \(supervisor.lastError ?? "")")
            XCTAssertEqual(started, ["supabase", "web"], row.name)
            XCTAssertFalse(supervisor.preflightChecks.contains { $0.result.isFailed }, row.name)
            await stop()
        }
    }
}
