import Foundation
import XCTest
@testable import TravelRunner

/// Finding ux-db-step-diagnostics and the runner half of the hotel error findings:
/// a failed DB step says what happened and what to do, and the fallback is a line
/// that says something, not "Exit code 1: Node.js v20".
final class DbSetupDiagnosticsTests: XCTestCase {
    /// The Node error shape of the finding: the cause, its stack, then the version banner.
    private let nodeCrash = [
        "file:///repo/scripts/db/load-hotels.mjs:12",
        "    throw new Error(\"relation fb_travel.travel_organizations does not exist\");",
        "    ^",
        "",
        "Error: relation fb_travel.travel_organizations does not exist",
        "    at main (file:///repo/scripts/db/load-hotels.mjs:12:11)",
        "    at ModuleJob.run (node:internal/modules/esm/module_job:195:25)",
        "",
        "Node.js v20.11.0",
    ]

    func testTheFallbackSkipsTheNodeBannerAndTheStackFrames() {
        let diagnosis = DbSetupDiagnostics.diagnose(
            stepID: "verify-data", output: nodeCrash, exitCode: 1, scriptMessage: nil
        )
        XCTAssertEqual(diagnosis.message, "Exit code 1: Error: relation fb_travel.travel_organizations does not exist")
        XCTAssertEqual(diagnosis.guidance, DbSetupDiagnostics.retryGuidance)
        XCTAssertEqual(diagnosis.action, .retryFromStep)

        // Control: a plain last line is the line itself.
        let plain = DbSetupDiagnostics.diagnose(
            stepID: "verify-data", output: ["rows: 0", "users table is empty"], exitCode: 2, scriptMessage: nil
        )
        XCTAssertEqual(plain.message, "Exit code 2: users table is empty")

        // A step with no output still says something.
        let silent = DbSetupDiagnostics.diagnose(stepID: "verify-data", output: [], exitCode: 1, scriptMessage: nil)
        XCTAssertEqual(silent.message, "Exit code 1, with no output")
        XCTAssertFalse(silent.guidance.isEmpty)
    }

    func testNoiseLines() {
        for line in ["Node.js v22.3.0", "    at foo (bar.js:1:1)", "    ^", "}", "", "   ", "Thrown at:",
                     "node:internal/process/esm_loader:40"] {
            XCTAssertTrue(DbSetupDiagnostics.isNoise(line), line)
        }
        // Negative controls: lines that carry the cause are kept.
        for line in ["Error: boom", "attempt 3 failed", "  code: 'ECONNREFUSED'", "Node.js could not start"] {
            XCTAssertFalse(DbSetupDiagnostics.isNoise(line), line)
        }
    }

    /// The exit codes of the hotel scripts (`scripts/db/README.md`) name the cause
    /// and the fix, also when the script printed no `status:failed` line.
    func testTheHotelExitCodesNameTheCauseAndTheFix() {
        let cases: [(Int32, String, RecoveryAction)] = [
            (10, "No dev credentials: apps/booking-portal/.env is missing AMATEUR_SUPABASE_URL / ANON_KEY / SIGNING_KEY",
             .importSharedEnv),
            (11, "Dev Supabase rejected the signing key (HTTP 401) — your shared .env is out of date", .importSharedEnv),
            (12, "Cannot reach dev Supabase — check network or VPN", .retryFromStep),
            (13, "Hotel download incomplete — nothing was cached", .redownloadHotels),
        ]
        for step in ["check-prerequisites", "fetch-hotels", "load-hotels"] {
            for (code, message, action) in cases {
                let diagnosis = DbSetupDiagnostics.diagnose(
                    stepID: step, output: nodeCrash, exitCode: code, scriptMessage: nil
                )
                XCTAssertEqual(diagnosis.message, message, "\(step) exit \(code)")
                XCTAssertEqual(diagnosis.action, action, "\(step) exit \(code)")
                XCTAssertFalse(diagnosis.guidance.isEmpty)
            }
        }
        let unreachable = DbSetupDiagnostics.diagnose(stepID: "load-hotels", output: [], exitCode: 14, scriptMessage: nil)
        XCTAssertEqual(unreachable.message, "The local database is not reachable, or has no hotel table")

        // Negative control: the same code from a step that is not a hotel step is no hotel cause.
        let other = DbSetupDiagnostics.diagnose(stepID: "reset-database", output: nodeCrash, exitCode: 10, scriptMessage: nil)
        XCTAssertFalse(other.message.contains("credentials"), other.message)
        XCTAssertNotEqual(other.action, .importSharedEnv)
    }

