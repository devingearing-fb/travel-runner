import Foundation
import XCTest
@testable import TravelRunner

/// The `##db:` protocol lines that the DB scripts print.
@MainActor
final class DbSetupProtocolTests: XCTestCase {
    private func makeStep() -> DbSetupStep {
        DbSetupStep(id: "reset-database", name: "Reset database", command: "true",
                    healthCheckCommand: nil, timeoutSeconds: 60, isOptional: false, stepNumber: 1)
    }

    func testProgressKeepsTheFractionTheScriptSends() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("progress:0.42:Applying migrations", step: step)
        XCTAssertEqual(step.progress ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(step.progressLabel, "Applying migrations")
    }

    func testProgressCoversTheWholeScale() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("progress:0.00:Starting", step: step)
        XCTAssertEqual(step.progress, 0)
        DbSetupRunner.parseProtocolLine("progress:1.00:Database ready", step: step)
        XCTAssertEqual(step.progress, 1)
    }

    func testProgressIsClampedToZeroAndOne() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("progress:1.7:Too far", step: step)
        XCTAssertEqual(step.progress, 1)
        DbSetupRunner.parseProtocolLine("progress:-0.3:Below zero", step: step)
        XCTAssertEqual(step.progress, 0)
    }

    func testProgressWithoutLabelKeepsTheLastLabel() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("progress:0.10:Loading hotel dump", step: step)
        DbSetupRunner.parseProtocolLine("progress:0.50", step: step)
        XCTAssertEqual(step.progress ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(step.progressLabel, "Loading hotel dump")
    }

    func testLabelMayContainColons() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("progress:0.80:Applying supabase/seed.sql: part 2", step: step)
        XCTAssertEqual(step.progressLabel, "Applying supabase/seed.sql: part 2")
    }

    func testBadProgressValuesChangeNothing() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("progress:0.25:Quarter", step: step)
        for line in ["progress:abc:Bad", "progress:nan:Bad", "progress:inf:Bad", "progress"] {
            DbSetupRunner.parseProtocolLine(line, step: step)
        }
        XCTAssertEqual(step.progress ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(step.progressLabel, "Quarter")
    }

    /// The finding: the bar showed 0% for the whole run, because the view read the
    /// 0-1 fraction as a 0-100 percent. The view shows these two values.
    func testTheBarAndTheLabelReadTheFraction() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("progress:0.42:Applying migrations", step: step)
        let progress = step.progress ?? -1

        XCTAssertEqual(DbSetupStep.percentLabel(progress), "42%")
        XCTAssertEqual(DbSetupStep.barValue(progress), 0.42, accuracy: 0.0001)
        XCTAssertEqual(DbSetupStep.percentLabel(0), "0%")
        XCTAssertEqual(DbSetupStep.percentLabel(1), "100%")
        XCTAssertEqual(DbSetupStep.barValue(1.7), 1)
        XCTAssertEqual(DbSetupStep.barValue(.nan), 0)
    }

    /// 0.29 * 100 is 28.999…, so a label that cuts the fraction said 28%.
    func testTheLabelRoundsEachTwoDecimalFraction() {
        for percent in 0...100 {
            let fraction = Double(String(format: "%.2f", Double(percent) / 100)) ?? -1
            XCTAssertEqual(DbSetupStep.percentLabel(fraction), "\(percent)%")
        }
    }

    func testOtherLineTypesLeaveProgressAlone() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("status:failed:Migration error", step: step)
        DbSetupRunner.parseProtocolLine("health:pass:42 tables", step: step)
        XCTAssertNil(step.progress)
        XCTAssertEqual(step.errorMessage, "Migration error")
        XCTAssertEqual(step.healthResult, "42 tables")
    }

    func testAFailedStatusNamesEveryHealthFailure() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("health:fail:Docker is not running", step: step)
        DbSetupRunner.parseProtocolLine("health:fail:PyJWT not installed", step: step)
        DbSetupRunner.parseProtocolLine("status:failed:2 prerequisite(s) missing", step: step)
        XCTAssertEqual(step.errorMessage,
                       "2 prerequisite(s) missing: Docker is not running; PyJWT not installed")
    }

    func testHealthFailuresAloneAreAllKept() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("health:fail:Docker is not running", step: step)
        DbSetupRunner.parseProtocolLine("health:fail:PyJWT not installed", step: step)
        XCTAssertEqual(step.errorMessage, "Health check: Docker is not running; PyJWT not installed")
        XCTAssertNil(step.healthResult)
    }

    func testAFailedStatusThatAlreadyNamesTheFailuresIsNotRepeated() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("health:fail:Docker is not running", step: step)
        DbSetupRunner.parseProtocolLine("health:fail:PyJWT not installed", step: step)
        DbSetupRunner.parseProtocolLine(
            "status:failed:Missing: Docker is not running; PyJWT not installed", step: step)
        XCTAssertEqual(step.errorMessage, "Missing: Docker is not running; PyJWT not installed")
    }

    func testAFailedStatusWithoutHealthFailuresIsUnchanged() {
        let step = makeStep()
        DbSetupRunner.parseProtocolLine("status:failed:Migration error", step: step)
        XCTAssertEqual(step.errorMessage, "Migration error")
    }

    // MARK: - Environment checks

    func testPyJWTIsNotARequiredCheck() throws {
        // A checkout from before the .env dump scripts: its prerequisite check asks for PyJWT.
        let mono = FileManager.default.temporaryDirectory.appendingPathComponent("pyjwt-\(UUID().uuidString)")
        let scripts = mono.appendingPathComponent("scripts/db")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mono) }
        try "console.log(\"  PyJWT: OK\");\n".write(
            to: scripts.appendingPathComponent("check-prerequisites.mjs"), atomically: true, encoding: .utf8
        )
        let checker = EnvironmentChecker(monorepoPath: mono.path, loginPath: "/nonexistent/login",
                                         streamServicesPath: "/nonexistent/stream")
        checker.buildChecks()
        let check = try XCTUnwrap(checker.checks.first { $0.id == "python-jwt" })
        XCTAssertFalse(check.isRequired)
        XCTAssertFalse(EnvironmentChecker.pyJWTFixCommand.contains("pip3 install pyjwt"))
        // Negative control: a real prerequisite stays required.
        let node = try XCTUnwrap(checker.checks.first { $0.id == "node" })
        XCTAssertTrue(node.isRequired)
    }

    /// The newer database scripts sign the token with Node: the row would only warn about nothing.
    func testACheckoutWithoutPyJWTInItsScriptsHasNoPyJWTRow() throws {
        let mono = FileManager.default.temporaryDirectory.appendingPathComponent("pyjwt-\(UUID().uuidString)")
        let scripts = mono.appendingPathComponent("scripts/db")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mono) }
        try "console.log(\"  Docker: OK\");\n".write(
            to: scripts.appendingPathComponent("check-prerequisites.mjs"), atomically: true, encoding: .utf8
        )
        let checker = EnvironmentChecker(monorepoPath: mono.path, loginPath: "/nonexistent/login",
                                         streamServicesPath: "/nonexistent/stream")
        checker.buildChecks()

        XCTAssertFalse(checker.checks.contains { $0.id == "python-jwt" })
        XCTAssertTrue(checker.checks.contains { $0.id == "node" })
    }

    /// Findings "hotel seed needs a shared env marked optional": the row is the source of
    /// the hotels, and its fix imports the shared .env. No fix of it resets or downloads.
    func testTheHotelRowIsTheSourceAndItsFixImportsTheSharedEnv() throws {
        let checker = EnvironmentChecker(monorepoPath: "/nonexistent/mono", loginPath: "/nonexistent/login",
                                         streamServicesPath: "/nonexistent/stream")
        checker.buildChecks()
        let hotels = try XCTUnwrap(checker.checks.first { $0.id == "hotel-data" })
        XCTAssertEqual(hotels.name, "Hotel catalog source")
        XCTAssertEqual(hotels.fixLabel, "Import…")
        XCTAssertFalse(hotels.isRequired)
        XCTAssertFalse(hotels.checkDescription.contains("pnpm db:hotels"))
        XCTAssertEqual(EnvironmentChecker.linkedChecks(of: "hotel-data"), ["booking-env"])
        XCTAssertEqual(EnvironmentChecker.linkedChecks(of: "booking-env"), ["hotel-data"])
        // Negative control: another row changes no other row.
        XCTAssertEqual(EnvironmentChecker.linkedChecks(of: "stream-modules"), [])
        XCTAssertEqual(EnvironmentChecker.fixFailedText(for: "hotel-data"), "Fix failed — try manually")
    }

    // MARK: - What the runner tells the scripts

    /// The scripts read these names. Without `TRAVEL_DB_PROFILE` the prerequisites
    /// step never checked the hotel source, so the reset ran before the hotel
    /// download could fail.
    func testAStepGetsTheProfileTheHotelDumpAndTheFlavor() {
        let environment = DbSetupRunner.environment(
            parent: ["PATH": "/test/bin", "TRAVEL_DB_PROFILE": "old", "TRAVEL_HOTEL_DUMP": "/old"],
            seedScenarioID: "standard", profile: "reset", flavor: .hackathon, home: "/Users/a"
        )
        XCTAssertEqual(environment, [
            "PATH": "/test/bin",
            "TRAVEL_SEED_SCENARIO": "standard",
            "TRAVEL_DB_PROFILE": "reset",
            "TRAVEL_HOTEL_DUMP":
                "/Users/a/Library/Application Support/Travel Runner Hackathon/hotels/travel_organizations.sql",
            "TRAVEL_RUNNER_FLAVOR": "hackathon",
            // A reset can clone the backend baseline: git must not wait for a password.
            "GIT_TERMINAL_PROMPT": "0",
        ])
        // The two apps keep their dumps apart.
        XCTAssertEqual(
            DbSetupRunner.hotelDumpPath(flavor: .standard, home: "/Users/a"),
            "/Users/a/Library/Application Support/Travel Runner/hotels/travel_organizations.sql"
        )
        // Negative control: a runner without a pipeline names no profile.
        let bare = DbSetupRunner.environment(parent: [:], seedScenarioID: "standard")
        XCTAssertNil(bare["TRAVEL_DB_PROFILE"])
    }

    /// The step command and its health check both get the profile of the pipeline.
    func testTheStepAndItsHealthCheckGetTheProfile() async throws {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("DbSetupProfile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let step = DbSetupStep(
            id: "check-prerequisites", name: "Prerequisites",
            command: "test \"$TRAVEL_DB_PROFILE\" = full && test -n \"$TRAVEL_HOTEL_DUMP\" && test -n \"$TRAVEL_RUNNER_FLAVOR\"",
            healthCheckCommand: "check", timeoutSeconds: 10, isOptional: false, stepNumber: 1
        )
        let shell = FakeCommandRunner()
        let tools = ToolEnvironment(home: cwd.path)
        let passed = await DbSetupRunner(
            portalCwd: cwd.path, logStore: LogStore(), seedScenarioID: "standard", profile: "full",
            tools: tools, shell: shell
        ).executeStepPublic(step)

        XCTAssertTrue(passed, "\(step.logEntries.map(\.text))")
        XCTAssertEqual(shell.calls.map(\.environment["TRAVEL_DB_PROFILE"]), ["full"])
        XCTAssertEqual(shell.calls.first?.environment["TRAVEL_HOTEL_DUMP"], DbSetupRunner.hotelDumpPath())
        XCTAssertEqual(shell.calls.first?.environment["TRAVEL_RUNNER_FLAVOR"], Flavor.current.rawValue)

        // Negative control: the same step fails when the runner names another profile.
        let other = await DbSetupRunner(
            portalCwd: cwd.path, logStore: LogStore(), seedScenarioID: "standard", profile: "fast",
            tools: tools, shell: FakeCommandRunner()
        ).executeStepPublic(step)
        XCTAssertFalse(other)
    }

    /// Stop All cancels the task of the start, and an automatic reset runs inside
    /// it. The real shell ends a command at once in a cancelled task, so the health
    /// check failed as "Cancelled" and the pipeline broke after the reset step:
    /// a database with no hotels. Only `cancel()` of the runner stops a pipeline.
    func testACancelledTaskDoesNotBreakThePipelineAtAHealthCheck() async throws {
        let cwd = FileManager.default.temporaryDirectory.appendingPathComponent("DbSetupCancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        // Like `Shell.execute`: a command in a cancelled task does not run.
        let shell = FakeCommandRunner { _ in
            Task.isCancelled ? CommandResult(exitCode: -1, stdout: "", stderr: "Cancelled") : FakeCommandRunner.ok()
        }
        func makeStep(_ id: String, _ command: String) -> DbSetupStep {
            DbSetupStep(
                id: id, name: id, command: command, healthCheckCommand: "check-\(id)",
                timeoutSeconds: 30, isOptional: false, stepNumber: 1
            )
        }
        let marker = cwd.appendingPathComponent("started").path
        let steps = [
            makeStep("reset-database", "touch \(ShellQuote.quote(marker)); sleep 1"),
            makeStep("load-hotels", "true"),
        ]
        let scenario = DbSeedScenario(id: "test", name: "Test", description: "", fileSummary: "", variables: [])
        let pipeline = DbSetupPipeline(profile: "reset", seedScenario: scenario)
        pipeline.steps = steps
        let runner = DbSetupRunner(
            portalCwd: cwd.path, logStore: LogStore(), seedScenarioID: "test", profile: "reset",
            tools: ToolEnvironment(home: cwd.path), shell: shell
        )

        let run = Task { await runner.run(pipeline: pipeline) }
        // The first step is in flight when the task is cancelled, as with Stop All.
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        run.cancel()
        await run.value

        XCTAssertEqual(steps.map(\.status), [.passed, .passed], "\(steps.map(\.errorMessage))")
        XCTAssertEqual(shell.commands, ["check-reset-database", "check-load-hotels"])
        XCTAssertTrue(pipeline.allRequiredPassed)
        let wasCancelled = await runner.wasCancelled
        XCTAssertFalse(wasCancelled)

        // Control: the fake does answer "Cancelled" inside a cancelled task.
        let direct = Task {
            try? await Task.sleep(for: .seconds(30))
            return await shell.run("direct", cwd: nil, environment: [:], timeout: .seconds(1), onLine: nil)
        }
        direct.cancel()
        let answer = await direct.value
        XCTAssertEqual(answer.exitCode, -1)
    }
}
