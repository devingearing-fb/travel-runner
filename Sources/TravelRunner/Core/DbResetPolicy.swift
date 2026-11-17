import Foundation

/// The one rule for when the runner may reset the local database by itself.
///
/// Only an empty database is set up without a question. A database with data is
/// never reset because migrations changed, unless the person turned on
/// "Reset the database when migrations change" in Settings. Otherwise the runner
/// shows a banner and offers "Apply migrations" or "Reset and reseed…".
enum DbResetPolicy {
    /// The profile of `scripts/db/manifest.json` that applies the missing
    /// migrations and never resets.
    static let migrateProfile = "migrate"
    /// The UserDefaults key of the opt-in setting. Off by default.
    static let autoResetSettingKey = "autoResetOnMigrations"

    /// How the database differs from the migration files of the checkout.
    struct MigrationStatus: Equatable, Sendable {
        /// Versions the database lacks, oldest first.
        var missing: [String]
        /// Versions only the database has, oldest first.
        var extra: [String]
        /// A backend bootstrap is missing. Apply cannot add it on top of data.
        var missingBootstrap: Bool

        var isCurrent: Bool { missing.isEmpty && extra.isEmpty }

        static func compare(expected: ExpectedMigrations, applied: Set<String>) -> MigrationStatus {
            let missing = MigrationTracker.missing(expected: expected, applied: applied)
            return MigrationStatus(
                missing: missing,
                extra: MigrationTracker.extra(expected: expected, applied: applied),
                missingBootstrap: missing.contains { expected.aliases[$0] != nil }
            )
        }
    }

    /// Who built the database: the row that `reset-database.mjs` writes to
    /// `travel_runner.seed_state`. Older rows lack some columns.
    struct BuiltFrom: Equatable, Sendable {
        var checkoutPath: String?
        var branch: String?
        var backendSha: String?
        var flavor: String?

