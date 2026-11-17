import Foundation
import XCTest
@testable import TravelRunner

/// The contract `"runner": { "minVersion": "x.y.z" }` of `scripts/db/manifest.json`:
/// a runner older than the minimum resets nothing.
final class CompatibilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CompatibilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("scripts/db"), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeManifest(_ json: String) throws {
        try Data(json.utf8).write(to: URL(fileURLWithPath: Compatibility.manifestPath(root: root.path)))
    }

    private func requirement(_ json: String) -> Compatibility.Requirement {
        Compatibility.requirement(manifest: Data(json.utf8))
    }

    // MARK: - Versions

    func testTheManifestVersionIsExactlyThreeNumbers() {
        XCTAssertNotNil(Compatibility.Version(manifest: "0.14.0"))
        XCTAssertNotNil(Compatibility.Version(manifest: "10.0.123"))
        // The shapes that the monolith's own test refuses, and a few more.
        for bad in ["0.14", "v0.14.0", "0.14.0-beta", "00.14.0", "", "0.14.0.1", "0..1", " 0.14.0", "0.14.x",
                    "99999999999999999999.0.0"] {
            XCTAssertNil(Compatibility.Version(manifest: bad), bad)
        }
    }

    func testTheRunnerVersionCountsOnlyItsNumbers() {
        XCTAssertEqual(Compatibility.Version(runner: "0.13.4"), Compatibility.Version(manifest: "0.13.4"))
        // A dev build: `git describe` adds a suffix.
        XCTAssertEqual(Compatibility.Version(runner: "0.13.5-2-ga1b2c3d-dirty"), Compatibility.Version(manifest: "0.13.5"))
        XCTAssertEqual(Compatibility.Version(runner: "1.0"), Compatibility.Version(manifest: "1.0.0"))
        XCTAssertNil(Compatibility.Version(runner: "dev"))
        XCTAssertNil(Compatibility.Version(runner: ""))
    }

    func testVersionsCompareAsNumbersNotAsText() throws {
        let v = { try XCTUnwrap(Compatibility.Version(manifest: $0)) }
        XCTAssertLessThan(try v("0.9.0"), try v("0.14.0"))
        XCTAssertLessThan(try v("0.13.10"), try v("0.14.0"))
        XCTAssertLessThan(try v("0.14.0"), try v("0.14.1"))
        XCTAssertLessThan(try v("0.99.99"), try v("1.0.0"))
        XCTAssertFalse(try v("0.14.0") < v("0.14.0"))
    }

    // MARK: - Reading the manifest

    func testTheManifestNamesTheMinimum() {
        XCTAssertEqual(requirement(#"{"version":4,"runner":{"minVersion":"0.14.0"},"steps":[]}"#), .minVersion("0.14.0"))
    }

    func testAManifestWithoutTheFieldAsksNothing() throws {
        XCTAssertEqual(requirement(#"{"version":4,"steps":[]}"#), .none)
        XCTAssertEqual(requirement(#"{"runner":{}}"#), .none)
        XCTAssertEqual(requirement(#"{"runner":null}"#), .none)
        XCTAssertEqual(requirement(#"{"runner":{"minVersion":null}}"#), .none)
        // Not JSON, or not there: the DB setup reports that itself.
        XCTAssertEqual(requirement("not json"), .none)
        XCTAssertEqual(Compatibility.requirement(manifestPath: root.appendingPathComponent("none.json").path), .none)
    }

    func testAMinimumOutsideTheContractIsUnreadable() {
        XCTAssertEqual(requirement(#"{"runner":{"minVersion":"0.14"}}"#), .unreadable("0.14"))
        XCTAssertEqual(requirement(#"{"runner":{"minVersion":"v0.14.0"}}"#), .unreadable("v0.14.0"))
        XCTAssertEqual(requirement(#"{"runner":{"minVersion":14}}"#), .unreadable("14"))
        XCTAssertEqual(requirement(#"{"runner":"0.14.0"}"#), .unreadable("0.14.0"))
    }

    // MARK: - The check

    func testAnOlderRunnerIsTooOld() {
        XCTAssertEqual(
            Compatibility.check(requirement: .minVersion("0.14.0"), runnerVersion: "0.13.4"),
            .runnerTooOld(required: "0.14.0", current: "0.13.4")
        )
        XCTAssertTrue(Compatibility.Verdict.runnerTooOld(required: "0.14.0", current: "0.13.4").blocksResets)
    }

    func testTheSameOrANewerRunnerIsCompatible() {
        for current in ["0.14.0", "0.14.1", "0.15.0", "1.0.0", "0.14.0-3-gabc1234-dirty"] {
            XCTAssertEqual(
                Compatibility.check(requirement: .minVersion("0.14.0"), runnerVersion: current), .compatible, current
            )
        }
        XCTAssertFalse(Compatibility.Verdict.compatible.blocksResets)
    }

    func testACheckoutThatAsksNothingIsCompatible() {
        XCTAssertEqual(Compatibility.check(requirement: .none, runnerVersion: "0.1.0"), .compatible)
    }

    /// `swift run` and the tests have no Info.plist, so no version.
    func testARunnerWithNoVersionIsNotBlocked() {
        XCTAssertEqual(Compatibility.check(requirement: .minVersion("99.0.0"), runnerVersion: nil), .compatible)
        XCTAssertEqual(Compatibility.check(requirement: .minVersion("99.0.0"), runnerVersion: "dev"), .compatible)
        XCTAssertEqual(Compatibility.check(requirement: .unreadable("x"), runnerVersion: nil), .compatible)
    }

    /// A dev build is named by `git describe`, so its number is the last tag. It
    /// must not block every reset once the checkout names the next release.
    func testADevBuildHasNoVersionToCompareAndIsNotBlocked() {
        let dev = BuildInfo(version: "0.13.5-12-ga1b2c3d", build: "1", commit: "a1b2c3d", kind: .dev, flavor: .standard)
        let release = BuildInfo(version: "0.13.5", build: "1", commit: "a1b2c3d", kind: .release, flavor: .standard)
        XCTAssertNil(Compatibility.comparableVersion(of: dev))
        XCTAssertEqual(Compatibility.comparableVersion(of: release), "0.13.5")
        XCTAssertEqual(
            Compatibility.check(
                requirement: .minVersion("0.14.0"), runnerVersion: Compatibility.comparableVersion(of: dev)
            ),
            .compatible
        )
        // The control: the release build of the same number is blocked.
        XCTAssertEqual(
            Compatibility.check(
                requirement: .minVersion("0.14.0"), runnerVersion: Compatibility.comparableVersion(of: release)
            ),
            .runnerTooOld(required: "0.14.0", current: "0.13.5")
        )
    }

    func testAnUnreadableMinimumBlocksAVersionedRunner() {
        let verdict = Compatibility.check(requirement: .unreadable("0.14"), runnerVersion: "0.13.4")
        XCTAssertEqual(verdict, .unreadableRequirement(value: "0.14", current: "0.13.4"))
        XCTAssertTrue(verdict.blocksResets)
    }

    func testTheCheckReadsTheManifestOfTheCheckout() throws {
        // No manifest yet.
        XCTAssertEqual(Compatibility.check(root: root.path, runnerVersion: "0.13.4"), .compatible)

        try writeManifest(#"{"version":4,"runner":{"minVersion":"0.14.0"},"steps":[],"profiles":{}}"#)
        XCTAssertEqual(
            Compatibility.check(root: root.path, runnerVersion: "0.13.4"),
            .runnerTooOld(required: "0.14.0", current: "0.13.4")
        )
        XCTAssertEqual(Compatibility.check(root: root.path, runnerVersion: "0.14.0"), .compatible)
    }

    // MARK: - The text

    func testTheBannerTextNamesBothVersions() throws {
        let notice = try XCTUnwrap(Compatibility.notice(
            for: .runnerTooOld(required: "0.14.0", current: "0.13.4"), flavor: .standard
        ))
        XCTAssertEqual(
            notice.text,
            "This fb-travel-monolith checkout needs Travel Runner 0.14.0 or newer (you have 0.13.4). "
                + "The database was not touched."
        )
        XCTAssertEqual(notice.downloadURL.absoluteString, "https://github.com/devingearing-fb/travel-runner/releases/latest")
        XCTAssertEqual(Compatibility.updateButtonTitle, "Update \(Flavor.current.displayName)")
    }

    func testTheHackathonAppNamesItsOwnRepoAndReleases() throws {
        let notice = try XCTUnwrap(Compatibility.notice(
            for: .runnerTooOld(required: "1.2.0", current: "1.0.0"), flavor: .hackathon
        ))
        XCTAssertEqual(
            notice.text,
            "This fb-travel-monolith-hackathon checkout needs Travel Runner Hackathon 1.2.0 or newer "
                + "(you have 1.0.0). The database was not touched."
        )
        // The hackathon app is never the latest release.
        XCTAssertEqual(notice.downloadURL.absoluteString, "https://github.com/devingearing-fb/travel-runner/releases")
    }

    func testAnUnreadableMinimumHasItsOwnText() throws {
        let notice = try XCTUnwrap(Compatibility.notice(
            for: .unreadableRequirement(value: "0.14", current: "0.13.4"), flavor: .standard
        ))
        XCTAssertTrue(notice.text.contains("\"0.14\""), notice.text)
        XCTAssertTrue(notice.text.hasSuffix("The database was not touched."), notice.text)
    }

    func testACompatibleRunnerHasNoBanner() {
        XCTAssertNil(Compatibility.notice(for: .compatible, flavor: .standard))
    }
}
