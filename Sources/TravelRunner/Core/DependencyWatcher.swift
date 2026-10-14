import Foundation

actor DependencyWatcher {
    private let repoPaths: [String: String]
    private(set) var staleServices: Set<String> = []

    init(repoPaths: [String: String]) {
        self.repoPaths = repoPaths
    }

    @discardableResult
    func check() -> Set<String> {
        var stale = Set<String>()
        var verdicts: [String: Bool] = [:]
        for (serviceID, path) in repoPaths {
            let isStale = verdicts[path] ?? Self.needsInstall(path)
            verdicts[path] = isStale
            if isStale { stale.insert(serviceID) }
        }
        staleServices = stale
        return stale
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
