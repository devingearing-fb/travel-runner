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

    /// `pnpm db:hotels` needs a running local Supabase and the shared env. The row says so
    /// before the fix and after it fails.
    func testTheHotelFixSaysWhatItNeeds() throws {
        let checker = EnvironmentChecker(monorepoPath: "/nonexistent/mono", loginPath: "/nonexistent/login",
                                         streamServicesPath: "/nonexistent/stream")
        checker.buildChecks()
        let hotels = try XCTUnwrap(checker.checks.first { $0.id == "hotel-data" })
        XCTAssertTrue(
            hotels.checkDescription.hasSuffix(
                "The fix downloads the file only; it does not reset the database. The fix needs the local Supabase running and the shared apps/booking-portal/.env."
            ),
            hotels.checkDescription
        )
        XCTAssertEqual(
            EnvironmentChecker.fixFailedText(for: "hotel-data"),
            "Download failed — start the stack first (the download needs the local Supabase and the shared apps/booking-portal/.env), then retry"
        )
        // Negative control: another row keeps the general text.
        XCTAssertEqual(EnvironmentChecker.fixFailedText(for: "stream-modules"), "Fix failed — try manually")
    }

    func testTheHotelFixDoesNotResetTheDatabase() {
        let command = EnvironmentChecker.hotelDataFixCommand
        XCTAssertEqual(command, "pnpm db:hotels")
        XCTAssertFalse(command.contains("reset"))
        XCTAssertFalse(command.contains("db:setup"))
    }
}