        /// Reads the answer of `SELECT row_to_json(s) FROM travel_runner.seed_state s`.
        /// The last line holds the JSON: a login profile can print before it.
        static func parse(_ output: String) -> BuiltFrom? {
            guard let line = DbQueryResult.lastLine(of: output),
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return nil
            }
            func text(_ key: String) -> String? {
                guard let value = object[key] as? String, !value.isEmpty else { return nil }
                return value
            }
            return BuiltFrom(
                checkoutPath: text("checkout_path"), branch: text("branch"),
                backendSha: text("backend_sha"), flavor: text("flavor")
            )
        }
    }

    /// The checkout this runner runs.
    struct Checkout: Equatable, Sendable {
        var path: String
        var branch: String?
    }

    enum ResetReason: Equatable, Sendable {
        case missingMigrations(Int)
        case extraMigrations(Int)
        case missingBootstrap
    }

    enum Decision: Equatable, Sendable {
        /// Nothing to do, or nothing the runner can know.
        case none
        /// The database is empty: set it up without asking.
        case autoSetup
        /// The opt-in setting is on: reset without asking.
        case autoReset(ResetReason)
        /// Ask; "Apply migrations" can add these versions.
        case offerMigrate([String])
        /// Ask; only a reset can bring the database in line.
        case offerReset(ResetReason)
        /// The database could not be read. Nothing may change.
        case blocked(String)
    }

    /// `migrations` is nil when the applied versions could not be read; the runner
    /// then does nothing about migrations. `builtFrom` is nil when no reset recorded it.
    static func decide(
        probe: DbProbe,
        migrations: MigrationStatus?,
        builtFrom: BuiltFrom?,
        current: Checkout,
        autoResetOnMigrations: Bool
    ) -> Decision {
        switch probe {
        case .unknown(let detail):
            return .blocked(DbProbe.unreadableMessage(detail))
        case .empty:
            return .autoSetup
        case .hasTables:
            break
        }
        guard let migrations, !migrations.isCurrent else { return .none }
        let reason: ResetReason?
        if migrations.missingBootstrap {
            reason = .missingBootstrap
        } else if !migrations.extra.isEmpty {
            reason = .extraMigrations(migrations.extra.count)
        } else {
            reason = nil
        }
        // The setting resets only a database that this checkout built. Another
        // checkout's data is never replaced without a question.
        if autoResetOnMigrations, !builtElsewhere(builtFrom, current: current) {
            return .autoReset(reason ?? .missingMigrations(migrations.missing.count))
        }
        if let reason { return .offerReset(reason) }
        return .offerMigrate(migrations.missing)
    }

    /// True when the last reset ran in another checkout. An unknown builder is not
    /// another checkout.
    static func builtElsewhere(_ builtFrom: BuiltFrom?, current: Checkout) -> Bool {
        guard let path = builtFrom?.checkoutPath else { return false }
        return canonical(path) != canonical(current.path)
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - What the person reads

    private static func migrations(_ count: Int) -> String {
        "\(count) migration\(count == 1 ? "" : "s")"
    }

    /// `baseline` is "<path> @ <sha>", or nil when it is not known.
    static func missingHeadline(count: Int, baseline: String?) -> String {
        "Local database is missing \(migrations(count))" + (baseline.map { " (from \($0))" } ?? "")
    }

    static func extraHeadline(count: Int) -> String {
        "The database has \(migrations(count)) this branch does not have. Apply cannot undo them — reset to match this branch."
    }

    static let missingBootstrapText =
        "The database was not built with this checkout's bootstrap migrations. Apply cannot add them on top of your data. Reset and reseed to continue."

    static func otherCheckoutText(_ builtFrom: BuiltFrom, project: String) -> String {
        let path = builtFrom.checkoutPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "another checkout"
        let branch = builtFrom.branch.map { " (\($0))" } ?? ""
        return "This database was last built from \(path)\(branch). Resetting replaces it for every checkout that shares project `\(project)`."
    }

    static let appliedText =
        "Migrations applied. Types and seed data were not regenerated — reset if scenario data looks wrong."

    static func emptySetupFailedText(step: String, message: String) -> String {
        "Database setup failed at \(step): \(message). Portals were not started."
    }

    /// A setup passed after Start All stopped before the portals.
    static let setUpAfterHaltText = "Database is set up. Click Retry to start the portals."

    /// The scenario of an apply when none is selected. The `migrate` steps seed nothing.
    static let noScenario = DbSeedScenario(
        id: "", name: "None (migrations only)", description: "", fileSummary: "", variables: []
    )

    static let noMigrateProfileText =
        "This branch has no Apply migrations step (no \"migrate\" profile in scripts/db/manifest.json). Nothing was changed."

    /// The banner while the database differs from the checkout.
    struct Notice: Equatable, Sendable {
        let headline: String
        let detail: String?
        /// "Apply migrations" can help: only versions are missing, and the
        /// checkout has the `migrate` profile.
        let offersApply: Bool
        /// The body of the "Reset and reseed…" confirmation.
        let resetConfirmation: String
    }

    static let resetConfirmationTitle = "Reset the local database?"
    static let resetConfirmationBody = "Every local booking, block and user is deleted, and the database is rebuilt from this checkout."

    /// Nil when the database matches the checkout.
    static func notice(
        status: MigrationStatus,
        baseline: String?,
        builtFrom: BuiltFrom?,
        current: Checkout,
        project: String,
        hasMigrateProfile: Bool
    ) -> Notice? {
        guard !status.isCurrent else { return nil }
        let elsewhere = builtElsewhere(builtFrom, current: current)
        let otherCheckout = elsewhere ? builtFrom.map { otherCheckoutText($0, project: project) } : nil
        let headline: String
        let detail: String?
        if !status.extra.isEmpty && !status.missingBootstrap {
            headline = extraHeadline(count: status.extra.count)
            detail = otherCheckout ?? versionList(status.extra)
        } else {
            headline = missingHeadline(count: status.missing.count, baseline: baseline)
            detail = status.missingBootstrap ? missingBootstrapText : (otherCheckout ?? versionList(status.missing))
        }
        let canApply = hasMigrateProfile && !status.missingBootstrap && status.extra.isEmpty
        return Notice(
            headline: headline,
            detail: detail,
            offersApply: canApply,
            resetConfirmation: [resetConfirmationBody, otherCheckout].compactMap { $0 }.joined(separator: " ")
        )
    }

    private static func versionList(_ versions: [String]) -> String {
        versions.prefix(3).joined(separator: ", ") + (versions.count > 3 ? " …" : "")
    }
}
