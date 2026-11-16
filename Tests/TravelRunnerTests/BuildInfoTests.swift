import Foundation
import XCTest
@testable import TravelRunner

/// The build identity that Settings, the menu, `/api/status` and the tickets show.
final class BuildInfoTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildInfoTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let releaseInfo: [String: Any] = [
        "CFBundleShortVersionString": "0.13.5",
        "CFBundleVersion": "20261116120000",
        BuildInfo.commitKey: "a1b2c3d",
        BuildInfo.kindKey: "release",
    ]

    func testAReleaseBuildShowsVersionCommitFlavorAndKind() {
        let info = BuildInfo.resolve(info: releaseInfo, flavor: .standard)

        XCTAssertEqual(info.version, "0.13.5")
        XCTAssertEqual(info.build, "20261116120000")
        XCTAssertEqual(info.commit, "a1b2c3d")
        XCTAssertEqual(info.kind, .release)
        XCTAssertFalse(info.isDev)
        XCTAssertEqual(info.summary, "v0.13.5 (a1b2c3d) · standard · release")
        XCTAssertEqual(info.menuTitle, "Travel Runner v0.13.5 (a1b2c3d)")
    }

    func testADevBuildIsMarked() {
        var plist = releaseInfo
        plist["CFBundleShortVersionString"] = "0.13.5-2-ga1b2c3d-dirty"
        plist[BuildInfo.kindKey] = "dev"
        let info = BuildInfo.resolve(info: plist, flavor: .hackathon)

        XCTAssertTrue(info.isDev)
        XCTAssertEqual(info.summary, "v0.13.5-2-ga1b2c3d-dirty (a1b2c3d) · hackathon · dev")
        XCTAssertEqual(info.menuTitle, "Travel Runner Hackathon v0.13.5-2-ga1b2c3d-dirty (a1b2c3d) · DEV")
    }

    func testABuildThatDoesNotSayReleaseIsADevBuild() {
        // `swift run` and the tests have no Info.plist.
        let bare = BuildInfo.resolve(info: nil, flavor: .standard)
        XCTAssertEqual(bare.kind, .dev)
        XCTAssertNil(bare.version)
        XCTAssertNil(bare.commit)
        XCTAssertEqual(bare.summary, "v? · standard · dev")

        var plist = releaseInfo
        plist[BuildInfo.kindKey] = "other"
        XCTAssertEqual(BuildInfo.resolve(info: plist, flavor: .standard).kind, .dev)
        plist[BuildInfo.kindKey] = nil
        XCTAssertEqual(BuildInfo.resolve(info: plist, flavor: .standard).kind, .dev)
    }

    func testAnEmptyCommitIsNoCommit() {
        // A source build outside a git checkout writes an empty string.
        var plist = releaseInfo
        plist[BuildInfo.commitKey] = ""
        let info = BuildInfo.resolve(info: plist, flavor: .standard)

        XCTAssertNil(info.commit)
        XCTAssertEqual(info.summary, "v0.13.5 · standard · release")
    }

    func testTheStatusFieldsAreAlwaysStrings() {
        XCTAssertEqual(
            BuildInfo.resolve(info: releaseInfo, flavor: .standard).statusFields,
            ["version": "0.13.5", "build": "20261116120000", "commit": "a1b2c3d", "build_kind": "release"]
        )
        XCTAssertEqual(
            BuildInfo.resolve(info: nil, flavor: .standard).statusFields,
            ["version": "", "build": "", "commit": "", "build_kind": "dev"]
        )
    }

    func testATicketRecordsTheBuildThatFiledIt() async throws {
        try #"{"enabled": true}"#.write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let tracker = DebugTracker(
            baseDir: root.path,
            buildInfo: BuildInfo.resolve(info: releaseInfo, flavor: .standard)
        )

        let captured = await tracker.captureIssue(trigger: "manual", serviceId: nil, errorMessage: "Something is wrong")
        let id = try XCTUnwrap(captured)

        let url = root.appendingPathComponent("open/\(id)/issue.json")
        let issue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(issue["app_version"] as? String, "0.13.5")
        XCTAssertEqual(issue["app_build"] as? String, "20261116120000")
        XCTAssertEqual(issue["app_commit"] as? String, "a1b2c3d")
        XCTAssertEqual(issue["app_build_kind"] as? String, "release")
        XCTAssertEqual(issue["app_flavor"] as? String, "standard")
    }

    /// `/api/status` carries the build fields, next to the fields it had before.
    @MainActor
    func testTheStatusAnswerCarriesTheBuildFields() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BuildInfoTests-\(UUID().uuidString)"))
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)

        let json = supervisor.statusJSON(buildInfo: BuildInfo.resolve(info: releaseInfo, flavor: .standard))

        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(status["version"] as? String, "0.13.5")
        XCTAssertEqual(status["build"] as? String, "20261116120000")
        XCTAssertEqual(status["commit"] as? String, "a1b2c3d")
        XCTAssertEqual(status["build_kind"] as? String, "release")
        // Control: the fields from before are still there.
        XCTAssertEqual(status["app"] as? String, Flavor.current.rawValue)
        XCTAssertNotNil(status["health"])
        XCTAssertNotNil(status["services"])
    }

    /// A ticket from 0.13.5 that recurs on 0.13.6 said only 0.13.5, so it looked fixed
    /// in the newer version.
    func testARecurrenceRecordsTheBuildThatSawItLast() async throws {
        try #"{"enabled": true}"#.write(to: root.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        let first = DebugTracker(baseDir: root.path, buildInfo: BuildInfo.resolve(info: releaseInfo, flavor: .standard))
        let captured = await first.captureIssue(trigger: "manual", serviceId: nil, errorMessage: "Something is wrong")
        let id = try XCTUnwrap(captured)
        let url = root.appendingPathComponent("open/\(id)/issue.json")
        // Control: an issue that did not recur has no "last" build.
        let fresh = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNil(fresh["last_app_version"])

        var newer = releaseInfo
        newer["CFBundleShortVersionString"] = "0.13.6"
        newer["CFBundleVersion"] = "20261120120000"
        newer[BuildInfo.commitKey] = "e4f5a6b"
        let second = DebugTracker(baseDir: root.path, buildInfo: BuildInfo.resolve(info: newer, flavor: .standard))
        let again = await second.captureIssue(trigger: "manual", serviceId: nil, errorMessage: "Something is wrong")
        XCTAssertNil(again, "the same error bumps the open issue")

        let issue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(issue["recurrence_count"] as? Int, 1)
        XCTAssertEqual(issue["app_version"] as? String, "0.13.5", "the first capture stays")
        XCTAssertEqual(issue["app_commit"] as? String, "a1b2c3d")
        XCTAssertEqual(issue["last_app_version"] as? String, "0.13.6")
        XCTAssertEqual(issue["last_app_build"] as? String, "20261120120000")
        XCTAssertEqual(issue["last_app_commit"] as? String, "e4f5a6b")
    }

    func testATicketFromBeforeTheBuildFieldsStillLoads() async throws {
        let id = "20260821T141601_manual"
        let folder = root.appendingPathComponent("open/\(id)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"id": "\(id)", "summary": "old", "status": "open", "severity": "error", "category": "runtime",
         "trigger": "manual", "error_signature": "x", "error_message": "old",
         "created_at": "2026-08-21T14:16:01Z", "updated_at": "2026-08-21T14:16:01Z",
         "recurrence_count": 0, "recurrence_timestamps": []}
        """.write(to: folder.appendingPathComponent("issue.json"), atomically: true, encoding: .utf8)

        let issue = await DebugTracker(baseDir: root.path).getIssue(id: id)
        XCTAssertEqual(issue?.summary, "old")
        XCTAssertNil(issue?.appVersion)
    }
}
