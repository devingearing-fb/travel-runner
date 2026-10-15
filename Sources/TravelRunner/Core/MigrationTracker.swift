import Foundation
import CryptoKit

/// Detects when the local database needs a reset. The monorepo replays the
/// fb-amateur-backend baseline plus its own pending migrations, so the hash covers
/// both: the pending `supabase/migrations/*.sql` files and the baseline commit.
struct MigrationTracker: Sendable {
    private let hashPath: String

    init(configDir: String = ConfigLoader.configDir) {
        self.hashPath = (configDir as NSString).appendingPathComponent("migration-hash.txt")
    }

    func migrationsChanged(portalCwd: String) -> Bool {
        let currentHash = computeHash(root: portalCwd)
        guard let currentHash else { return true }

        guard let storedHash = try? String(contentsOfFile: hashPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return true
        }

        return currentHash != storedHash
    }

    func recordCurrentHash(portalCwd: String) {
        guard let hash = computeHash(root: portalCwd) else { return }
        try? hash.write(toFile: hashPath, atomically: true, encoding: .utf8)
    }

    func hasEverRun() -> Bool {
        FileManager.default.fileExists(atPath: hashPath)
    }

    func computeHash(root: String) -> String? {
        let migrationsDir = (root as NSString).appendingPathComponent("supabase/migrations")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: migrationsDir) else {
            return nil
        }
        var hasher = SHA256()
        hasher.update(data: Data("monorepo-v1".utf8))
        for file in files.filter({ $0.hasSuffix(".sql") }).sorted() {
            hasher.update(data: Data(file.utf8))
            let filePath = (migrationsDir as NSString).appendingPathComponent(file)
            if let data = FileManager.default.contents(atPath: filePath) {
                hasher.update(data: data)
            }
        }
        hasher.update(data: Data("baseline:\(Self.backendBaselineSHA(root: root) ?? "none")".utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The backend commit `scripts/local-db.sh` replays, read locally (no fetch), in the
    /// script's resolution order. `.backend-baseline/` only moves during a reset, so its
    /// HEAD is the baseline the database was last built from.
    static func backendBaselineSHA(
        root: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let dir = environment["FB_AMATEUR_BACKEND_DIR"], !dir.isEmpty { candidates.append(dir) }
        let sibling = ((root as NSString).deletingLastPathComponent as NSString).appendingPathComponent("fb-amateur-backend")
        if fm.fileExists(atPath: (sibling as NSString).appendingPathComponent("supabase/migrations")) {
            candidates.append(sibling)
        }
        candidates.append((root as NSString).appendingPathComponent(".backend-baseline"))

        guard let dir = candidates.first(where: { fm.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git")) }) else {
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir, "rev-parse", "HEAD"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let sha = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
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
