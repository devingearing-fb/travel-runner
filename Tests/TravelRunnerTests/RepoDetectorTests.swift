import Foundation
import XCTest
@testable import TravelRunner

final class RepoDetectorTests: XCTestCase {
    func testScanFindsStreamServicesBesideTravelWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-runner-repos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let travelRoot = root.appendingPathComponent("TRAVEL BOOKING")
        let portal = travelRoot.appendingPathComponent("travel-booking-portal")
        let data = travelRoot.appendingPathComponent("fb-travel-data")
        let login = root.appendingPathComponent("fb-amateur-universal-login")
        let stream = root.appendingPathComponent("stream-services")

        try FileManager.default.createDirectory(
            at: portal.appendingPathComponent("supabase"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: portal.appendingPathComponent("src/app"),
            withIntermediateDirectories: true
        )
        try Data().write(to: portal.appendingPathComponent("supabase/config.toml"))
        try writePackage(name: "@fastbreak-amateur/fb-travel-data", at: data)
        try writePackage(name: "fb-amateur-universal-login", at: login)
        try writePackage(name: "fb-amateur-stream-services", at: stream)

        let detected = RepoDetector.scan(directory: root.path)

        XCTAssertEqual(detected.bookingPortal, portal.path)
        XCTAssertEqual(detected.travelData, data.path)
        XCTAssertEqual(detected.universalLogin, login.path)
        XCTAssertEqual(detected.streamServices, stream.path)
        XCTAssertTrue(detected.allDetected)
        XCTAssertEqual(detected.detectedCount, 4)
    }

    func testStreamServicesValidationRequiresPackageManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-runner-stream-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        XCTAssertFalse(RepoDetector.validate(path: root.path, role: .streamServices))
        try writePackage(name: "fb-amateur-stream-services", at: root)
        XCTAssertTrue(RepoDetector.validate(path: root.path, role: .streamServices))
    }

    private func writePackage(name: String, at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["name": name])
        try data.write(to: directory.appendingPathComponent("package.json"))
    }
}
