import Foundation
import XCTest
@testable import TravelRunner

/// The one rule for when the runner may reset the local database by itself.
final class DbResetPolicyTests: XCTestCase {
    private let here = DbResetPolicy.Checkout(path: "/work/fb-travel-monolith", branch: "dev")
    private let missingOne = DbResetPolicy.MigrationStatus(missing: ["20261101000000"], extra: [], missingBootstrap: false)
    private let extraOne = DbResetPolicy.MigrationStatus(missing: [], extra: ["20261201000000"], missingBootstrap: false)
    private let noBootstrap = DbResetPolicy.MigrationStatus(
        missing: ["20260101000000", "20261101000000"], extra: [], missingBootstrap: true
    )
    private let elsewhere = DbResetPolicy.BuiltFrom(
        checkoutPath: "/work/fb-travel-monolith-hackathon", branch: "main", backendSha: nil, flavor: "hackathon"
    )

    private func decide(
        _ probe: DbProbe,
        _ migrations: DbResetPolicy.MigrationStatus?,
        builtFrom: DbResetPolicy.BuiltFrom? = nil,
        setting: Bool = false
    ) -> DbResetPolicy.Decision {
        DbResetPolicy.decide(
            probe: probe, migrations: migrations, builtFrom: builtFrom, current: here, autoResetOnMigrations: setting
        )
    }

    // MARK: - The decision

    func testOnlyAnEmptyDatabaseIsSetUpWithoutAQuestion() {
        XCTAssertEqual(decide(.empty, nil), .autoSetup)
        XCTAssertEqual(decide(.empty, missingOne), .autoSetup)
        XCTAssertEqual(decide(.hasTables, missingOne), .offerMigrate(["20261101000000"]))
        XCTAssertEqual(decide(.hasTables, extraOne), .offerReset(.extraMigrations(1)))
        XCTAssertEqual(decide(.hasTables, noBootstrap), .offerReset(.missingBootstrap))
    }

    func testADatabaseThatCannotBeReadIsBlocked() {
        XCTAssertEqual(
            decide(.unknown("No such container: x"), missingOne, setting: true),
            .blocked("Could not read the local database (No such container: x). Nothing was changed.")
        )
    }

    func testNothingIsDoneWhenTheMigrationsMatchOrCannotBeRead() {
        let current = DbResetPolicy.MigrationStatus(missing: [], extra: [], missingBootstrap: false)
        XCTAssertEqual(decide(.hasTables, current, setting: true), .none)
        XCTAssertEqual(decide(.hasTables, nil, setting: true), .none)
    }

    /// The opt-in setting resets a database this checkout built, or one with no
    /// record. Never one that another checkout built.
    func testTheSettingResetsOnlyADatabaseOfThisCheckout() {
        XCTAssertEqual(decide(.hasTables, missingOne, setting: true), .autoReset(.missingMigrations(1)))
        XCTAssertEqual(decide(.hasTables, extraOne, setting: true), .autoReset(.extraMigrations(1)))
        let mine = DbResetPolicy.BuiltFrom(checkoutPath: "/work/fb-travel-monolith/", branch: "feature")
        XCTAssertEqual(decide(.hasTables, missingOne, builtFrom: mine, setting: true), .autoReset(.missingMigrations(1)))

        XCTAssertEqual(decide(.hasTables, missingOne, builtFrom: elsewhere, setting: true), .offerMigrate(["20261101000000"]))
        XCTAssertEqual(decide(.hasTables, extraOne, builtFrom: elsewhere, setting: true), .offerReset(.extraMigrations(1)))
    }

    func testABootstrapAppliedUnderNeitherVersionIsAMissingBootstrap() {
        let expected = ExpectedMigrations(
            versions: ["20250101000000", "20250101000001", "20261101000000"],
            aliases: ["20250101000000": "00000000000000", "20250101000001": "00000000000001"]
        )
        let built = DbResetPolicy.MigrationStatus.compare(
            expected: expected, applied: ["00000000000000", "00000000000001", "20261201000000"]
        )
        XCTAssertEqual(built, DbResetPolicy.MigrationStatus(
            missing: ["20261101000000"], extra: ["20261201000000"], missingBootstrap: false
        ))
        let unbuilt = DbResetPolicy.MigrationStatus.compare(expected: expected, applied: ["20261101000000"])
        XCTAssertTrue(unbuilt.missingBootstrap)
    }

    // MARK: - Who built the database

