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
            MigrationTracker.expectedVersions(root: root.path, environment: [:])?.versions,
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
        XCTAssertEqual(
            MigrationTracker.expectedVersions(root: root.path, environment: [:])?.versions,
            ["20260202000000"]
        )
    }

    func testBootstrapFilesMapToLocalVersions() throws {
        let baseline = root.appendingPathComponent(".backend-baseline")
        try migration(in: baseline, "20260909184456_init-roles.sql")
        try migration(in: baseline, "20260909184457_init-schema.sql")
        try migration(in: baseline, "20260101000000_base.sql")
        // A pending file of the monorepo is never renamed, whatever its name.
        try migration(in: root, "20261014000000_init-roles.sql")
        let expected = try XCTUnwrap(MigrationTracker.expectedVersions(root: root.path, environment: [:]))
        XCTAssertEqual(expected.aliases, [
            "20260909184456": "00000000000000",
            "20260909184457": "00000000000001",
        ])

        // The database local-db.sh builds records the bootstraps under the local versions.
        let applied = MigrationTracker.parseVersions(
            "00000000000000\n00000000000001\n20260101000000\n20261014000000\n"
        )
        XCTAssertEqual(MigrationTracker.missing(expected: expected, applied: applied), [])
        XCTAssertEqual(MigrationTracker.extra(expected: expected, applied: applied), [])

        // A database that never got a bootstrap still misses it.
        XCTAssertEqual(
            MigrationTracker.missing(
                expected: expected,
                applied: ["00000000000000", "20260101000000", "20261014000000"]
            ),
            ["20260909184457"]
        )
    }

    func testBootstrapAppliedUnderOriginalVersionIsNotMissing() throws {
        let baseline = root.appendingPathComponent(".backend-baseline")
        try migration(in: baseline, "20260909184456_init-roles.sql")
        try migration(in: baseline, "20260909184457_init-schema.sql")
        let expected = try XCTUnwrap(MigrationTracker.expectedVersions(root: root.path, environment: [:]))
        let applied: Set<String> = ["20260909184456", "20260909184457"]
        XCTAssertEqual(MigrationTracker.missing(expected: expected, applied: applied), [])
        XCTAssertEqual(MigrationTracker.extra(expected: expected, applied: applied), [])
    }

    func testExtraListsAppliedVersionsNoFileExpects() throws {
        try migration(in: root.appendingPathComponent(".backend-baseline"), "20260101000000_base.sql")
        let expected = try XCTUnwrap(MigrationTracker.expectedVersions(root: root.path, environment: [:]))
        XCTAssertEqual(
            MigrationTracker.extra(expected: expected, applied: ["20260101000000", "20270101000000", "00000000000000"]),
            ["00000000000000", "20270101000000"]
        )
    }

    // MARK: - The real bootstrap names

    /// The local versions that `scripts/local-db.sh` gives the two backend
    /// bootstraps, read from the script. The finding: the runner expected the
    /// file versions, found 2 "missing" migrations on every Start, and reset.
    private func aliasesOfTheScript() throws -> [String: String] {
        let script = try MonolithCheckout.text("scripts/local-db.sh")
        // `for kind in init-roles init-schema; do`
        let loop = try XCTUnwrap(script.firstMatch(of: try Regex(#"for kind in ([a-z -]+); do"#)))
        let kinds = try XCTUnwrap(loop.output[1].substring).split(separator: " ").map(String.init)
        // `mv "${matches[0]}" "$WORKSPACE/supabase/migrations/0000000000000${order}_$kind.sql"`
        let move = try XCTUnwrap(script.firstMatch(of: try Regex(#"migrations/([0-9]+)\$\{order\}_\$kind\.sql"#)))
        let prefix = try XCTUnwrap(move.output[1].substring)
        XCTAssertNotNil(script.firstMatch(of: try Regex(#"\border=0\b"#)), "the count starts at 0")
        return Dictionary(uniqueKeysWithValues: kinds.enumerated().map { ($1, "\(prefix)\($0)") })
    }

    func testTheBootstrapAliasesAreTheVersionsThatLocalDbShGives() throws {
        let aliases = try aliasesOfTheScript()
        XCTAssertEqual(aliases, ["init-roles": "00000000000000", "init-schema": "00000000000001"])
        XCTAssertEqual(MigrationTracker.bootstrapAliases, aliases)
    }

    /// One row per state of a local database that teammates had. The baseline has
    /// the two bootstraps under their real names, and an older file as on prod.
    func testEachDatabaseStateMissesTheRightMigrations() throws {
        let aliases = try aliasesOfTheScript()
        let roles = try XCTUnwrap(aliases["init-roles"])
        let schema = try XCTUnwrap(aliases["init-schema"])
        let backend = container.appendingPathComponent("TRAVEL BOOKING/fb-amateur-backend")
        try migration(in: backend, "20260909144500_customer_detail_from_checkout.sql")
        try migration(in: backend, "20260909184456_init-roles.sql")
        try migration(in: backend, "20260909184457_init-schema.sql")
        try migration(in: backend, "20261001000000_base.sql")
        try migration(in: root, "20261014000000_change.sql")
        let expected = try XCTUnwrap(MigrationTracker.expectedVersions(root: root.path, environment: [:]))
        let rest: Set<String> = ["20260909144500", "20261001000000", "20261014000000"]

        let rows: [(name: String, applied: Set<String>, missing: [String], extra: [String])] = [
            ("built by local-db.sh", rest.union([roles, schema]), [], []),
            ("built before local-db.sh renamed the bootstraps", rest.union(["20260909184456", "20260909184457"]), [], []),
            ("a new migration of the branch", rest.subtracting(["20261014000000"]).union([roles, schema]), ["20261014000000"], []),
            ("never got init-schema", rest.union([roles]), ["20260909184457"], []),
            ("no history", [], ["20260909144500", "20260909184456", "20260909184457", "20261001000000", "20261014000000"], []),
            ("ahead of the branch", rest.union([roles, schema, "20270101000000"]), [], ["20270101000000"]),
        ]
        for row in rows {
            XCTAssertEqual(MigrationTracker.missing(expected: expected, applied: row.applied), row.missing, row.name)
            XCTAssertEqual(MigrationTracker.extra(expected: expected, applied: row.applied), row.extra, row.name)
        }
    }

    /// The container that `apply-migrations.mjs` asks is `supabase_db_fb-travel`.
    func testTheContainerOfTheMonolithIsTheOneItsScriptsAsk() throws {
        XCTAssertEqual(SupabaseProject.dbContainerName(root: try MonolithCheckout.root().path), "supabase_db_fb-travel")
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
