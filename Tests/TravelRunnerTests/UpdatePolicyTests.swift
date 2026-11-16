import Foundation
import XCTest
@testable import TravelRunner

/// The update rules: the one-time switch to automatic downloads, the pill, and the restart question.
final class UpdatePolicyTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "UpdatePolicyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func build(_ kind: String) -> BuildInfo {
        BuildInfo.resolve(
            info: ["CFBundleShortVersionString": "0.13.5", BuildInfo.kindKey: kind],
            flavor: .standard
        )
    }

    func testAReleaseBuildTurnsAutomaticDownloadsOnOnce() {
        var enabled = 0

        UpdatePolicy.applyAutoUpdateDefault(defaults: defaults, build: build("release")) { enabled += 1 }

        XCTAssertEqual(enabled, 1)
        XCTAssertTrue(defaults.bool(forKey: "didDefaultAutoUpdate_v1"))
    }

    func testTheSwitchDoesNotRunAgainSoTheUsersChoiceStays() {
        var enabled = 0
        UpdatePolicy.applyAutoUpdateDefault(defaults: defaults, build: build("release")) { enabled += 1 }

        // The next launches, after the user may have turned automatic downloads off.
        UpdatePolicy.applyAutoUpdateDefault(defaults: defaults, build: build("release")) { enabled += 1 }
        UpdatePolicy.applyAutoUpdateDefault(defaults: defaults, build: build("release")) { enabled += 1 }

        XCTAssertEqual(enabled, 1)
    }

    func testADevBuildLeavesTheSwitchForTheReleaseCopy() {
        var enabled = 0

        UpdatePolicy.applyAutoUpdateDefault(defaults: defaults, build: build("dev")) { enabled += 1 }

        XCTAssertEqual(enabled, 0)
        XCTAssertFalse(defaults.bool(forKey: UpdatePolicy.didDefaultAutoUpdateKey))

        UpdatePolicy.applyAutoUpdateDefault(defaults: defaults, build: build("release")) { enabled += 1 }
        XCTAssertEqual(enabled, 1)
    }

    func testThePillNamesTheVersionAndTheAction() {
        XCTAssertEqual(
            UpdatePolicy.pillText(.ready(version: "0.13.6")),
            "Update 0.13.6 ready — Restart to install"
        )
        XCTAssertEqual(UpdatePolicy.pillText(.available(version: "0.13.6")), "Update 0.13.6 available")
    }

    func testAStoppedStackRestartsWithoutAQuestion() {
        XCTAssertNil(UpdatePolicy.restartWarning(liveServices: 0))
    }

    func testARunningStackAsksBeforeTheRestart() {
        XCTAssertEqual(
            UpdatePolicy.restartWarning(liveServices: 4),
            "Restarting stops the running stack (4 services). Supabase keeps running."
        )
        XCTAssertEqual(
            UpdatePolicy.restartWarning(liveServices: 1),
            "Restarting stops the running stack (1 service). Supabase keeps running."
        )
    }
}
