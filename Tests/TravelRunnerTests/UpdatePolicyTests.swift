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

    /// A new release goes to the canary feed first (`release.sh`). Only a copy that
    /// was put on the canary channel reads it.
    func testOnlyACopyOnTheCanaryChannelReadsTheCanaryFeed() {
        XCTAssertNil(UpdatePolicy.feedURL(defaults: defaults, flavor: .standard), "no value: the feed of Info.plist")

        defaults.set("canary", forKey: UpdatePolicy.channelKey)
        XCTAssertEqual(
            UpdatePolicy.feedURL(defaults: defaults, flavor: .standard),
            "https://github.com/devingearing-fb/travel-runner/releases/download/canary-appcast/appcast.xml"
        )
        // The hackathon app has one feed.
        XCTAssertNil(UpdatePolicy.feedURL(defaults: defaults, flavor: .hackathon))

        defaults.set("stable", forKey: UpdatePolicy.channelKey)
        XCTAssertNil(UpdatePolicy.feedURL(defaults: defaults, flavor: .standard))
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

    // MARK: - Restart without a click

    func testAnIdleAppRestartsByItself() {
        XCTAssertTrue(UpdatePolicy.mayRestartUnattended(UpdatePolicy.RestartState(), isDev: false))
    }

    func testAnythingThatARestartWouldInterruptKeepsTheAppRunning() {
        let busy: [(String, UpdatePolicy.RestartState)] = [
            ("stack", UpdatePolicy.RestartState(stackRunning: true)),
            ("window", UpdatePolicy.RestartState(panelOpen: true)),
            ("database", UpdatePolicy.RestartState(databaseBusy: true)),
            ("fix", UpdatePolicy.RestartState(fixRunning: true)),
            ("reconfigure", UpdatePolicy.RestartState(reconfigureRunning: true)),
        ]
        for (name, state) in busy {
            XCTAssertFalse(UpdatePolicy.mayRestartUnattended(state, isDev: false), name)
        }
    }

    func testADevBuildNeverRestartsByItself() {
        XCTAssertFalse(UpdatePolicy.mayRestartUnattended(UpdatePolicy.RestartState(), isDev: true))
    }

    /// Somebody who just stopped the stack may start it again: one idle tick is not enough.
    func testTheRestartWaitsForIdleTicksInARow() {
        var ticks = UpdatePolicy.idleTicks(after: 0, idle: true)
        XCTAssertLessThan(ticks, UpdatePolicy.idleTicksBeforeRestart)

        ticks = UpdatePolicy.idleTicks(after: ticks, idle: false)
        XCTAssertEqual(ticks, 0, "a busy tick starts the count again")

        ticks = UpdatePolicy.idleTicks(after: ticks, idle: true)
        ticks = UpdatePolicy.idleTicks(after: ticks, idle: true)
        XCTAssertEqual(ticks, UpdatePolicy.idleTicksBeforeRestart)
    }

    // MARK: - Versions behind

    func testTheVersionsBehindComeFromTheListInTheAppcast() {
        XCTAssertEqual(
            UpdatePolicy.versionsBehind(current: "0.13.4", latest: "0.13.7", released: "0.13.3 0.13.4 0.13.5 0.13.7"),
            2,
            "0.13.6 was never released to everyone"
        )
        XCTAssertEqual(
            UpdatePolicy.versionsBehind(current: "0.13.4", latest: "0.14.0", released: "0.13.10 0.13.9 0.14.0 0.14.1"),
            3,
            "numbers, not text, and nothing above the newest"
        )
    }

    func testAnAppcastWithoutTheListCountsAsOneVersion() {
        XCTAssertEqual(UpdatePolicy.versionsBehind(current: "0.13.4", latest: "0.13.7", released: nil), 1)
        XCTAssertEqual(UpdatePolicy.versionsBehind(current: "0.13.4", latest: "0.13.7", released: "garbage"), 1)
    }

    func testANewestVersionThatIsNotNewerIsNotBehind() {
        XCTAssertEqual(UpdatePolicy.versionsBehind(current: "0.13.7", latest: "0.13.7", released: "0.13.7"), 0)
        XCTAssertEqual(UpdatePolicy.versionsBehind(current: "0.13.8", latest: "0.13.7", released: "0.13.7"), 0)
    }

    func testTheBannerComesSevenDaysAfterTheFirstFinding() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let record = try XCTUnwrap(UpdatePolicy.recordLatest(
            defaults: defaults, current: "0.13.4", latest: "0.13.6", released: "0.13.5 0.13.6", now: start
        ))
        XCTAssertNil(UpdatePolicy.behindNotice(record, appName: "Travel Runner", now: start.addingTimeInterval(6 * 86_400)))

        // A later check finds a newer version. The date of the first finding stays.
        let later = try XCTUnwrap(UpdatePolicy.recordLatest(
            defaults: defaults, current: "0.13.4", latest: "0.13.7",
            released: "0.13.5 0.13.6 0.13.7", now: start.addingTimeInterval(5 * 86_400)
        ))
        XCTAssertEqual(later.since, start)

        XCTAssertEqual(
            UpdatePolicy.behindNotice(later, appName: "Travel Runner", now: start.addingTimeInterval(7 * 86_400)),
            "This Travel Runner is 3 versions behind (you: 0.13.4, latest: 0.13.7). Old versions can mis-handle the database."
        )
    }

    func testOneVersionBehindIsSingular() {
        let record = UpdatePolicy.BehindRecord(
            current: "0.13.6", latest: "0.13.7", versionsBehind: 1, since: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(
            UpdatePolicy.behindNotice(record, appName: "Travel Runner", now: Date(timeIntervalSince1970: 8 * 86_400)),
            "This Travel Runner is 1 version behind (you: 0.13.6, latest: 0.13.7). Old versions can mis-handle the database."
        )
    }

    func testTheRecordSurvivesARelaunchOfTheSameVersion() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let record = UpdatePolicy.recordLatest(
            defaults: defaults, current: "0.13.4", latest: "0.13.7", released: nil, now: start
        )

        XCTAssertEqual(UpdatePolicy.storedBehind(defaults: defaults, current: "0.13.4"), record)
    }

    func testAnUpdatedCopyForgetsTheRecord() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = UpdatePolicy.recordLatest(defaults: defaults, current: "0.13.4", latest: "0.13.7", released: nil, now: start)

        XCTAssertNil(UpdatePolicy.storedBehind(defaults: defaults, current: "0.13.7"))
        XCTAssertNil(defaults.data(forKey: UpdatePolicy.behindKey), "the record is gone, also for the next launch")
    }

    func testACheckThatFindsNothingNewerForgetsTheRecord() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = UpdatePolicy.recordLatest(defaults: defaults, current: "0.13.4", latest: "0.13.7", released: nil, now: start)

        let record = UpdatePolicy.recordLatest(
            defaults: defaults, current: "0.13.4", latest: "0.13.4", released: nil, now: start.addingTimeInterval(86_400)
        )

        XCTAssertNil(record)
        XCTAssertNil(UpdatePolicy.storedBehind(defaults: defaults, current: "0.13.4"))
    }
}
