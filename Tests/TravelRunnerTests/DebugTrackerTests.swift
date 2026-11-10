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
