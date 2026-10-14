import Foundation
import XCTest
@testable import TravelRunner

final class RepoDetectorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-runner-repos-\(UUID().uuidString)")
            .appendingPathComponent("Codebases")
        let travel = root.appendingPathComponent("TRAVEL BOOKING")
        try makeMonorepo(at: travel.appendingPathComponent("fb-travel-monolith"))
        try writePackage(name: "@fastbreak-amateur/travel-load-test", at: travel.appendingPathComponent("travel-load-test"))
        try writePackage(name: "fb-amateur-booking-portal", at: travel.appendingPathComponent("travel-booking-portal"))
        try writePackage(name: "fb-amateur-accounting-webhooks", at: root.appendingPathComponent("fb-amateur-universal-login"))
        try writePackage(name: "fb-amateur-stream-services", at: root.appendingPathComponent("stream-services"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testScanFindsMonorepoAndExternalRepos() {
        let detected = RepoDetector.scan(directory: root.path)

        XCTAssertEqual(detected.monorepo, root.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith").path)
        XCTAssertEqual(detected.universalLogin, root.appendingPathComponent("fb-amateur-universal-login").path)
        XCTAssertEqual(detected.streamServices, root.appendingPathComponent("stream-services").path)
        XCTAssertEqual(detected.loadTest, root.appendingPathComponent("TRAVEL BOOKING/travel-load-test").path)
        XCTAssertTrue(detected.allDetected)
    }

    func testDroppingTheMonorepoItselfDetectsIt() {
        let monorepo = root.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith").path
        XCTAssertEqual(RepoDetector.scan(directory: monorepo).monorepo, monorepo)
    }

    func testFindMonorepoNearOldSiblingRepo() {
        let oldPortal = root.appendingPathComponent("TRAVEL BOOKING/travel-booking-portal").path
        XCTAssertEqual(
            RepoDetector.findMonorepo(near: oldPortal),
            root.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith").path
        )
        XCTAssertNil(RepoDetector.findMonorepo(near: FileManager.default.temporaryDirectory.appendingPathComponent("nowhere").path))
    }

    func testMonorepoNeedsAllThreeMarkers() throws {
        let partial = root.appendingPathComponent("partial")
        try writePackage(name: "x", at: partial.appendingPathComponent("apps/booking-portal"))
        try Data().write(to: partial.appendingPathComponent("pnpm-workspace.yaml"))
        XCTAssertFalse(RepoDetector.isMonorepo(partial.path))
    }

    func testStreamServicesValidationRequiresPackageManifest() throws {
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertFalse(RepoDetector.validate(path: empty.path, role: .streamServices))
        XCTAssertTrue(RepoDetector.validate(path: root.appendingPathComponent("stream-services").path, role: .streamServices))
    }

    private func makeMonorepo(at directory: URL) throws {
        try writePackage(name: "fb-travel-monolith", at: directory)
        try writePackage(name: "booking-portal", at: directory.appendingPathComponent("apps/booking-portal"))
        try Data().write(to: directory.appendingPathComponent("pnpm-workspace.yaml"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("supabase"), withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("supabase/config.toml"))
    }

    private func writePackage(name: String, at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["name": name])
        try data.write(to: directory.appendingPathComponent("package.json"))
    }
}
