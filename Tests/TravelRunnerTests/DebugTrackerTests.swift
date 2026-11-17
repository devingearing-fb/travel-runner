import Foundation
import XCTest
import CryptoKit
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

    /// A supervisor whose diagnostics read no tool of this Mac.
    @MainActor
    private func makeSupervisor(_ defaults: UserDefaults) -> EnvironmentSupervisor {
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        supervisor.diagnosticsTools = { _ in [] }
        return supervisor
    }

    /// The lines of an issue log without their "HH:mm:ss.SSS " prefix. Each line must have one.
    private func withoutTimes(_ log: String) throws -> String {
        let prefix = try NSRegularExpression(pattern: #"^\d{2}:\d{2}:\d{2}\.\d{3} "#)
        return log.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let line = String(line)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = prefix.firstMatch(in: line, range: range) else {
                XCTFail("no time: \(line)")
                return line
            }
            return String(line[Range(match.range, in: line)!.upperBound...])
        }.joined(separator: "\n")
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

    /// Finding "dedupe swallows new causes": the cause line is part of the
    /// signature. The same failure with the same cause is a recurrence; with
    /// another cause it is a new issue.
    func testTheSameCauseIsARecurrenceAndANewCauseIsANewIssue() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let clock = TestClock()
        let tracker = DebugTracker(baseDir: root.path, now: { clock.now })

        let first = await tracker.captureIssue(
            trigger: "service_crash", serviceId: "supabase", errorMessage: "Supabase exited with code 1",
            likelyCause: "port 54322 is held by pid 4411"
        )
        clock.advance(120)
        // Only the pid differs: the same cause.
        let repeated = await tracker.captureIssue(
            trigger: "service_crash", serviceId: "supabase", errorMessage: "Supabase exited with code 1",
            likelyCause: "port 54322 is held by pid 9182"
        )
        clock.advance(120)
        let otherCause = await tracker.captureIssue(
            trigger: "service_crash", serviceId: "supabase", errorMessage: "Supabase exited with code 1",
            likelyCause: "Cannot connect to the Docker daemon"
        )

        XCTAssertNil(repeated)
        XCTAssertNotNil(otherCause)
        let issue = try issueJSON(try XCTUnwrap(first))
        XCTAssertEqual(issue["recurrence_count"] as? Int, 1)
        let open = await tracker.openIssueCount()
        XCTAssertEqual(open, 2)
    }

    /// A cause is a raw log line. Times, pids, durations and temp names in it
    /// vary from crash to crash, and each pair is still one cause.
    func testACauseThatDiffersOnlyInATimeANumberOrATempNameIsTheSameCause() {
        let pairs: [(String, String)] = [
            ("2026-11-17 10:52:49.123 UTC [61] FATAL: could not open file", "2026-11-17 11:03:02.004 UTC [87] FATAL: could not open file"),
            ("[10:52:49.123] Error: listen EADDRINUSE", "[11:01:07.900] Error: listen EADDRINUSE"),
            ("postgres[1234]: FATAL: the database system is shutting down", "postgres[98765]: FATAL: the database system is shutting down"),
            ("worker (4411) exited after 5023ms", "worker (9182) exited after 611ms"),
            (
                "Error: ENOENT: no such file or directory, rename '.next/static/development/_buildManifest.js.tmp.o8dzt0rqxf'",
                "Error: ENOENT: no such file or directory, rename '.next/static/development/_buildManifest.js.tmp.k2b9qwz1mf'"
            ),
        ]
        for (first, second) in pairs {
            XCTAssertEqual(
                DebugTracker.signature(trigger: "service_crash", serviceId: "x", message: "x exited", likelyCause: first),
                DebugTracker.signature(trigger: "service_crash", serviceId: "x", message: "x exited", likelyCause: second),
                first
            )
        }
        // Negative control: a different error is a different cause.
        XCTAssertNotEqual(
            DebugTracker.signature(trigger: "service_crash", serviceId: "x", message: "x exited", likelyCause: "Error: listen EADDRINUSE"),
            DebugTracker.signature(trigger: "service_crash", serviceId: "x", message: "x exited", likelyCause: "Error: listen EACCES")
        )
        XCTAssertEqual(DebugTracker.normalizeCause("next-auth and @supabase/realtime-js"), "next-auth and @supabase/realtime-js")
    }

    /// A crash loop whose cause line has a new time each crash is one issue.
    func testACrashLoopWithATimeInTheCauseIsOneIssue() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let clock = TestClock()
        let tracker = DebugTracker(baseDir: root.path, now: { clock.now })
        var filed: [String?] = []
        for second in 0..<3 {
            filed.append(await tracker.captureIssue(
                trigger: "service_crash", serviceId: "stripe", errorMessage: "Stripe exited with code 1",
                likelyCause: "2026-11-17 10:5\(second):49 [\(4000 + second)] Error: webhook secret expired"
            ))
            clock.advance(120)
        }

        XCTAssertNotNil(filed[0])
        XCTAssertEqual(filed.dropFirst().compactMap { $0 }, [])
        let open = await tracker.openIssueCount()
        XCTAssertEqual(open, 1)
    }

    /// An open issue from before the cause was in the signature still gets its
    /// recurrences when the failure has no cause line.
    func testAFailureWithoutACauseKeepsTheOldSignature() {
        let old = SHA256.hash(data: Data("service_crash:supabase:Supabase exited with code 1".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let withoutCause = DebugTracker.signature(
            trigger: "service_crash", serviceId: "supabase", message: "Supabase exited with code 1", likelyCause: nil
        )
        let emptyCause = DebugTracker.signature(
            trigger: "service_crash", serviceId: "supabase", message: "Supabase exited with code 1", likelyCause: ""
        )
        let withCause = DebugTracker.signature(
            trigger: "service_crash", serviceId: "supabase", message: "Supabase exited with code 1", likelyCause: "x"
        )
        XCTAssertEqual(withoutCause, old)
        XCTAssertEqual(emptyCause, old)
        XCTAssertNotEqual(withCause, old)
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
        let supervisor = makeSupervisor(defaults)
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
        XCTAssertEqual(try withoutTimes(log), "hotel fetch failed: HTTP 401")
    }

    /// The runner sends lines to the log store from detached tasks. When the last
    /// lines are not there yet, the issue takes the step's own list.
    @MainActor
    func testADbSetupFailureTakesTheStepsOwnLinesWhenTheStoreIsBehind() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)"))
        let supervisor = makeSupervisor(defaults)
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
        XCTAssertEqual(try withoutTimes(log), "seeding\nseed failed: no such table")
    }

    /// A cancel ends the step's process, so the step fails. That is not a fault:
    /// a cancelled run files no issue. A run that was not cancelled does.
    @MainActor
    func testACancelledDbRunFilesNoIssue() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)"))
        let supervisor = makeSupervisor(defaults)
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

    func testNothingIsCapturedWhenTrackingIsOff() async throws {
        try writeConfig(#"{"enabled": false}"#)
        let tracker = DebugTracker(baseDir: root.path)
        let captured = await tracker.captureIssue(trigger: "service_crash", serviceId: "x", errorMessage: "x exited")
        XCTAssertNil(captured)
        await tracker.recordEvent(kind: "outside_kill", serviceId: "x", message: "x was stopped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("open").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.jsonl").path))
    }

    // MARK: - Capture by default

    /// Findings "tickets only where a hand-made config exists": a Mac without a
    /// config captures.
    func testAMissingConfigMeansCaptureIsOn() async throws {
        let tracker = DebugTracker(baseDir: root.path)

        let enabled = await tracker.isEnabled()
        XCTAssertTrue(enabled)
        let captured = await tracker.captureIssue(trigger: "service_crash", serviceId: "x", errorMessage: "x exited")
        let issue = try issueJSON(try XCTUnwrap(captured))
        XCTAssertEqual(issue["error_message"] as? String, "x exited")
    }

    func testAConfigWithoutTheSwitchIsOnAndABrokenConfigIsOff() async throws {
        try writeConfig(#"{"dedup_window_seconds": 300}"#)
        let withoutSwitch = await DebugTracker(baseDir: root.path).isEnabled()
        XCTAssertTrue(withoutSwitch)

        // It can be an opt-out with a typing error. It is not read as "on".
        try writeConfig(#"{"enabled": false,}"#)
        let broken = await DebugTracker(baseDir: root.path).isEnabled()
        XCTAssertFalse(broken)
    }

    /// The Desktop folder is used only where its config exists: the author's Mac.
    /// Everyone else gets Application Support, which needs no permission prompt.
    func testTheFolderIsTheDesktopOnlyWhereItsConfigExists() {
        var asked: [String] = []
        let fresh = DebugTracker.resolveLocation(flavor: .standard, home: "/Users/ana") {
            asked.append($0)
            return false
        }
        XCTAssertEqual(fresh, .init(path: "/Users/ana/Library/Application Support/Travel Runner/issues", isDesktop: false))
        XCTAssertEqual(asked, ["/Users/ana/Desktop/debug-tracking/config.json"], "one look, at one file")

        let author = DebugTracker.resolveLocation(flavor: .standard, home: "/Users/ana") {
            $0 == "/Users/ana/Desktop/debug-tracking/config.json"
        }
        XCTAssertEqual(author, .init(path: "/Users/ana/Desktop/debug-tracking", isDesktop: true))

        let fork = DebugTracker.resolveLocation(flavor: .hackathon, home: "/Users/ana") { _ in false }
        XCTAssertEqual(fork.path, "/Users/ana/Library/Application Support/Travel Runner Hackathon/issues")
        let forkAuthor = DebugTracker.resolveLocation(flavor: .hackathon, home: "/Users/ana") {
            $0 == "/Users/ana/Desktop/debug-tracking-hackathon/config.json"
        }
        XCTAssertEqual(forkAuthor.path, "/Users/ana/Desktop/debug-tracking-hackathon")
    }

    func testTheSwitchIsSavedAndKeepsTheOtherKeys() async throws {
        let tracker = DebugTracker(baseDir: root.appendingPathComponent("not-there-yet").path)
        let saved = await tracker.setEnabled(false)
        XCTAssertTrue(saved)
        let off = await tracker.isEnabled()
        XCTAssertFalse(off)

        try writeConfig(#"{"enabled": true, "dedup_window_seconds": 300, "auto_capture": {"probe_timeout": false}}"#)
        let other = DebugTracker(baseDir: root.path)
        _ = await other.setEnabled(false)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("config.json"))
        ) as? [String: Any])
        XCTAssertEqual(config["enabled"] as? Bool, false)
        XCTAssertEqual(config["dedup_window_seconds"] as? Int, 300)
        XCTAssertEqual((config["auto_capture"] as? [String: Any])?["probe_timeout"] as? Bool, false)

        _ = await other.setEnabled(true)
        let probeTimeout = await other.isAutoCaptureEnabled(trigger: "probe_timeout")
        let crash = await other.isAutoCaptureEnabled(trigger: "service_crash")
        XCTAssertFalse(probeTimeout)
        XCTAssertTrue(crash)
    }

    @MainActor
    func testTheSettingsSwitchTurnsCaptureOffAndOn() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)"))
        let supervisor = makeSupervisor(defaults)
        supervisor.debugTracker = DebugTracker(baseDir: root.path)

        await supervisor.setIssueCaptureEnabled(false)
        XCTAssertFalse(supervisor.debugTrackingEnabled)
        XCTAssertNil(supervisor.debugTracker)
        await supervisor.captureDebugIssue(trigger: "manual", serviceID: nil, summary: "while off")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("open").path))

        await supervisor.setIssueCaptureEnabled(true)
        XCTAssertTrue(supervisor.debugTrackingEnabled)
        let folder = await supervisor.issueCaptureFolder()
        XCTAssertEqual(folder, root.path, "the same folder, not the one of the installed app")
        await supervisor.captureDebugIssue(trigger: "manual", serviceID: nil, summary: "while on")
        XCTAssertEqual(supervisor.debugOpenIssueCount, 1)
    }

    /// A first run has no service config. Capture starts all the same, and a
    /// config reload makes no second tracker.
    @MainActor
    func testTheSupervisorStartsOneTrackerAndPrunesOnce() async throws {
        let clock = TestClock()
        try writeClosedIssue("old", resolvedAt: clock.now.addingTimeInterval(-31 * 86_400))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)"))
        let supervisor = makeSupervisor(defaults)
        let path = root.path
        var made = 0
        supervisor.makeIssueTracker = {
            made += 1
            return DebugTracker(baseDir: path, now: { clock.now })
        }

        await supervisor.initDebugTracking()
        XCTAssertTrue(supervisor.debugTrackingEnabled, "no config means on")
        XCTAssertNotNil(supervisor.debugTracker)
        XCTAssertEqual(try closedIDs(), [], "the launch prune ran")

        // A reload: the same tracker, and no second prune.
        let first = supervisor.debugTracker
        try writeClosedIssue("old", resolvedAt: clock.now.addingTimeInterval(-31 * 86_400))
        await supervisor.initDebugTracking()
        XCTAssertEqual(made, 1)
        XCTAssertTrue(supervisor.debugTracker === first)
        XCTAssertEqual(try closedIDs(), ["old"])
    }

    /// The config and the issues can change on disk. The poll reads them again.
    @MainActor
    func testThePollReadsTheSwitchAndTheCountFromDisk() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)"))
        let supervisor = makeSupervisor(defaults)
        let path = root.path
        supervisor.makeIssueTracker = { DebugTracker(baseDir: path) }
        supervisor.issueCapturePollInterval = .milliseconds(50)
        func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }

        // "Turn On" before the launch call: the poll must start all the same.
        await supervisor.setIssueCaptureEnabled(true)
        await supervisor.initDebugTracking()
        await supervisor.captureDebugIssue(trigger: "manual", serviceID: nil, summary: "one")
        let counted = await waitUntil { supervisor.debugOpenIssueCount == 1 }
        XCTAssertTrue(counted)

        try writeConfig(#"{"enabled": false}"#)
        let off = await waitUntil { !supervisor.debugTrackingEnabled }
        XCTAssertTrue(off)
        XCTAssertNil(supervisor.debugTracker)
        XCTAssertEqual(supervisor.debugOpenIssueCount, 0)

        try writeConfig(#"{"enabled": true}"#)
        let on = await waitUntil { supervisor.debugTrackingEnabled }
        XCTAssertTrue(on)
    }

    @MainActor
    func testASwitchThatCannotBeSavedNamesTheFile() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)"))
        let supervisor = makeSupervisor(defaults)
        // A file where the folder should be: nothing can be written under it.
        try "x".write(to: root.appendingPathComponent("blocked"), atomically: true, encoding: .utf8)
        let folder = root.appendingPathComponent("blocked/issues").path
        supervisor.makeIssueTracker = { DebugTracker(baseDir: folder) }
        var feedback: [String] = []
        supervisor.onActionFeedback = { message, _ in feedback.append(message) }

        await supervisor.setIssueCaptureEnabled(false)

        XCTAssertEqual(feedback, [
            "Issue capture: could not write \(folder)/config.json. Check that the folder is writable, then try again."
        ])
        XCTAssertFalse(supervisor.debugTrackingEnabled)
    }

    // MARK: - Guards

    /// Finding "unbounded recurrence list": the count keeps every repeat, the list
    /// keeps the newest 20.
    func testAnIssueKeepsItsNewestTwentyRecurrenceTimes() async throws {
        let clock = TestClock()
        let tracker = DebugTracker(baseDir: root.path, now: { clock.now })
        let first = await tracker.captureIssue(trigger: "service_crash", serviceId: "stripe", errorMessage: "Stripe exited")
        for _ in 0..<25 {
            clock.advance(61)
            _ = await tracker.captureIssue(trigger: "service_crash", serviceId: "stripe", errorMessage: "Stripe exited")
        }

        let issue = try issueJSON(try XCTUnwrap(first))
        XCTAssertEqual(issue["recurrence_count"] as? Int, 25)
        let times = try XCTUnwrap(issue["recurrence_timestamps"] as? [String])
        XCTAssertEqual(times.count, 20)
        XCTAssertEqual(times.last, issue["updated_at"] as? String, "the newest stay")
    }

    func testARepeatInsideAMinuteWritesNothingAndIsCountedLater() async throws {
        let clock = TestClock()
        let tracker = DebugTracker(baseDir: root.path, now: { clock.now })
        func capture(_ tracker: DebugTracker, _ service: String = "web") async -> String? {
            await tracker.captureIssue(trigger: "service_crash", serviceId: service, errorMessage: "\(service) exited")
        }

        let first = await capture(tracker)
        let id = try XCTUnwrap(first)
        clock.advance(30)
        _ = await capture(tracker)
        XCTAssertEqual(try issueJSON(id)["recurrence_count"] as? Int, 0, "no write inside the minute")

        // Another signature has its own limit.
        let other = await capture(tracker, "api")
        XCTAssertNotNil(other)

        // After a new launch of the app, the time on disk holds the limit.
        clock.advance(20)
        _ = await capture(DebugTracker(baseDir: root.path, now: { clock.now }))
        XCTAssertEqual(try issueJSON(id)["recurrence_count"] as? Int, 0)

        clock.advance(15)
        _ = await capture(tracker)
        XCTAssertEqual(
            try issueJSON(id)["recurrence_count"] as? Int, 2, "65 s after the first: this one and the dropped one"
        )

        // A closed issue does not open the door: the same failure a moment later
        // files no second issue.
        let closed = await tracker.closeIssue(id: id, resolution: "fixed")
        XCTAssertTrue(closed)
        clock.advance(10)
        let again = await capture(tracker)
        XCTAssertNil(again)
        clock.advance(60)
        let later = await capture(tracker)
        XCTAssertEqual(try issueJSON(try XCTUnwrap(later))["recurrence_count"] as? Int, 1, "the dropped one counts")
    }

    /// A close writes the issue: the repeats that were dropped go into its count.
    func testACloseCountsTheDroppedRepeats() async throws {
        let clock = TestClock()
        let tracker = DebugTracker(baseDir: root.path, now: { clock.now })
        let first = await tracker.captureIssue(trigger: "service_crash", serviceId: "web", errorMessage: "web exited")
        let id = try XCTUnwrap(first)
        for _ in 0..<3 {
            clock.advance(5)
            _ = await tracker.captureIssue(trigger: "service_crash", serviceId: "web", errorMessage: "web exited")
        }

        let closed = await tracker.closeIssue(id: id, resolution: "fixed")
        XCTAssertTrue(closed)
        XCTAssertEqual(try issueJSON(id, status: "closed")["recurrence_count"] as? Int, 3)
    }

    /// A report that a person files is never dropped. The same text again is a
    /// recurrence of the open issue.
    func testAManualCaptureHasNoRateLimit() async throws {
        let clock = TestClock()
        let tracker = DebugTracker(baseDir: root.path, now: { clock.now })
        let first = await tracker.captureIssue(trigger: "manual", serviceId: nil, errorMessage: "the page is blank")
        let id = try XCTUnwrap(first)
        clock.advance(5)
        _ = await tracker.captureIssue(trigger: "manual", serviceId: nil, errorMessage: "the page is blank")
        clock.advance(5)
        _ = await tracker.captureIssue(trigger: "manual", serviceId: nil, errorMessage: "the page is blank")

        XCTAssertEqual(try issueJSON(id)["recurrence_count"] as? Int, 2)
    }

    /// Issue logs are redacted, but they are logs: only the user reads them.
    func testIssueFilesAreForTheUserOnly() async throws {
        let base = root.appendingPathComponent("support/issues")
        let tracker = DebugTracker(baseDir: base.path)
        let captured = await tracker.captureIssue(
            trigger: "service_crash", serviceId: "web", errorMessage: "web exited",
            logEntries: [.init(timestamp: Date(), serviceId: "web", line: "boom")],
            stateSnapshots: [
                ServiceStateSnapshot(
                    id: "web", phase: "failed", pid: nil, exitCode: 1, restartCount: 0,
                    isCircuitBroken: false, uptimeSeconds: nil
                )
            ]
        )
        let id = try XCTUnwrap(captured)
        // A recurrence writes issue.json again.
        _ = await tracker.captureIssue(trigger: "manual", serviceId: nil, errorMessage: "x")
        await tracker.recordEvent(kind: "stripe_skip", serviceId: "stripe", message: "skipped")

        func mode(_ path: String) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: base.appendingPathComponent(path).path)
            return try XCTUnwrap(attributes[.posixPermissions] as? Int)
        }
        XCTAssertEqual(try mode(""), 0o700)
        XCTAssertEqual(try mode("open"), 0o700)
        XCTAssertEqual(try mode("open/\(id)"), 0o700)
        for file in ["issue.json", "logs-web.txt", "logs-all.txt", "state-snapshot.json"] {
            XCTAssertEqual(try mode("open/\(id)/\(file)"), 0o600, file)
        }
        XCTAssertEqual(try mode("events.jsonl"), 0o600)

        let closed = await tracker.closeIssue(id: id, resolution: "fixed")
        XCTAssertTrue(closed)
        XCTAssertEqual(try mode("closed"), 0o700)
        XCTAssertEqual(try mode("closed/\(id)/issue.json"), 0o600)
    }

    private func writeClosedIssue(_ id: String, resolvedAt: Date, byHand: Bool = false) throws {
        let folder = root.appendingPathComponent("closed/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: resolvedAt)
        let json = """
        {
          "category": "runtime", "created_at": "\(stamp)", "error_message": "x", "error_signature": "\(id)",
          "id": "\(id)", "recurrence_count": 0, "recurrence_timestamps": [], "resolution": "fixed",
          \(byHand ? "" : "\"resolved_at\": \"\(stamp)\",") "severity": "error", "status": "closed", "summary": "x",
          "trigger": "service_crash", "updated_at": "\(stamp)"
        }
        """
        try json.write(to: folder.appendingPathComponent("issue.json"), atomically: true, encoding: .utf8)
        try "log".write(to: folder.appendingPathComponent("logs-all.txt"), atomically: true, encoding: .utf8)
    }

    private func closedIDs() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("closed").path).sorted()
    }

    func testClosedIssuesOlderThanThirtyDaysAreDeleted() async throws {
        let clock = TestClock()
        try writeClosedIssue("old", resolvedAt: clock.now.addingTimeInterval(-31 * 86_400))
        try writeClosedIssue("recent", resolvedAt: clock.now.addingTimeInterval(-29 * 86_400))
        // A folder that is not an issue is not ours to delete.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("closed/notes"), withIntermediateDirectories: true
        )
        let tracker = DebugTracker(baseDir: root.path, now: { clock.now })

        let removed = await tracker.pruneClosedIssues()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try closedIDs(), ["notes", "recent"])

        // A folder that someone moved here by hand has no close time. It stays.
        try writeClosedIssue("moved", resolvedAt: clock.now.addingTimeInterval(-90 * 86_400), byHand: true)
        let none = await tracker.pruneClosedIssues()
        XCTAssertEqual(none, 0)
        XCTAssertEqual(try closedIDs(), ["moved", "notes", "recent"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("closed/moved"))

        // Open issues have no age limit, and a close prunes too.
        let captured = await tracker.captureIssue(trigger: "manual", serviceId: nil, errorMessage: "open one")
        let open = try XCTUnwrap(captured)
        clock.advance(2 * 86_400)
        let closed = await tracker.closeIssue(id: open, resolution: "done")
        XCTAssertTrue(closed)
        XCTAssertEqual(try closedIDs(), [open, "notes"].sorted())
    }

    /// The Desktop folder is the author's archive of tickets. It is pruned only
    /// when its config asks for it.
    func testTheDesktopArchiveIsKeptUnlessItsConfigSaysOtherwise() async throws {
        let clock = TestClock()
        try writeClosedIssue("old", resolvedAt: clock.now.addingTimeInterval(-400 * 86_400))
        try writeClosedIssue("recent", resolvedAt: clock.now.addingTimeInterval(-10 * 86_400))
        let tracker = DebugTracker(baseDir: root.path, prunesClosedIssues: false, now: { clock.now })

        let kept = await tracker.pruneClosedIssues()
        XCTAssertEqual(kept, 0)
        XCTAssertEqual(try closedIDs(), ["old", "recent"])

        try writeConfig(#"{"enabled": true, "closed_retention_days": 7}"#)
        let removed = await tracker.pruneClosedIssues()
        XCTAssertEqual(removed, 2)

        // Zero keeps everything, in any folder.
        try writeClosedIssue("old", resolvedAt: clock.now.addingTimeInterval(-400 * 86_400))
        try writeConfig(#"{"closed_retention_days": 0}"#)
        let none = await DebugTracker(baseDir: root.path, now: { clock.now }).pruneClosedIssues()
        XCTAssertEqual(none, 0)
    }

    // MARK: - Events

    func testAnEventIsOneRedactedLine() async throws {
        let clock = TestClock()
        let tracker = DebugTracker(
            baseDir: root.path,
            buildInfo: BuildInfo(version: "9.9.9", build: "1", commit: nil, kind: .release, flavor: .standard),
            now: { clock.now }
        )
        let key = "sk_" + "test_" + "51AbCdEfGhIjKlMn"

        await tracker.recordEvent(kind: "stripe_skip", serviceId: "stripe", message: "the Stripe CLI exited (key \(key))")
        await tracker.recordEvent(kind: "breaker_trip", serviceId: "web", message: "web is crash-looping")

        let url = root.appendingPathComponent("events.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(key))
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: String])
        XCTAssertEqual(first["kind"], "stripe_skip")
        XCTAssertEqual(first["service_id"], "stripe")
        XCTAssertEqual(first["message"], "the Stripe CLI exited (key ‹redacted:stripe-key›)")
        XCTAssertEqual(first["app_version"], "9.9.9")
        XCTAssertNotNil(first["at"])
        let events = await tracker.listEvents()
        XCTAssertEqual(events.map(\.kind), ["stripe_skip", "breaker_trip"])
        // Events file no issue.
        let open = await tracker.openIssueCount()
        XCTAssertEqual(open, 0)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
    }

    func testAFullEventFileMovesAsideOnce() async throws {
        let tracker = DebugTracker(baseDir: root.path)
        let url = root.appendingPathComponent("events.jsonl")
        try Data(repeating: 0x78, count: DebugTracker.maxEventsBytes).write(to: url)

        await tracker.recordEvent(kind: "outside_kill", serviceId: "web", message: "web was stopped")

        let events = await tracker.listEvents()
        XCTAssertEqual(events.map(\.kind), ["outside_kill"])
        let older = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("events.1.jsonl").path)
        XCTAssertEqual(older[.size] as? Int, DebugTracker.maxEventsBytes)
    }

    /// Whole lines became "[REDACTED]", and the cause went with them.
    func testAnIssueKeepsTheLineAndLosesOnlyTheSecret() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let tracker = DebugTracker(baseDir: root.path)
        let key = "sk_" + "test_" + "51AbCdEfGhIjKlMn"
        let now = Date()
        let captured = await tracker.captureIssue(
            trigger: "service_crash",
            serviceId: "stripe",
            errorMessage: "Stripe CLI exited with code 1 (key \(key), HOTEL_API_KEY hotel-opaque-0001)",
            likelyCause: "Expired API Key provided: \(key)",
            logEntries: [
                .init(timestamp: now, serviceId: "stripe", line: #"  "code": "api_key_expired","#),
                .init(timestamp: now, serviceId: "stripe", line: "Expired API Key provided: \(key)"),
                .init(timestamp: now, serviceId: "stripe", line: "sent hotel-opaque-0001 to the hotel API"),
            ],
            redactor: Redactor(knownValues: ["hotel-opaque-0001"])
        )
        let id = try XCTUnwrap(captured)

        let issue = try issueJSON(id)
        XCTAssertEqual(
            issue["error_message"] as? String,
            "Stripe CLI exited with code 1 (key ‹redacted:stripe-key›, HOTEL_API_KEY ‹redacted:env-value›)"
        )
        XCTAssertEqual(issue["likely_cause"] as? String, "Expired API Key provided: ‹redacted:stripe-key›")

        let expected = """
              "code": "api_key_expired",
            Expired API Key provided: ‹redacted:stripe-key›
            sent ‹redacted:env-value› to the hotel API
            """
        let folder = root.appendingPathComponent("open/\(id)")
        XCTAssertEqual(
            try withoutTimes(String(contentsOf: folder.appendingPathComponent("logs-stripe.txt"), encoding: .utf8)), expected
        )
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains(key), file)
            XCTAssertFalse(text.contains("hotel-opaque-0001"), file)
            XCTAssertFalse(text.contains("[REDACTED]"), file)
        }
    }

    // MARK: - Tickets that explain themselves (C4)

    /// Finding "ticket logs: one service, no timestamps": the combined log has
    /// every service, in time order, and each line has its time.
    func testTheCombinedLogHasEveryServiceInTimeOrderWithTimes() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let tracker = DebugTracker(baseDir: root.path)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let captured = await tracker.captureIssue(
            trigger: "service_crash",
            serviceId: "travel-portal",
            errorMessage: "Travel Portal exited with code 1",
            logEntries: [
                .init(timestamp: start.addingTimeInterval(2), serviceId: "travel-portal", line: "portal down"),
                .init(timestamp: start, serviceId: "supabase", line: "db up"),
                .init(timestamp: start.addingTimeInterval(1), serviceId: "db-setup-seed", line: "seed done"),
            ]
        )
        let folder = root.appendingPathComponent("open/\(try XCTUnwrap(captured))")

        let all = try String(contentsOf: folder.appendingPathComponent("logs-all.txt"), encoding: .utf8)
        XCTAssertEqual(try withoutTimes(all), "[supabase] db up\n[db-setup-seed] seed done\n[travel-portal] portal down")
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss.SSS"
        time.locale = Locale(identifier: "en_US_POSIX")
        XCTAssertTrue(all.hasPrefix("\(time.string(from: start)) [supabase]"), all)
        let own = try String(contentsOf: folder.appendingPathComponent("logs-travel-portal.txt"), encoding: .utf8)
        XCTAssertEqual(own, "\(time.string(from: start.addingTimeInterval(2))) portal down")
    }

    /// The supervisor gives the tracker the logs of every service, not only
    /// those of the failed one. A capture without a service has them too.
    @MainActor
    func testAnIssueHasTheLogsOfEveryService() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)"))
        let supervisor = makeSupervisor(defaults)
        supervisor.debugTracker = DebugTracker(baseDir: root.path)
        await supervisor.logStore.append(serviceID: "supabase", entry: LogEntry(stream: .stdout, text: "db up"))
        await supervisor.logStore.append(serviceID: "travel-portal", entry: LogEntry(stream: .stderr, text: "portal down"))

        await supervisor.captureDebugIssue(trigger: "service_crash", serviceID: "travel-portal", summary: "Travel Portal exited")
        await supervisor.captureDebugIssue(trigger: "preflight_failure", serviceID: nil, summary: "Preflight failed")

        let issues = await supervisor.listDebugIssues()
        XCTAssertEqual(issues.count, 2)
        for issue in issues {
            let all = try String(contentsOf: root.appendingPathComponent("open/\(issue.id)/logs-all.txt"), encoding: .utf8)
            XCTAssertEqual(try withoutTimes(all), "[supabase] db up\n[travel-portal] portal down", issue.trigger)
        }
    }

    /// Finding "no app version or machine context": a new issue has
    /// `diagnostics.json`, with its free text redacted. A repeat of the issue
    /// does not read this Mac again.
    func testANewIssueHasRedactedDiagnosticsAndARepeatReadsNothing() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let clock = TestClock()
        let tracker = DebugTracker(baseDir: root.path, now: { clock.now })
        let reads = Counter()
        let key = "sk_" + "test_" + "51AbCdEfGhIjKlMn"
        let snapshot = DiagnosticsSnapshotTests.sample(lastError: "Stripe failed with \(key)")
        let diagnostics: @Sendable () async -> DiagnosticsSnapshot? = {
            reads.increment()
            return snapshot
        }

        let first = await tracker.captureIssue(
            trigger: "service_crash", serviceId: "stripe", errorMessage: "Stripe exited", diagnostics: diagnostics
        )
        clock.advance(120)
        let repeated = await tracker.captureIssue(
            trigger: "service_crash", serviceId: "stripe", errorMessage: "Stripe exited", diagnostics: diagnostics
        )

        XCTAssertNil(repeated)
        await tracker.diagnosticsWritten()
        XCTAssertEqual(reads.value, 1)
        let url = root.appendingPathComponent("open/\(try XCTUnwrap(first))/diagnostics.json")
        let written = try JSONDecoder().decode(DiagnosticsSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(written.lastError, "Stripe failed with ‹redacted:stripe-key›")
        XCTAssertEqual(written.app, snapshot.app)
        XCTAssertEqual(written.services, snapshot.services)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    /// The supervisor's issues have diagnostics: build, profile, DB mode,
    /// pending migrations and the tools.
    @MainActor
    func testTheSupervisorsIssueHasDiagnostics() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)"))
        let supervisor = makeSupervisor(defaults)
        supervisor.debugTracker = DebugTracker(baseDir: root.path)
        supervisor.pendingMigrations = ["20261101000000_add_holds"]
        supervisor.dbMode = .remote
        supervisor.diagnosticsTools = { _ in
            [ToolReport(name: "node", path: "/opt/homebrew/bin/node", version: "22.11.0", origin: .loginShell, searchedPath: "/usr/bin")]
        }

        await supervisor.captureDebugIssue(trigger: "manual", serviceID: nil, summary: "Something is wrong")

        await supervisor.debugTracker?.diagnosticsWritten()
        let listed = await supervisor.listDebugIssues()
        let issue = try XCTUnwrap(listed.first)
        let url = root.appendingPathComponent("open/\(issue.id)/diagnostics.json")
        let written = try JSONDecoder().decode(DiagnosticsSnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(written.app, DiagnosticsSnapshot.App(.current))
        XCTAssertEqual(written.dbMode, "remote")
        XCTAssertEqual(written.profile, supervisor.profile.rawValue)
        XCTAssertEqual(written.pendingMigrations, ["20261101000000_add_holds"])
        XCTAssertEqual(written.tools.map(\.version), ["22.11.0"])
        XCTAssertFalse(written.machine.macOS.isEmpty)
        XCTAssertFalse(written.machine.arch.isEmpty)
    }

    /// `running.marker`: a run that did not quit cleanly is one issue at the next
    /// launch. A clean quit deletes the marker, so the launch after it files nothing.
    @MainActor
    func testARunThatDidNotQuitCleanlyIsAnIssueAtTheNextLaunch() async throws {
        try writeConfig(#"{"enabled": true}"#)
        let marker = """
        {"app_version": "0.13.4", "pid": 4242, "started_at": "2026-11-16T09:14:03.412Z"}
        """
        try marker.write(to: root.appendingPathComponent("running.marker"), atomically: true, encoding: .utf8)
        let path = root.path

        let first = makeSupervisor(try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)")))
        first.makeIssueTracker = { DebugTracker(baseDir: path) }
        await first.initDebugTracking()

        let issues = await first.listDebugIssues()
        XCTAssertEqual(issues.map(\.trigger), ["unclean_exit"])
        XCTAssertEqual(
            issues.first?.errorMessage,
            "The last run did not quit cleanly. Look in ~/Library/Logs/DiagnosticReports. "
                + "It was \(Flavor.current.displayName) v0.13.4, pid 4242, started 2026-11-16T09:14:03.412Z. "
                + "It crashed, was force-quit, or the Mac lost power."
        )
        // The marker is this run's now.
        let current = try JSONDecoder().decode(
            DebugTracker.RunMarker.self, from: Data(contentsOf: root.appendingPathComponent("running.marker"))
        )
        XCTAssertEqual(current.pid, getpid())

        first.markCleanExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("running.marker").path))

        let second = makeSupervisor(try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)")))
        second.makeIssueTracker = { DebugTracker(baseDir: path) }
        await second.initDebugTracking()
        let after = await second.listDebugIssues()
        XCTAssertEqual(after.count, 1, "a clean quit files nothing")
        XCTAssertEqual(after.first?.recurrenceCount, 0)
    }

    /// Finding "an unclean-exit ticket cannot say why the app died": the issue
    /// has the tail of the last run's runner log, says where the full log is,
    /// and its summary says where to look.
    @MainActor
    func testAnUncleanExitIssueHasTheLastRunsRunnerLog() async throws {
        try writeConfig(#"{"enabled": true}"#)
        try #"{"app_version": "0.13.4", "pid": 4242, "started_at": "2026-11-16T09:14:03.412Z"}"#.write(
            to: root.appendingPathComponent("running.marker"), atomically: true, encoding: .utf8
        )
        let logs = root.appendingPathComponent("Logs")
        let earlier = LogFileSink(directory: logs, version: "0.13.4", now: { Date(timeIntervalSinceNow: -600) })
        earlier.write(id: LogFileSink.runnerLogID, entries: [
            LogEntry(timestamp: Date(timeIntervalSinceNow: -601), stream: .stdout, text: "health check of supabase"),
            LogEntry(timestamp: Date(timeIntervalSinceNow: -600), stream: .stderr, text: "restart of supabase failed"),
        ])
        let sink = LogFileSink(directory: logs, version: "0.14.0")
        let path = root.path
        let supervisor = EnvironmentSupervisor(
            userDefaults: try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)")), logSink: sink
        )
        supervisor.diagnosticsTools = { _ in [] }
        supervisor.makeIssueTracker = { DebugTracker(baseDir: path) }
        // This run's own runner line is not the last run's.
        await supervisor.logStore.append(serviceID: LogFileSink.runnerLogID, entry: LogEntry(stream: .stdout, text: "launched"))

        await supervisor.initDebugTracking()

        let issues = await supervisor.listDebugIssues()
        let issue = try XCTUnwrap(issues.first)
        XCTAssertEqual(issue.trigger, "unclean_exit")
        XCTAssertTrue(issue.summary.contains("Look in logs-all.txt [runner-last-run] and ~/Library/Logs/DiagnosticReports"), issue.summary)
        XCTAssertTrue(issue.errorMessage.hasSuffix("Its full runner log: \(logs.appendingPathComponent("runner.log").path)"), issue.errorMessage)
        let all = try String(contentsOf: root.appendingPathComponent("open/\(issue.id)/logs-all.txt"), encoding: .utf8)
        XCTAssertEqual(
            try withoutTimes(all),
            "[runner-last-run] health check of supabase\n[runner-last-run] restart of supabase failed\n[runner] launched"
        )
    }

    /// With capture off, the marker is still written, and no issue is filed.
    @MainActor
    func testTheMarkerIsKeptWhileCaptureIsOff() async throws {
        try writeConfig(#"{"enabled": false}"#)
        try #"{"pid": 1, "started_at": "x"}"#.write(
            to: root.appendingPathComponent("running.marker"), atomically: true, encoding: .utf8
        )
        let path = root.path
        let supervisor = makeSupervisor(try XCTUnwrap(UserDefaults(suiteName: "DebugTrackerTests-\(UUID().uuidString)")))
        supervisor.makeIssueTracker = { DebugTracker(baseDir: path) }

        await supervisor.initDebugTracking()

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("open").path))
        let current = try JSONDecoder().decode(
            DebugTracker.RunMarker.self, from: Data(contentsOf: root.appendingPathComponent("running.marker"))
        )
        XCTAssertEqual(current.pid, getpid())
    }
}

/// A clock that a test moves.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
