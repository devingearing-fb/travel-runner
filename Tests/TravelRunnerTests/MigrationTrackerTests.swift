import Foundation
import XCTest
@testable import TravelRunner

final class MigrationTrackerTests: XCTestCase {
    private var container: URL!
    private var root: URL!
    private var tracker: MigrationTracker!

    override func setUpWithError() throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigrationTrackerTests-\(UUID().uuidString)")
        root = container.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("supabase/migrations"),
            withIntermediateDirectories: true
        )
        try Data("# pending only".utf8).write(to: root.appendingPathComponent("supabase/migrations/README.md"))
        tracker = MigrationTracker(configDir: container.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
    }

    func testEmptyPendingDirectoryIsStableAfterRecording() {
        XCTAssertTrue(tracker.migrationsChanged(portalCwd: root.path))
        tracker.recordCurrentHash(portalCwd: root.path)
        XCTAssertFalse(tracker.migrationsChanged(portalCwd: root.path))
    }

    func testNewPendingMigrationChangesTheHash() throws {
        tracker.recordCurrentHash(portalCwd: root.path)
        try Data("select 1;".utf8).write(to: root.appendingPathComponent("supabase/migrations/20261014000000_change.sql"))
        XCTAssertTrue(tracker.migrationsChanged(portalCwd: root.path))
    }

    func testNewBackendBaselineCommitChangesTheHash() throws {
        let baseline = root.appendingPathComponent(".backend-baseline")
        try git(["init", "-q", baseline.path])
        try git(["-C", baseline.path, "commit", "-q", "--allow-empty", "-m", "one"])
        tracker.recordCurrentHash(portalCwd: root.path)
        XCTAssertFalse(tracker.migrationsChanged(portalCwd: root.path))

        try git(["-C", baseline.path, "commit", "-q", "--allow-empty", "-m", "two"])
        XCTAssertTrue(tracker.migrationsChanged(portalCwd: root.path))
    }

    func testSiblingBackendCheckoutWinsOverManagedClone() throws {
        let sibling = container.appendingPathComponent("TRAVEL BOOKING/fb-amateur-backend")
        try FileManager.default.createDirectory(
            at: sibling.appendingPathComponent("supabase/migrations"),
            withIntermediateDirectories: true
        )
        try git(["init", "-q", sibling.path])
        try git(["-C", sibling.path, "commit", "-q", "--allow-empty", "-m", "sibling"])
        let siblingSHA = try git(["-C", sibling.path, "rev-parse", "HEAD"])
        XCTAssertEqual(MigrationTracker.backendBaselineSHA(root: root.path, environment: [:]), siblingSHA)
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

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ]) { $1 }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
