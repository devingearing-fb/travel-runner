import Foundation
import CryptoKit

struct MigrationTracker: Sendable {
    private let hashPath: String

    init(configDir: String = ConfigLoader.configDir) {
        self.hashPath = (configDir as NSString).appendingPathComponent("migration-hash.txt")
    }

    func migrationsChanged(portalCwd: String) -> Bool {
        let currentHash = computeHash(portalCwd: portalCwd)
        guard let currentHash else { return true }

        guard let storedHash = try? String(contentsOfFile: hashPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            return true
        }

        return currentHash != storedHash
    }

    func recordCurrentHash(portalCwd: String) {
        guard let hash = computeHash(portalCwd: portalCwd) else { return }
        try? hash.write(toFile: hashPath, atomically: true, encoding: .utf8)
    }

    func hasEverRun() -> Bool {
        FileManager.default.fileExists(atPath: hashPath)
    }

    private func computeHash(portalCwd: String) -> String? {
        let migrationsDir = (portalCwd as NSString).appendingPathComponent("supabase/migrations")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: migrationsDir) else {
            return nil
        }
        let sorted = files.filter { $0.hasSuffix(".sql") }.sorted()
        var hasher = SHA256()
        for file in sorted {
            hasher.update(data: Data(file.utf8))
            let filePath = (migrationsDir as NSString).appendingPathComponent(file)
            if let data = FileManager.default.contents(atPath: filePath) {
                hasher.update(data: data)
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
