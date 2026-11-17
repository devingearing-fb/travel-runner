import CryptoKit
import Foundation

/// Whether the packages of a repo match its lockfile.
enum DependencyState: String, Equatable, Sendable {
    /// No packages are installed. The service is started only after an install.
    case missing
    /// The lockfile changed after the last install. The row offers the install.
    case stale
    case fresh
}

/// `deps.json` in the config folder: for each install folder, the SHA-256 of its
/// lockfile at the last successful install. A branch that changes the lockfile
/// and changes it back is fresh again, which a file time cannot tell.
final class DependencyRecord: @unchecked Sendable {
    let path: String
    private let lock = NSLock()

    init(path: String) {
        self.path = path
    }

    /// `~/.config/<storage name>/deps.json`.
    static let live = DependencyRecord(path: (ConfigLoader.configDir as NSString).appendingPathComponent("deps.json"))

    func hash(for folder: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return read()[folder]
    }

    func record(_ hash: String, for folder: String) {
        lock.lock()
        defer { lock.unlock() }
        var entries = read()
        guard entries[folder] != hash else { return }
        entries[folder] = hash
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(entries).write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            print("[Deps] Could not write \(path): \(error)")
        }
    }

    private func read() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

actor DependencyWatcher {
    private let repoPaths: [String: String]
    private let record: DependencyRecord
    /// The services whose packages are missing or stale.
    private(set) var staleServices: Set<String> = []

    init(repoPaths: [String: String], record: DependencyRecord) {
        self.repoPaths = repoPaths
        self.record = record
    }

    @discardableResult
    func check() -> Set<String> {
        var stale = Set<String>()
        var verdicts: [String: DependencyState] = [:]
        for (serviceID, path) in repoPaths {
            let verdict = verdicts[path] ?? Self.state(of: path, record: record)
            verdicts[path] = verdict
            if verdict != .fresh { stale.insert(serviceID) }
        }
        staleServices = stale
        return stale
    }

    /// The state of the packages of `directory`.
    /// - No `package.json` (and no pnpm workspace): `.fresh`, there is nothing to install.
    /// - No `node_modules/.modules.yaml` at the workspace root, or no `node_modules`
    ///   in an npm repo: `.missing`.
    /// - A lockfile whose hash is the one in `record`: `.fresh`.
    /// - Otherwise the file times decide (`needsInstall`). When the install marker is
    ///   newer, someone installed by hand: the hash goes into `record` and the state is `.fresh`.
    static func state(of directory: String, record: DependencyRecord?) -> DependencyState {
        let directory = NSString(string: directory).expandingTildeInPath
        let fm = FileManager.default
        let workspace = pnpmWorkspaceRoot(containing: directory)
        let folder = workspace ?? directory
        if workspace == nil, !fm.fileExists(atPath: (directory as NSString).appendingPathComponent("package.json")) {
            return .fresh
        }
        let marker = workspace == nil ? "node_modules" : "node_modules/.modules.yaml"
        guard fm.fileExists(atPath: (folder as NSString).appendingPathComponent(marker)) else { return .missing }

        let installedAfterChange = !needsInstall(directory)
        guard let hash = lockHash(folder: folder) else { return installedAfterChange ? .fresh : .stale }
        if record?.hash(for: folder) == hash { return .fresh }
        guard installedAfterChange else { return .stale }
        record?.record(hash, for: folder)
        return .fresh
    }

    /// The SHA-256 of the lockfile of an install folder: `pnpm-lock.yaml` of a pnpm
    /// workspace, or `package-lock.json`. Nil when there is none.
    static func lockHash(folder: String) -> String? {
        for name in ["pnpm-lock.yaml", "package-lock.json"] {
            let path = (folder as NSString).appendingPathComponent(name)
            if let data = FileManager.default.contents(atPath: path) {
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return nil
    }

    /// Whether `directory` needs an install. Inside a pnpm workspace the install marker is
    /// the root `node_modules/.modules.yaml`, compared with the root lockfile and the
    /// directory's own `package.json`; a standalone npm repo uses
    /// `node_modules/.package-lock.json`. Nil-safe: no `package.json` means not stale.
    static func needsInstall(_ directory: String) -> Bool {
        let packageJSON = (directory as NSString).appendingPathComponent("package.json")
        let fm = FileManager.default
        if let root = pnpmWorkspaceRoot(containing: directory) {
            let marker = mtime((root as NSString).appendingPathComponent("node_modules/.modules.yaml"))
            guard let marker else { return true }
            let inputs = [(root as NSString).appendingPathComponent("pnpm-lock.yaml"), packageJSON].compactMap(mtime)
            return inputs.contains { $0 > marker }
        }
        guard fm.fileExists(atPath: packageJSON), let packageMtime = mtime(packageJSON) else { return false }
        guard let lockMtime = mtime((directory as NSString).appendingPathComponent("node_modules/.package-lock.json")) else {
            return true
        }
        return packageMtime > lockMtime
    }

    /// Where the packages of `directory` are installed, and the command that installs
    /// them: `pnpm install --frozen-lockfile` at the root of its pnpm workspace, or
    /// `npm install` in the directory itself.
    static func installTarget(for directory: String) -> (folder: String, command: String) {
        if let root = pnpmWorkspaceRoot(containing: directory) { return (root, "pnpm install --frozen-lockfile") }
        return (NSString(string: directory).expandingTildeInPath, "npm install")
    }

    /// The nearest directory at or above `directory` with a `pnpm-workspace.yaml`.
    static func pnpmWorkspaceRoot(containing directory: String) -> String? {
        var current = NSString(string: directory).expandingTildeInPath
        while true {
            if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent("pnpm-workspace.yaml")) {
                return current
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
    }

    private static func mtime(_ path: String) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }
}
