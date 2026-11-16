import Foundation
import XCTest
@testable import TravelRunner

final class DebugTrackerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DebugTrackerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeConfig(_ json: String) throws {
        try json.write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    }

    private func issueJSON(_ id: String, status: String = "open") throws -> [String: Any] {
        let url = root.appendingPathComponent("\(status)/\(id)/issue.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testTheLikelyCauseIsInTheIssueAndItsSummary() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let tracker = DebugTracker(baseDir: root.path)

        let captured = await tracker.captureIssue(
            trigger: "service_crash",
            serviceId: "travel-portal",
            errorMessage: "Travel Portal exited with code 1",
            likelyCause: "Error: listen EADDRINUSE: address already in use :::3002"
        )
        let id = try XCTUnwrap(captured)

        let issue = try issueJSON(id)
        XCTAssertEqual(issue["likely_cause"] as? String, "Error: listen EADDRINUSE: address already in use :::3002")
        XCTAssertEqual(
            issue["summary"] as? String,
            "service_crash [travel-portal]: Travel Portal exited with code 1 — Error: listen EADDRINUSE: address already in use :::3002"
        )
        XCTAssertEqual(issue["error_message"] as? String, "Travel Portal exited with code 1")
    }

    func testAnIssueWithoutACauseKeepsTheOldSummary() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let tracker = DebugTracker(baseDir: root.path)

        let captured = await tracker.captureIssue(trigger: "manual", serviceId: nil, errorMessage: "Something is wrong")
        let issue = try issueJSON(try XCTUnwrap(captured))

        XCTAssertEqual(issue["summary"] as? String, "manual [unknown]: Something is wrong")
        XCTAssertNil(issue["likely_cause"])
    }

    /// The cause is not part of the signature: the same failure with another cause
    /// line is one issue with a recurrence, not a second issue.
    func testARepeatInsideTheWindowIsARecurrence() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let tracker = DebugTracker(baseDir: root.path)

        let first = await tracker.captureIssue(
            trigger: "service_crash", serviceId: "supabase", errorMessage: "Supabase exited with code 1", likelyCause: "one"
        )
        let second = await tracker.captureIssue(
            trigger: "service_crash", serviceId: "supabase", errorMessage: "Supabase exited with code 1", likelyCause: "two"
        )

        XCTAssertNil(second)
        let issue = try issueJSON(try XCTUnwrap(first))
        XCTAssertEqual(issue["recurrence_count"] as? Int, 1)
        let open = await tracker.openIssueCount()
        XCTAssertEqual(open, 1)
    }

    func testAnIssueFromBeforeTheCauseFieldStillLoads() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let folder = root.appendingPathComponent("open/20260821T141601_service-crash-travel-portal")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = """
        {
          "category": "runtime", "created_at": "2026-08-21T18:16:01.447Z",
          "error_message": "Travel Portal exited with code 1", "error_signature": "abc",
          "id": "20260821T141601_service-crash-travel-portal", "recurrence_count": 0,
          "recurrence_timestamps": [], "service_id": "travel-portal", "severity": "error",
          "status": "open", "summary": "service_crash [travel-portal]: Travel Portal exited with code 1",
          "trigger": "service_crash", "updated_at": "2026-08-21T18:16:01.447Z"
        }
        """
        try old.write(to: folder.appendingPathComponent("issue.json"), atomically: true, encoding: .utf8)
        let tracker = DebugTracker(baseDir: root.path)

        let issues = await tracker.listIssues(status: "open")
        XCTAssertEqual(issues.count, 1)
        XCTAssertNil(issues.first?.likelyCause)

        let closed = await tracker.closeIssue(id: "20260821T141601_service-crash-travel-portal", resolution: "fixed")
        XCTAssertTrue(closed)
        let after = try issueJSON("20260821T141601_service-crash-travel-portal", status: "closed")
        XCTAssertEqual(after["resolution"] as? String, "fixed")
    }

    /// Findings "seed tickets have empty logs" and "no step id": the ticket of a failed
    /// DB step names the step and holds what the step printed.
    @MainActor
    func testADbSetupFailureHasTheStepNameAndItsLog() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)"))
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        supervisor.debugTracker = DebugTracker(baseDir: root.path)
        let step = DbSetupStep(
            id: "load-hotels", name: "Load hotels", command: "true", healthCheckCommand: nil,
            timeoutSeconds: 60, isOptional: false, stepNumber: 4
        )
        step.status = .failed
        step.errorMessage = "Exit code 1"
        await supervisor.logStore.append(
            serviceID: step.logKey, entry: LogEntry(stream: .stdout, text: "hotel fetch failed: HTTP 401")
        )
        // The log of another step stays out of the step's file.
        await supervisor.logStore.append(
            serviceID: "db-setup-seed", entry: LogEntry(stream: .stdout, text: "seed done")
        )

        await supervisor.captureDbSetupFailure(step)

        let issues = await supervisor.listDebugIssues()
        let issue = try XCTUnwrap(issues.first)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issue.trigger, "db_setup_failure")
        XCTAssertEqual(issue.serviceId, "db-setup-load-hotels")
        XCTAssertEqual(issue.errorMessage, "Load hotels (load-hotels): Exit code 1")
        let log = try String(
            contentsOf: root.appendingPathComponent("open/\(issue.id)/logs-db-setup-load-hotels.txt"), encoding: .utf8
        )
        XCTAssertEqual(log, "hotel fetch failed: HTTP 401")
    }

    /// The runner sends lines to the log store from detached tasks. When the last
    /// lines are not there yet, the issue takes the step's own list.
    @MainActor
    func testADbSetupFailureTakesTheStepsOwnLinesWhenTheStoreIsBehind() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)"))
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        supervisor.debugTracker = DebugTracker(baseDir: root.path)
        let step = DbSetupStep(
            id: "seed", name: "Seed", command: "true", healthCheckCommand: nil,
            timeoutSeconds: 60, isOptional: false, stepNumber: 5
        )
        step.status = .failed
        step.errorMessage = "Exit code 1"
        step.logEntries = [
            LogEntry(stream: .stdout, text: "seeding"),
            LogEntry(stream: .stdout, text: "seed failed: no such table"),
        ]
        await supervisor.logStore.append(serviceID: step.logKey, entry: LogEntry(stream: .stdout, text: "seeding"))

        await supervisor.captureDbSetupFailure(step)

        let found = await supervisor.listDebugIssues()
        let issue = try XCTUnwrap(found.first)
        let log = try String(
            contentsOf: root.appendingPathComponent("open/\(issue.id)/logs-\(step.logKey).txt"), encoding: .utf8
        )
        XCTAssertEqual(log, "seeding\nseed failed: no such table")
    }

    /// A cancel ends the step's process, so the step fails. That is not a fault:
    /// a cancelled run files no issue. A run that was not cancelled does.
    @MainActor
    func testACancelledDbRunFilesNoIssue() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)"))
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        supervisor.debugTracker = DebugTracker(baseDir: root.path)
        let step = DbSetupStep(
            id: "seed", name: "Seed", command: "true", healthCheckCommand: nil,
            timeoutSeconds: 60, isOptional: false, stepNumber: 5
        )
        step.status = .failed
        step.errorMessage = "Exit code 15"
        let runner = DbSetupRunner(portalCwd: root.path, logStore: supervisor.logStore, seedScenarioID: "default")

        await runner.cancel()
        await supervisor.captureDbSetupFailure(step, runner: runner)
        let afterCancel = await supervisor.listDebugIssues()
        XCTAssertTrue(afterCancel.isEmpty)

        let notCancelled = DbSetupRunner(portalCwd: root.path, logStore: supervisor.logStore, seedScenarioID: "default")
        await supervisor.captureDbSetupFailure(step, runner: notCancelled)
        let afterFailure = await supervisor.listDebugIssues()
        XCTAssertEqual(afterFailure.count, 1)
    }

    /// The runner writes a step's output under the step's log key, the key the
    /// issue reads. Each run starts with an empty log, so an issue shows one run.
    @MainActor
    func testTheRunnerLogsUnderTheStepsKeyAndEachRunStartsEmpty() async throws {
        let store = LogStore()
        let marker = root.appendingPathComponent("ran-once").path
        let step = DbSetupStep(
            id: "seed", name: "Seed",
            command: "if [ -f '\(marker)' ]; then echo second-run; else touch '\(marker)'; echo first-run; fi; exit 1",
            healthCheckCommand: nil, timeoutSeconds: 60, isOptional: false, stepNumber: 5
        )
        let runner = DbSetupRunner(portalCwd: root.path, logStore: store, seedScenarioID: "default")

        func lines(until text: String) async -> [String] {
            for _ in 0..<100 {
                let lines = await store.entries(for: step.logKey).map(\.text)
                if lines.contains(text) { return lines }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return await store.entries(for: step.logKey).map(\.text)
        }

        let first = await runner.executeStepPublic(step)
        XCTAssertFalse(first)
        let firstLines = await lines(until: "first-run")
        XCTAssertTrue(firstLines.contains("first-run"), "\(firstLines)")

        let second = await runner.executeStepPublic(step)
        XCTAssertFalse(second)
        let secondLines = await lines(until: "second-run")
        XCTAssertTrue(secondLines.contains("second-run"), "\(secondLines)")
        XCTAssertFalse(secondLines.contains("first-run"), "\(secondLines)")
    }

    func testNothingIsCapturedWhenTrackingIsOff() async {
        let tracker = DebugTracker(baseDir: root.path)
        let captured = await tracker.captureIssue(trigger: "service_crash", serviceId: "x", errorMessage: "x exited")
        XCTAssertNil(captured)
    }

    func testSecretLines() {
        XCTAssertTrue(DebugTracker.isSecretLine("STRIPE_WEBHOOK_SECRET=whsec_123"))
        XCTAssertTrue(DebugTracker.isSecretLine("using api key abc"))
        XCTAssertFalse(DebugTracker.isSecretLine("Error: listen EADDRINUSE: address already in use :::3002"))
    }
}