    /// The script's `status:failed` line is the line the user reads. The table adds
    /// what to do; before this, a script message came with no guidance at all.
    func testTheScriptMessageStaysAndGetsGuidance() {
        let line = "Hotels cannot be downloaded yet: Dev Supabase rejected the signing key (HTTP 401). Nothing was reset."
        let diagnosis = DbSetupDiagnostics.diagnose(
            stepID: "check-prerequisites", output: ["checking"], exitCode: 11, scriptMessage: line
        )
        XCTAssertEqual(diagnosis.message, line)
        XCTAssertEqual(diagnosis.guidance, "Import a current shared .env, then retry the step.")
        XCTAssertEqual(diagnosis.action, .importSharedEnv)

        // A script message that no rule knows still gets guidance.
        let unknown = DbSetupDiagnostics.diagnose(
            stepID: "verify-data", output: [], exitCode: 1, scriptMessage: "users table is empty"
        )
        XCTAssertEqual(unknown.message, "users table is empty")
        XCTAssertEqual(unknown.guidance, DbSetupDiagnostics.retryGuidance)
    }

    func testTheRulesOfOneStepAndOfEveryStep() {
        let migration = DbSetupDiagnostics.diagnose(
            stepID: "reset-database",
            output: ["Applying migration 20260101000000_blocks.sql...", "ERROR: insert violates foreign key constraint"],
            exitCode: 1, scriptMessage: nil
        )
        XCTAssertEqual(migration.message, "Migration 20260101000000_blocks.sql: FK constraint violation")

        // The CLI prints each file before it applies it: the last one failed.
        let many = DbSetupDiagnostics.diagnose(
            stepID: "reset-database",
            output: [
                "Applying migration 0001_init.sql...", "Applying migration 0100_hotels.sql...",
                "Applying migration 0150_blocks.sql...", "ERROR: syntax error at or near \"tabel\"",
            ],
            exitCode: 1, scriptMessage: nil
        )
        XCTAssertEqual(many.message, "Migration 0150_blocks.sql failed")

        // Negative control: a seed that fails after every migration applied is no
        // migration failure, and the file of the last migration is not named.
        for seedLine in ["Seeding data from supabase/seed.sql...", "psql:<stdin>:12: ERROR:  duplicate key value"] {
            let seed = DbSetupDiagnostics.diagnose(
                stepID: "reset-database",
                output: ["Applying migration 0001_init.sql...", "Applying migration 0150_blocks.sql...",
                         seedLine, "ERROR: duplicate key value violates unique constraint"],
                exitCode: 1, scriptMessage: nil
            )
            XCTAssertFalse(seed.message.contains("Migration"), seed.message)
            XCTAssertNotEqual(seed.guidance, "Check the migration file for errors (supabase/migrations or the backend baseline).")
        }

        // A cause that every step has wins over the catch-all for a migration.
        let dockerInReset = DbSetupDiagnostics.diagnose(
            stepID: "reset-database",
            output: ["Applying migration 0001_init.sql...",
                     "error: Cannot connect to the Docker daemon. Is the docker daemon running?"],
            exitCode: 1, scriptMessage: nil
        )
        XCTAssertEqual(dockerInReset.message, "Docker is not running")

        let docker = DbSetupDiagnostics.diagnose(
            stepID: "start-supabase",
            output: ["Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"],
            exitCode: 1, scriptMessage: nil
        )
        XCTAssertEqual(docker.message, "Docker is not running")
        XCTAssertEqual(docker.action, .openContainerRuntime)

        let module = DbSetupDiagnostics.diagnose(
            stepID: "verify-data",
            output: ["Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'pg' imported from /repo/x.mjs", "Node.js v20.11.0"],
            exitCode: 1, scriptMessage: nil
        )
        XCTAssertEqual(module.action, .installDependencies)
        XCTAssertTrue(module.message.contains("Cannot find package 'pg'"), module.message)

        let missingDump = DbSetupDiagnostics.diagnose(
            stepID: "load-hotels", output: ["ENOENT: no such file or directory, open 'x.sql'"], exitCode: 1, scriptMessage: nil
        )
        XCTAssertEqual(missingDump.action, .redownloadHotels)

        // Negative control: a refused connection is a local database cause only for
        // the steps that use it. The remote fetch falls through to the log line.
        let refusedLocal = DbSetupDiagnostics.diagnose(
            stepID: "reset-database", output: ["psql: connection refused"], exitCode: 1, scriptMessage: nil
        )
        XCTAssertEqual(refusedLocal.message, "Database connection refused")
        let refusedRemote = DbSetupDiagnostics.diagnose(
            stepID: "fetch-hotels", output: ["urlopen: connection refused"], exitCode: 1, scriptMessage: nil
        )
        XCTAssertEqual(refusedRemote.message, "Exit code 1: urlopen: connection refused")
    }

