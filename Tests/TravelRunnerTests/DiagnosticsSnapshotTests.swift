import Foundation
import XCTest
@testable import TravelRunner

final class DiagnosticsSnapshotTests: XCTestCase {

    /// A snapshot with one of each part.
    static func sample(lastError: String? = nil) -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            generatedAt: "2026-11-16T09:14:03Z",
            app: DiagnosticsSnapshot.App(
                BuildInfo(version: "0.13.5", build: "202611160914", commit: "a1b2c3d", kind: .release, flavor: .standard)
            ),
            machine: DiagnosticsSnapshot.Machine(macOS: "Version 15.1 (Build 24B83)", arch: "arm64", rosetta: false),
            tools: [],
            toolPath: "~/.nvm/versions/node/v22.11.0/bin:/usr/bin",
            profile: "both",
            dbMode: "local",
            health: "DEGRADED",
            lastError: lastError,
            preflight: [DiagnosticsSnapshot.Check(id: "docker", name: "Docker", result: .passed(detail: "OrbStack"))],
            dbPipeline: DiagnosticsSnapshot.DbPipeline(
                profile: "fast", seedScenario: "default", running: false,
                steps: [DiagnosticsSnapshot.DbStep(id: "seed", name: "Seed", status: "FAILED", optional: false, error: "Exit code 1")]
            ),
            pendingMigrations: ["20261101000000_add_holds"],
            repoPaths: ["monorepo": "~/code/fb-travel-monolith"],
            gitBranches: ["travel-portal": "dev"],
            services: [
                DiagnosticsSnapshot.Service(
                    id: "supabase", phase: "RUNNING", inProfile: true, pid: 10, exitCode: nil,
                    restartCount: 0, circuitBroken: false, uptimeSeconds: 30
                ),
            ]
        )
    }

    // MARK: - Paths

    func testPathsUnderHomeStartWithATilde() {
        let home = "/Users/teammate"
        XCTAssertEqual(DiagnosticsSnapshot.tilde("/Users/teammate/code/mono", home: home), "~/code/mono")
        XCTAssertEqual(DiagnosticsSnapshot.tilde("/Users/teammate", home: home), "~")
        XCTAssertEqual(DiagnosticsSnapshot.tilde("/Users/teammate/", home: home + "/"), "~/")
        XCTAssertEqual(DiagnosticsSnapshot.tilde("/opt/homebrew/bin/node", home: home), "/opt/homebrew/bin/node")
        // Another user whose name starts the same is not this home.
        XCTAssertEqual(DiagnosticsSnapshot.tilde("/Users/teammate2/x", home: home), "/Users/teammate2/x")
        XCTAssertEqual(
            DiagnosticsSnapshot.tilde("/Users/teammate/.nvm/bin:/usr/bin:/Users/teammate/Library/pnpm", home: home),
            "~/.nvm/bin:/usr/bin:~/Library/pnpm"
        )
    }

    func testRepoPathsHaveATildeAndLeaveOutWhatIsNotSet() {
        let paths = RepoPaths(
            monorepo: "/Users/teammate/code/fb-travel-monolith",
            universalLogin: "",
            streamServices: nil,
            loadTest: "/Volumes/work/load-test"
        )
        XCTAssertEqual(
            DiagnosticsSnapshot.repoPaths(paths, home: "/Users/teammate"),
            ["monorepo": "~/code/fb-travel-monolith", "load_test": "/Volumes/work/load-test"]
        )
        XCTAssertEqual(DiagnosticsSnapshot.repoPaths(nil, home: "/Users/teammate"), [:])
    }

    // MARK: - Parts

    func testEachPreflightResultHasItsStatus() {
        typealias Check = DiagnosticsSnapshot.Check
        XCTAssertEqual(Check(id: "a", name: "A", result: .pending).status, "pending")
        let passed = Check(id: "a", name: "A", result: .passed(detail: "v22"))
        XCTAssertEqual([passed.status, passed.message], ["passed", "v22"])
        let warning = Check(id: "a", name: "A", result: .warning(message: "old"))
        XCTAssertEqual([warning.status, warning.message], ["warning", "old"])
        let failed = Check(id: "a", name: "A", result: .failed(message: "missing", fix: "brew install x"))
        XCTAssertEqual([failed.status, failed.message, failed.fix], ["failed", "missing", "brew install x"])
    }

    func testAToolSaysWhereItCameFrom() {
        let home = "/Users/teammate"
        func tool(_ origin: ToolReport.Origin?, path: String? = "/Users/teammate/.nvm/v22/bin/node") -> DiagnosticsSnapshot.Tool {
            DiagnosticsSnapshot.Tool(
                ToolReport(name: "node", path: path, version: "22.11.0", origin: origin, searchedPath: "/usr/bin"),
                home: home
            )
        }
        XCTAssertEqual(tool(.rcFile("~/.zshrc", manager: "nvm")).source, "~/.zshrc (nvm)")
        XCTAssertEqual(tool(.rcFile("~/.zshrc", manager: nil)).source, "~/.zshrc")
        XCTAssertEqual(tool(.loginShell).source, "login shell")
        XCTAssertEqual(tool(.runner).source, "runner")
        XCTAssertEqual(tool(.runner).path, "~/.nvm/v22/bin/node")

        let unread = DiagnosticsSnapshot.Tool(
            ToolReport(name: "docker", path: nil, version: nil, origin: nil, searchedPath: "", problem: "the shell did not answer in 10 s"),
            home: home
        )
        XCTAssertNil(unread.path)
        XCTAssertNil(unread.source)
        XCTAssertEqual(unread.problem, "the shell did not answer in 10 s")
    }

    // MARK: - Redaction and the file

    func testRedactionTakesTheSecretOutOfEachFreeTextField() {
        let key = "sk_" + "test_" + "51AbCdEfGhIjKlMn"
        var snapshot = Self.sample(lastError: "Stripe failed: \(key)")
        snapshot.preflight = [
            DiagnosticsSnapshot.Check(id: "s", name: "Stripe", result: .failed(message: "key \(key)", fix: "stripe login \(key)")),
        ]
        snapshot.dbPipeline?.steps[0].error = "Exit code 1: \(key)"

        let redacted = snapshot.redacted(by: .patterns)

        let encoded = String(decoding: try! JSONEncoder().encode(redacted), as: UTF8.self)
        XCTAssertFalse(encoded.contains(key), encoded)
        XCTAssertEqual(redacted.lastError, "Stripe failed: ‹redacted:stripe-key›")
        XCTAssertEqual(redacted.dbPipeline?.steps.first?.error, "Exit code 1: ‹redacted:stripe-key›")
        XCTAssertEqual(redacted.services, snapshot.services)
        XCTAssertEqual(redacted.app, snapshot.app)
    }

    func testTheFileHasSnakeCaseKeysAndReadsBack() throws {
        let snapshot = Self.sample()
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["generated_at", "app", "machine", "tools", "tool_path", "profile", "db_mode", "health", "preflight",
                    "db_pipeline", "pending_migrations", "repo_paths", "git_branches", "services"] {
            XCTAssertNotNil(object[key], key)
        }
        let app = try XCTUnwrap(object["app"] as? [String: Any])
        XCTAssertEqual(app["version"] as? String, "0.13.5")
        XCTAssertEqual(app["build_kind"] as? String, "release")
        let machine = try XCTUnwrap(object["machine"] as? [String: Any])
        XCTAssertEqual(machine["macos"] as? String, "Version 15.1 (Build 24B83)")
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticsSnapshot.self, from: data), snapshot)
    }

    func testThisMacHasAnArchitecture() {
        let machine = DiagnosticsSnapshot.Machine.current
        XCTAssertTrue(["arm64", "x86_64"].contains(machine.arch), machine.arch)
        XCTAssertFalse(machine.macOS.isEmpty)
    }

    // MARK: - The supervisor's snapshot

    @MainActor
    func testTheSupervisorSnapshotHasTheStackAndReadsTheToolsOnce() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DiagnosticsSnapshotTests-\(UUID().uuidString)"))
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        let reads = ReadCounter()
        supervisor.diagnosticsTools = { _ in
            reads.increment()
            return [ToolReport(
                name: "node", path: "/Users/teammate/.nvm/v22/bin/node", version: "22.11.0",
                origin: .rcFile("~/.zshrc", manager: "nvm"), searchedPath: "/Users/teammate/.nvm/v22/bin:/usr/bin"
            )]
        }
        supervisor.dbMode = .local
        supervisor.pendingMigrations = ["20261101000000_add_holds"]
        supervisor.notices.post(.dbSetup, "DB setup failed at Seed")
        let check = PreflightCheck(id: "docker", name: "Docker")
        check.result = .failed(message: "Docker is not running", fix: "Open OrbStack")
        supervisor.preflightChecks = [check]
        let scenario = DbSeedScenario(id: "default", name: "Default", description: "", fileSummary: "", variables: [])
        let pipeline = DbSetupPipeline(profile: "fast", seedScenario: scenario)
        let step = DbSetupStep(
            id: "seed", name: "Seed", command: "true", healthCheckCommand: nil, timeoutSeconds: 60, isOptional: false, stepNumber: 1
        )
        step.status = .failed
        step.errorMessage = "Exit code 1"
        pipeline.steps = [step]
        supervisor.dbSetupPipeline = pipeline
        let state = ServiceState(definition: ServiceDefinition(
            id: "supabase", name: nil, cmd: ["true"], cwd: nil, probe: nil, type: .daemon,
            restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        ))
        state.phase = .failed
        state.exitCode = 1
        state.restartCount = 2
        supervisor.serviceStates = ["supabase": state]

        let snapshot = await supervisor.diagnosticsSnapshot(home: "/Users/teammate")

        XCTAssertEqual(snapshot.app, DiagnosticsSnapshot.App(.current))
        XCTAssertEqual(snapshot.dbMode, "local")
        XCTAssertEqual(snapshot.profile, supervisor.profile.rawValue)
        XCTAssertEqual(snapshot.lastError, "DB setup failed at Seed")
        XCTAssertEqual(snapshot.pendingMigrations, ["20261101000000_add_holds"])
        XCTAssertEqual(snapshot.preflight.map(\.status), ["failed"])
        XCTAssertEqual(snapshot.preflight.first?.fix, "Open OrbStack")
        XCTAssertEqual(snapshot.dbPipeline?.profile, "fast")
        XCTAssertEqual(snapshot.dbPipeline?.seedScenario, "default")
        XCTAssertEqual(snapshot.dbPipeline?.steps.map(\.status), ["FAILED"])
        XCTAssertEqual(snapshot.dbPipeline?.steps.first?.error, "Exit code 1")
        XCTAssertEqual(snapshot.services.map(\.id), ["supabase"])
        XCTAssertEqual(snapshot.services.first?.phase, "FAILED")
        XCTAssertEqual(snapshot.services.first?.exitCode, 1)
        XCTAssertEqual(snapshot.services.first?.restartCount, 2)
        XCTAssertEqual(snapshot.tools.first?.path, "~/.nvm/v22/bin/node")
        XCTAssertEqual(snapshot.tools.first?.source, "~/.zshrc (nvm)")
        XCTAssertEqual(snapshot.toolPath, "~/.nvm/v22/bin:/usr/bin")

        // A crash loop files many issues: the tools are read once.
        _ = await supervisor.diagnosticsSnapshot(home: "/Users/teammate")
        XCTAssertEqual(reads.value, 1)
    }

    /// A tool that was not read is read again at the next snapshot.
    @MainActor
    func testAToolThatWasNotReadIsReadAgain() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DiagnosticsSnapshotTests-\(UUID().uuidString)"))
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        let reads = ReadCounter()
        supervisor.diagnosticsTools = { _ in
            reads.increment()
            return [ToolReport(name: "docker", path: nil, version: nil, origin: nil, searchedPath: "", problem: "timed out")]
        }

        _ = await supervisor.diagnosticsSnapshot()
        _ = await supervisor.diagnosticsSnapshot()

        XCTAssertEqual(reads.value, 2)
    }

    // MARK: - The bundle

    private static func service(_ id: String, phase: String, circuitBroken: Bool = false) -> DiagnosticsSnapshot.Service {
        DiagnosticsSnapshot.Service(
            id: id, phase: phase, inProfile: true, pid: nil, exitCode: nil,
            restartCount: 0, circuitBroken: circuitBroken, uptimeSeconds: nil
        )
    }

    private static func entries(_ count: Int, prefix: String = "line") -> [LogEntry] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return (0..<count).map { LogEntry(timestamp: start.addingTimeInterval(Double($0)), stream: .stdout, text: "\(prefix) \($0)") }
    }

    func testTheBundleTakesTheLogsOfFailedServicesAndSteps() {
        var snapshot = Self.sample()
        snapshot.services = [
            Self.service("supabase", phase: "RUNNING"),
            Self.service("travel-portal", phase: "FAILED"),
            Self.service("stripe", phase: "STOPPED", circuitBroken: true),
        ]
        snapshot.dbPipeline?.steps = [
            DiagnosticsSnapshot.DbStep(id: "start-supabase", name: "Start", status: "COMPLETED", optional: false, error: nil),
            DiagnosticsSnapshot.DbStep(id: "load-hotels", name: "Load hotels", status: "TIMED_OUT", optional: false, error: nil),
            DiagnosticsSnapshot.DbStep(id: "seed", name: "Seed", status: "FAILED", optional: false, error: "Exit code 1"),
        ]
        XCTAssertEqual(
            DiagnosticsBundle.failedLogIDs(in: snapshot),
            ["travel-portal", "stripe", "db-setup-load-hotels", "db-setup-seed"]
        )

        let bundle = DiagnosticsBundle.make(
            snapshot: snapshot, redactor: .patterns,
            logs: [
                "supabase": Self.entries(5),
                "travel-portal": Self.entries(300),
                "db-setup-seed": Self.entries(3),
            ],
            timeZone: TimeZone(identifier: "UTC")!
        )

        // A healthy service and a log id with no lines are left out.
        XCTAssertEqual(bundle.logs.keys.sorted(), ["db-setup-seed", "travel-portal"])
        let portal = bundle.logs["travel-portal"] ?? []
        XCTAssertEqual(portal.count, DiagnosticsBundle.maxLogLines)
        XCTAssertEqual(DiagnosticsBundle.maxLogLines, 200)
        XCTAssertEqual(portal.first, "\(Self.time(100)) [out] line 100")
        XCTAssertEqual(portal.last, "\(Self.time(299)) [out] line 299")
    }

    /// `HH:mm:ss.SSS` in UTC of the sample entry at `offset` seconds.
    private static func time(_ offset: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: Date(timeIntervalSince1970: 1_800_000_000 + Double(offset)))
    }

    func testTheBundleMasksSecretsInTheLogsAndTheSnapshot() throws {
        let key = "sk_" + "test_" + "51AbCdEfGhIjKlMn"
        var snapshot = Self.sample(lastError: "Stripe failed: \(key)")
        snapshot.services = [Self.service("stripe", phase: "FAILED")]
        let bundle = DiagnosticsBundle.make(
            snapshot: snapshot, redactor: .patterns,
            logs: ["stripe": [LogEntry(stream: .stderr, text: "auth with \(key) failed")]],
            rootCause: "Stripe key \(key)",
            configIssues: ["bad key \(key)"]
        )

        let json = bundle.json()
        XCTAssertFalse(json.contains(key), json)
        XCTAssertTrue(bundle.logs["stripe"]?.first?.hasSuffix("[err] auth with ‹redacted:stripe-key› failed") == true)
        XCTAssertEqual(bundle.snapshot.lastError, "Stripe failed: ‹redacted:stripe-key›")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        for key in ["snapshot", "logs", "root_cause", "config_issues"] {
            XCTAssertNotNil(object[key], key)
        }
        XCTAssertEqual(try JSONDecoder().decode(DiagnosticsBundle.self, from: Data(json.utf8)), bundle)
    }

    @MainActor
    func testTheSupervisorBundleHasTheFailedServiceLog() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DiagnosticsSnapshotTests-\(UUID().uuidString)"))
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        supervisor.diagnosticsTools = { _ in [] }
        let failed = Self.definition("travel-portal")
        let healthy = Self.definition("supabase")
        try supervisor.loadServices([healthy, failed])
        supervisor.serviceStates["travel-portal"]?.phase = .failed
        for entry in Self.entries(250, prefix: "portal") {
            await supervisor.logStore.append(serviceID: "travel-portal", entry: entry)
        }
        await supervisor.logStore.append(serviceID: "supabase", entry: LogEntry(stream: .stdout, text: "ready"))

        let json = await supervisor.diagnosticsBundleJSON(home: "/Users/teammate")
        let bundle = try JSONDecoder().decode(DiagnosticsBundle.self, from: Data(json.utf8))

        XCTAssertEqual(bundle.logs.keys.sorted(), ["travel-portal"])
        XCTAssertEqual(bundle.logs["travel-portal"]?.count, 200)
        XCTAssertTrue(bundle.logs["travel-portal"]?.last?.hasSuffix("portal 249") == true)
        XCTAssertEqual(bundle.snapshot.services.map(\.id).sorted(), ["supabase", "travel-portal"])
    }

    // MARK: - Run Checks Now

    private static func definition(_ id: String, cwd: String? = nil, port: Int? = nil) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: nil, cmd: ["true"], cwd: cwd,
            probe: port.map { ProbeConfig(type: .tcp, port: $0, host: nil, url: nil, pattern: nil, artifact: nil, timeout: 5) },
            type: .daemon, restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
    }

    /// The checks run and show their reasons; nothing starts.
    @MainActor
    func testRunChecksNowRunsTheChecksWithoutAStart() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DiagnosticsSnapshotTests-\(UUID().uuidString)"))
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        let shell = FakeCommandRunner { call in
            call.command.contains("node --version") ? FakeCommandRunner.ok("v22.11.0") : FakeCommandRunner.ok()
        }
        supervisor.shell = shell
        let missing = "/nonexistent-\(UUID().uuidString)"
        try supervisor.loadServices([Self.definition("api", cwd: missing)])
        let phaseBefore = supervisor.serviceStates["api"]?.phase

        await supervisor.runPreflightOnly()

        let dir = try XCTUnwrap(supervisor.preflightChecks.first { $0.id.hasPrefix("dir-") })
        guard case .failed(let message, _) = dir.result else {
            return XCTFail("the folder check is \(dir.result)")
        }
        XCTAssertTrue(message.contains("Directory not found"), message)
        XCTAssertFalse(supervisor.preflightChecks.contains { if case .pending = $0.result { true } else { false } })
        XCTAssertFalse(supervisor.preflightOnlyRunning)
        XCTAssertEqual(supervisor.health, .stopped)
        XCTAssertEqual(supervisor.serviceStates["api"]?.phase, phaseBefore)
    }
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
