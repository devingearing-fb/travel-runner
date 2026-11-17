import Foundation

/// The migrations the database should have.
struct ExpectedMigrations: Equatable {
    /// Versions as the migration files name them (the timestamp before the first `_`).
    var versions: Set<String>
    /// Backend bootstrap version -> the local version `scripts/local-db.sh` applies it under.
    var aliases: [String: String] = [:]
}

/// Finds the migrations the local database has not applied. The monorepo replays the
/// fb-amateur-backend baseline plus its own pending `supabase/migrations/*.sql`, so the
/// expected versions are the files of both; the applied versions come from the database
/// (`supabase_migrations.schema_migrations`).
///
/// The database is the record, not a hash file: a reset outside the runner
/// (`pnpm db:reset`) or another runner build cannot make it stale, so a database that
/// is up to date is never reset again.
enum MigrationTracker {
    /// `scripts/local-db.sh` renames the two backend bootstraps (`*_init-roles.sql`,
    /// `*_init-schema.sql`) to these local versions before it applies them, so the
    /// database records them under these versions, not the ones in the file names.
    static let bootstrapAliases = ["init-roles": "00000000000000", "init-schema": "00000000000001"]

    /// The migrations the database should have, or nil when the backend baseline
    /// checkout is not there.
    static func expectedVersions(
        root: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ExpectedMigrations? {
        guard let backend = backendBaselineDir(root: root, environment: environment) else { return nil }
        let backendDir = (backend as NSString).appendingPathComponent("supabase/migrations")
        let dirs = [
            backendDir,
            (root as NSString).appendingPathComponent("supabase/migrations"),
        ]
        var expected = ExpectedMigrations(versions: [])
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for file in files where file.hasSuffix(".sql") {
                let parts = file.split(separator: "_", maxSplits: 1)
                guard let version = parts.first, !version.isEmpty else { continue }
                expected.versions.insert(String(version))
                // Only the backend bootstraps are renamed.
                if dir == backendDir, parts.count == 2,
                   let alias = bootstrapAliases[String(parts[1].dropLast(".sql".count))] {
                    expected.aliases[String(version)] = alias
                }
            }
        }
        return expected
    }

    /// Expected versions the database has not applied, oldest first. A bootstrap counts
    /// as applied under its original version or its local alias.
    static func missing(expected: ExpectedMigrations, applied: Set<String>) -> [String] {
        expected.versions.subtracting(applied)
            .filter { version in
                guard let alias = expected.aliases[version] else { return true }
                return !applied.contains(alias)
            }
            .sorted()
    }

    /// Applied versions that no migration file expects, oldest first.
    static func extra(expected: ExpectedMigrations, applied: Set<String>) -> [String] {
        applied.subtracting(expected.versions)
            .subtracting(expected.aliases.values)
            .sorted()
    }

    /// The backend checkout `scripts/local-db.sh` replays, in the script's resolution
    /// order. `.backend-baseline/` only moves during a reset, so it is the baseline the
    /// database was last built from.
    static func backendBaselineDir(
        root: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let dir = environment["FB_AMATEUR_BACKEND_DIR"], !dir.isEmpty { candidates.append(dir) }
        candidates.append(((root as NSString).deletingLastPathComponent as NSString).appendingPathComponent("fb-amateur-backend"))
        candidates.append((root as NSString).appendingPathComponent(".backend-baseline"))
        return candidates.first {
            fm.fileExists(atPath: ($0 as NSString).appendingPathComponent("supabase/migrations"))
        }
    }

    /// Parses `psql -tA` output: one version per line.
    static func parseVersions(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }
}

/// The local Supabase project of the monorepo.
enum SupabaseProject {
    /// Docker container of the local database: `supabase_db_<project_id>` from
    /// `supabase/config.toml`, falling back to the directory name like the Supabase CLI.
    static func dbContainerName(root: String) -> String {
        let configPath = (root as NSString).appendingPathComponent("supabase/config.toml")
        if let config = try? String(contentsOfFile: configPath, encoding: .utf8),
           let projectID = projectID(inConfig: config) {
            return "supabase_db_\(projectID)"
        }
        return "supabase_db_\((root as NSString).lastPathComponent)"
    }

    static func projectID(inConfig config: String) -> String? {
        for line in config.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("project_id") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = parts[1].split(separator: "#").first ?? ""
            let id = value.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return id.isEmpty ? nil : id
        }
        return nil
    }
}