    /// Every rule of the table gives guidance.
    func testEveryRuleGivesGuidance() {
        for (index, rule) in DbSetupDiagnostics.rules.enumerated() {
            let failure = DbSetupDiagnostics.Failure(
                stepID: rule.steps?.first ?? "any", output: ["Applying migration 1_a.sql error"], exitCode: rule.exitCode ?? 1,
                text: (rule.all + rule.any).joined(separator: " ")
            )
            let diagnosis = rule.diagnose(failure)
            XCTAssertFalse(diagnosis.message.isEmpty, "rule \(index)")
            XCTAssertFalse(diagnosis.guidance.isEmpty, "rule \(index)")
        }
    }

    func testALongLineIsCut() {
        let long = String(repeating: "x", count: 1000)
        let diagnosis = DbSetupDiagnostics.diagnose(stepID: "verify-data", output: [long], exitCode: 1, scriptMessage: nil)
        XCTAssertEqual(diagnosis.message.count, "Exit code 1: ".count + DbSetupDiagnostics.maxLineLength + 1)
    }

    func testTheReportHoldsTheErrorTheGuidanceAndTheWholeLog() {
        let report = DbSetupDiagnostics.report(
            stepName: "Load Hotels", stepID: "load-hotels", status: "FAILED", exitCode: 14,
            error: "The local database is not reachable", guidance: "Run All.", log: ["one", "two"]
        )
        XCTAssertEqual(report, """
        DB step: Load Hotels (load-hotels)
        Status: FAILED
        Exit code: 14
        Error: The local database is not reachable
        What to do: Run All.

        Log:
        one
        two
        """)
    }

    func testTheElapsedTimeIsShownAgainstTheCap() {
        XCTAssertEqual(DbSetupDiagnostics.elapsedLabel(seconds: 65, capSeconds: 900), "1m 05s / 15m")
        XCTAssertEqual(DbSetupDiagnostics.elapsedLabel(seconds: 7, capSeconds: 30), "7s / 30s")
        XCTAssertEqual(DbSetupDiagnostics.elapsedLabel(seconds: 0, capSeconds: 90), "0s / 1m 30s")
    }

    // MARK: - Through the runner

    /// A step that fails gets its message, its guidance and its action from the table.
    @MainActor
    func testAFailedStepGetsTheDiagnosisOfTheTable() async throws {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("DbSetupDiagnosticsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let tools = ToolEnvironment(home: cwd.appendingPathComponent("home").path)
        let launcher = StepLauncher(executable: "/bin/zsh", arguments: { ["-f", "-c", $0] })
        func run(_ id: String, _ command: String) async -> DbSetupStep {
            let step = DbSetupStep(
                id: id, name: id, command: command, healthCheckCommand: nil,
                timeoutSeconds: 10, isOptional: false, stepNumber: 1
            )
            let runner = DbSetupRunner(
                portalCwd: cwd.path, logStore: LogStore(), seedScenarioID: "default", tools: tools,
                shell: FakeCommandRunner(), launcher: launcher
            )
            _ = await runner.executeStepPublic(step)
            return step
        }

        let crashed = await run("verify-data", "echo 'Error: boom'; echo '    at x (y.js:1:1)'; echo 'Node.js v20.11.0'; exit 1")
        XCTAssertEqual(crashed.status, .failed)
        XCTAssertEqual(crashed.errorMessage, "Exit code 1: Error: boom")
        XCTAssertEqual(crashed.recoveryGuidance, DbSetupDiagnostics.retryGuidance)
        XCTAssertEqual(crashed.recoveryAction, .retryFromStep)

        let refused = await run("fetch-hotels", "echo '##db:status:failed:Dev Supabase refused (HTTP 401)'; exit 11")
        XCTAssertEqual(refused.errorMessage, "Dev Supabase refused (HTTP 401)")
        XCTAssertEqual(refused.recoveryGuidance, "Import a current shared .env, then retry the step.")
        XCTAssertEqual(refused.recoveryAction, .importSharedEnv)
        XCTAssertEqual(refused.exitCode, 11)

        // Control: a step that passes has no error, guidance or action.
        let passed = await run("verify-data", "echo fine")
        XCTAssertEqual(passed.status, .passed)
        XCTAssertNil(passed.errorMessage)
        XCTAssertNil(passed.recoveryGuidance)
        XCTAssertNil(passed.recoveryAction)
    }
}
