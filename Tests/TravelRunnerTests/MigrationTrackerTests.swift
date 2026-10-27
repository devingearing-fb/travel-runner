import Foundation
import XCTest
@testable import TravelRunner

final class MigrationTrackerTests: XCTestCase {
    private var container: URL!
    private var root: URL!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationTrackerTests-\(UUID().uuidString)")
        root = container.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("supabase/migrations"),
            withIntermediateDirectories: true
        )
        try Data("# pending only".utf8).write(to: root.appendingPathComponent("supabase/migrations/README.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    func testNoBaselineCheckoutMeansUnknown() {
        XCTAssertNil(MigrationTracker.expectedVersions(root: root.path, environment: [:]))
    }

    func testExpectedVersionsAreBaselinePlusPending() throws {
        try migration(in: root.appendingPathComponent(".backend-baseline"), "20260101000000_base.sql")
        try migration(in: root, "20261014000000_change.sql")
        XCTAssertEqual(
            MigrationTracker.expectedVersions(root: root.path, environment: [:]),
            ["20260101000000", "20261014000000"]
        )
    }

    func testAnUpToDateDatabaseMissesNothing() throws {
        try migration(in: root.appendingPathComponent(".backend-baseline"), "20260101000000_base.sql")
        let expected = try XCTUnwrap(MigrationTracker.expectedVersions(root: root.path, environment: [:]))
        let applied = MigrationTracker.parseVersions("20260101000000\n20250101000000\n")
        XCTAssertEqual(MigrationTracker.missing(expected: expected, applied: applied), [])
    }

    func testANewPendingMigrationIsMissing() throws {
        try migration(in: root.appendingPathComponent(".backend-baseline"), "20260101000000_base.sql")
        try migration(in: root, "20261014000000_change.sql")
        let expected = try XCTUnwrap(MigrationTracker.expectedVersions(root: root.path, environment: [:]))
        let applied = MigrationTracker.parseVersions("20260101000000")
        XCTAssertEqual(MigrationTracker.missing(expected: expected, applied: applied), ["20261014000000"])
    }

    func testSiblingBackendCheckoutWinsOverManagedClone() throws {
        let sibling = container.appendingPathComponent("TRAVEL BOOKING/fb-amateur-backend")
        try migration(in: sibling, "20260202000000_sibling.sql")
        try migration(in: root.appendingPathComponent(".backend-baseline"), "20260101000000_base.sql")
        XCTAssertEqual(MigrationTracker.backendBaselineDir(root: root.path, environment: [:]), sibling.path)
        XCTAssertEqual(MigrationTracker.expectedVersions(root: root.path, environment: [:]), ["20260202000000"])
    }

    func testContainerNameComesFromProjectID() throws {
        try Data("""
        # comment
        project_id = "fb-travel"  # the CLI project

        [api]
        port = 54321
        """.utf8).write(to: root.appendingPathComponent("supabase/config.toml"))
        XCTAssertEqual(SupabaseProject.dbContainerName(root: root.path), "supabase_db_fb-travel")
    }

    func testContainerNameFallsBackToDirectoryName() {
        XCTAssertEqual(SupabaseProject.dbContainerName(root: root.path), "supabase_db_fb-travel-monolith")
    }

    private func migration(in checkout: URL, _ name: String) throws {
        let dir = checkout.appendingPathComponent("supabase/migrations")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("select 1;".utf8).write(to: dir.appendingPathComponent(name))
    }
}
