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
}

private final class ReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