    func testTheSeedStateRowIsRead() {
        let row = #"{"singleton":true,"scenario_id":"standard","checkout_path":"/work/a","branch":"dev","backend_sha":"abc","flavor":"standard"}"#
        XCTAssertEqual(
            DbResetPolicy.BuiltFrom.parse("nvm: using v22\n" + row),
            DbResetPolicy.BuiltFrom(checkoutPath: "/work/a", branch: "dev", backendSha: "abc", flavor: "standard")
        )
        // An older row has no such columns; NULL is not a value.
        XCTAssertEqual(
            DbResetPolicy.BuiltFrom.parse(#"{"scenario_id":"standard","branch":null}"#),
            DbResetPolicy.BuiltFrom()
        )
        XCTAssertNil(DbResetPolicy.BuiltFrom.parse(""))
        XCTAssertNil(DbResetPolicy.BuiltFrom.parse("not json"))
    }

    func testAnUnknownBuilderIsNotAnotherCheckout() {
        XCTAssertFalse(DbResetPolicy.builtElsewhere(nil, current: here))
        XCTAssertFalse(DbResetPolicy.builtElsewhere(DbResetPolicy.BuiltFrom(), current: here))
        XCTAssertTrue(DbResetPolicy.builtElsewhere(elsewhere, current: here))
    }

    // MARK: - What the person reads

    func testTheBannerOfMissingMigrationsOffersApply() throws {
        let notice = try XCTUnwrap(DbResetPolicy.notice(
            status: missingOne, baseline: "~/code/fb-amateur-backend @ a1b2c3d", builtFrom: nil,
            current: here, project: "fb-travel", hasMigrateProfile: true
        ))
        XCTAssertEqual(notice.headline, "Local database is missing 1 migration (from ~/code/fb-amateur-backend @ a1b2c3d)")
        XCTAssertEqual(notice.detail, "20261101000000")
        XCTAssertTrue(notice.offersApply)
        XCTAssertEqual(notice.resetConfirmation, DbResetPolicy.resetConfirmationBody)

        // A branch without the `migrate` profile: no Apply button.
        let older = try XCTUnwrap(DbResetPolicy.notice(
            status: missingOne, baseline: nil, builtFrom: nil, current: here, project: "fb-travel", hasMigrateProfile: false
        ))
        XCTAssertEqual(older.headline, "Local database is missing 1 migration")
        XCTAssertFalse(older.offersApply)
    }

    func testExtraVersionsOrAMissingBootstrapOfferOnlyAReset() throws {
        let extra = try XCTUnwrap(DbResetPolicy.notice(
            status: DbResetPolicy.MigrationStatus(missing: ["1"], extra: ["2", "3"], missingBootstrap: false),
            baseline: nil, builtFrom: nil, current: here, project: "fb-travel", hasMigrateProfile: true
        ))
        XCTAssertEqual(
            extra.headline,
            "The database has 2 migrations this branch does not have. Apply cannot undo them — reset to match this branch."
        )
        XCTAssertFalse(extra.offersApply)

        let bootstrap = try XCTUnwrap(DbResetPolicy.notice(
            status: noBootstrap, baseline: nil, builtFrom: nil, current: here, project: "fb-travel", hasMigrateProfile: true
        ))
        XCTAssertEqual(bootstrap.headline, "Local database is missing 2 migrations")
        XCTAssertEqual(bootstrap.detail, DbResetPolicy.missingBootstrapText)
        XCTAssertFalse(bootstrap.offersApply)
    }

    func testTheResetOfADatabaseFromAnotherCheckoutSaysWhoseItIs() throws {
        let notice = try XCTUnwrap(DbResetPolicy.notice(
            status: missingOne, baseline: nil, builtFrom: elsewhere, current: here, project: "fb-travel", hasMigrateProfile: true
        ))
        let other = "This database was last built from /work/fb-travel-monolith-hackathon (main). "
            + "Resetting replaces it for every checkout that shares project `fb-travel`."
        XCTAssertEqual(notice.detail, other)
        XCTAssertEqual(notice.resetConfirmation, DbResetPolicy.resetConfirmationBody + " " + other)
    }

    func testNoBannerWhenTheDatabaseMatches() {
        XCTAssertNil(DbResetPolicy.notice(
            status: DbResetPolicy.MigrationStatus(missing: [], extra: [], missingBootstrap: false),
            baseline: nil, builtFrom: nil, current: here, project: "fb-travel", hasMigrateProfile: true
        ))
    }

    func testTheTextsOfThePlan() {
        XCTAssertEqual(
            DbResetPolicy.appliedText,
            "Migrations applied. Types and seed data were not regenerated — reset if scenario data looks wrong."
        )
        XCTAssertEqual(
            DbResetPolicy.emptySetupFailedText(step: "Load Hotels", message: "HTTP 401"),
            "Database setup failed at Load Hotels: HTTP 401. Portals were not started."
        )
    }

    // MARK: - The manifest

    func testTheProfileNamesOfTheManifest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DbResetPolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest = folder.appendingPathComponent("manifest.json")

        XCTAssertNil(DbManifestLoader.profileNames(from: manifest.path))
        try Data(#"{"steps":[],"profiles":{"reset":["a"],"migrate":["b"]}}"#.utf8).write(to: manifest)
        XCTAssertEqual(DbManifestLoader.profileNames(from: manifest.path), ["reset", "migrate"])
        try Data(#"{"steps":[],"profiles":{"reset":["a"]}}"#.utf8).write(to: manifest)
        XCTAssertEqual(DbManifestLoader.profileNames(from: manifest.path)?.contains("migrate"), false)
    }
}
