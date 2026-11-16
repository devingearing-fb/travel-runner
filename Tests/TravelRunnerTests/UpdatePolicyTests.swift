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

    // MARK: - The pending update

    func testADownloadedUpdateShowsAsReady() {
        XCTAssertEqual(
            UpdatePolicy.pending(nil, after: .downloaded(version: "0.13.6")),
            .ready(version: "0.13.6")
        )
    }

    func testAScheduledCheckShowsTheUpdateButAUserCheckDoesNot() {
        XCTAssertEqual(
            UpdatePolicy.pending(nil, after: .found(version: "0.13.6", userInitiated: false)),
            .available(version: "0.13.6")
        )
        XCTAssertNil(UpdatePolicy.pending(nil, after: .found(version: "0.13.6", userInitiated: true)))
    }

    func testAnAvailableUpdateClearsWhenTheUserSeesItOrTheWindowCloses() {
        let available = PendingUpdate.available(version: "0.13.6")

        XCTAssertNil(UpdatePolicy.pending(available, after: .seen))
        XCTAssertNil(UpdatePolicy.pending(available, after: .windowSessionEnded))
    }

    func testADownloadedUpdateStaysWhenTheWindowCloses() {
        let ready = PendingUpdate.ready(version: "0.13.6")

        XCTAssertEqual(UpdatePolicy.pending(ready, after: .seen), ready)
        XCTAssertEqual(UpdatePolicy.pending(ready, after: .windowSessionEnded), ready)
    }

    func testTheEndOfTheCycleClearsThePill() {
        XCTAssertNil(UpdatePolicy.pending(.ready(version: "0.13.6"), after: .cycleEnded))
        XCTAssertNil(UpdatePolicy.pending(.available(version: "0.13.6"), after: .cycleEnded))
    }

    // MARK: - The click on the pill

    func testADatabaseResetOrSetupBlocksTheRestart() {
        XCTAssertNil(UpdatePolicy.restartBlockedReason(dbResetRunning: false, setupPipelineRunning: false))
        XCTAssertEqual(
            UpdatePolicy.restartBlockedReason(dbResetRunning: true, setupPipelineRunning: false),
            "A database reset is running. Restart after it ends."
        )
        XCTAssertEqual(
            UpdatePolicy.restartBlockedReason(dbResetRunning: false, setupPipelineRunning: true),
            "A database setup is running. Restart after it ends."
        )
    }

    func testAClickInstallsAsksOrOpensTheWindow() {
        let ready = PendingUpdate.ready(version: "0.13.6")

        XCTAssertEqual(UpdatePolicy.pillAction(pending: ready, liveServices: 0, blockedReason: nil), .install)
        XCTAssertEqual(
            UpdatePolicy.pillAction(pending: ready, liveServices: 2, blockedReason: nil),
            .ask("Restarting stops the running stack (2 services). Supabase keeps running.")
        )
        XCTAssertEqual(
            UpdatePolicy.pillAction(pending: .available(version: "0.13.6"), liveServices: 2, blockedReason: nil),
            .showUpdateWindow
        )
    }

    func testABusyDatabaseBlocksTheClickEvenWithAStoppedStack() {
        XCTAssertEqual(
            UpdatePolicy.pillAction(pending: .ready(version: "0.13.6"), liveServices: 0, blockedReason: "busy"),
            .blocked("busy")
        )
        XCTAssertEqual(
            UpdatePolicy.pillAction(pending: .available(version: "0.13.6"), liveServices: 0, blockedReason: "busy"),
            .blocked("busy")
        )
    }

    // MARK: - Dev builds

    func testADevBuildDoesNotInstallInTheBackground() {
        XCTAssertFalse(UpdatePolicy.mayProceed(isDev: true, backgroundCheck: true, automaticDownloads: true))
        // The prompt of a scheduled check and a check by the user still work.
        XCTAssertTrue(UpdatePolicy.mayProceed(isDev: true, backgroundCheck: true, automaticDownloads: false))
        XCTAssertTrue(UpdatePolicy.mayProceed(isDev: true, backgroundCheck: false, automaticDownloads: true))
        XCTAssertTrue(UpdatePolicy.mayProceed(isDev: false, backgroundCheck: true, automaticDownloads: true))
    }
}
