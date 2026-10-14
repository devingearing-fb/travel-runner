import Foundation

/// Tracks the branch and the commits-behind count of each service's git repository.
/// Services are grouped by repository root: in the monorepo, supabase, both portals and
/// the local CDC scripts share one repository, so it is read and fetched once.
actor GitBranchWatcher {
    /// serviceID → repository root (`git rev-parse --show-toplevel`); services outside git are absent.
    nonisolated let repoRoots: [String: String]
    private(set) var branches: [String: String] = [:]
    private(set) var changedServices: Set<String> = []
    private(set) var behindCounts: [String: Int] = [:]
    private var branchByRoot: [String: String] = [:]
    private var lastFetchedAt: [String: Date] = [:]

    init(repos: [String: String]) {
        var roots: [String: String] = [:]
        var cache: [String: String?] = [:]
        for (serviceID, path) in repos {
            let root = cache[path] ?? Self.git(["rev-parse", "--show-toplevel"], in: path)
            cache[path] = root
            if let root { roots[serviceID] = root }
        }
        self.repoRoots = roots
    }

    private var servicesByRoot: [String: [String]] {
        Dictionary(grouping: repoRoots.keys, by: { repoRoots[$0]! })
    }

    @discardableResult
    func check() -> Set<String> {
        var changed = Set<String>()
        for (root, serviceIDs) in servicesByRoot {
            // --abbrev-ref resolves HEAD in worktrees too (.git is a file there).
            guard let ref = Self.git(["rev-parse", "--abbrev-ref", "HEAD"], in: root) else { continue }
            let branch = ref == "HEAD"
                ? String((Self.git(["rev-parse", "HEAD"], in: root) ?? "").prefix(8))
                : ref
            if let previous = branchByRoot[root], previous != branch {
                changed.formUnion(serviceIDs)
                lastFetchedAt[root] = nil
            }
            branchByRoot[root] = branch
            for serviceID in serviceIDs { branches[serviceID] = branch }
        }
        changedServices = changed
        return changed
    }

    func fetchAndCount(fetchInterval: TimeInterval = 120) async {
        for (root, serviceIDs) in servicesByRoot {
            let needsFetch = lastFetchedAt[root].map { Date.now.timeIntervalSince($0) >= fetchInterval } ?? true
            if needsFetch {
                _ = Self.git(["fetch", "--quiet"], in: root)
                lastFetchedAt[root] = .now
            }
            let count = Int(Self.git(["rev-list", "HEAD..@{upstream}", "--count"], in: root) ?? "") ?? 0
            for serviceID in serviceIDs { behindCounts[serviceID] = count }
        }
    }

    /// Runs git in `directory`; trimmed stdout on success, nil on failure.
    private static func git(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }
}
