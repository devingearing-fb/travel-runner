import Foundation

actor GitBranchWatcher {
    private let repos: [String: String]
    private(set) var branches: [String: String] = [:]
    private(set) var changedServices: Set<String> = []
    private(set) var behindCounts: [String: Int] = [:]
    private var lastFetchedAt: [String: Date] = [:]

    init(repos: [String: String]) {
        self.repos = repos
    }

    @discardableResult
    func check() -> Set<String> {
        var changed = Set<String>()
        for (serviceID, path) in repos {
            let branch = readBranch(at: path)
            if let prev = branches[serviceID], prev != branch {
                changed.insert(serviceID)
                lastFetchedAt[path] = nil
            }
            if let branch {
                branches[serviceID] = branch
            }
            behindCounts[serviceID] = countBehind(at: path)
        }
        changedServices = changed
        return changed
    }

    func fetchAndCount(fetchInterval: TimeInterval = 120) async {
        let uniquePaths = deduplicatedPaths()

        for (path, serviceIDs) in uniquePaths {
            let needsFetch: Bool
            if let last = lastFetchedAt[path] {
                needsFetch = Date.now.timeIntervalSince(last) >= fetchInterval
            } else {
                needsFetch = true
            }

            if needsFetch {
                await shellRun("cd \"\(path)\" && git fetch --quiet 2>/dev/null")
                lastFetchedAt[path] = .now
            }

            let count = countBehind(at: path)
            for sid in serviceIDs {
                behindCounts[sid] = count
            }
        }
    }

    private func deduplicatedPaths() -> [String: [String]] {
        var map: [String: [String]] = [:]
        for (serviceID, path) in repos {
            map[path, default: []].append(serviceID)
        }
        return map
    }

    private func countBehind(at repoPath: String) -> Int {
        let headPath = (repoPath as NSString).appendingPathComponent(".git/HEAD")
        guard let content = try? String(contentsOfFile: headPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return 0 }
        guard content.hasPrefix("ref: refs/heads/") else { return 0 }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "cd \"\(repoPath)\" && git rev-list HEAD..@{upstream} --count 2>/dev/null"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 0
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int(output) ?? 0
    }

    private func readBranch(at repoPath: String) -> String? {
        let headPath = (repoPath as NSString).appendingPathComponent(".git/HEAD")
        guard let content = try? String(contentsOfFile: headPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let prefix = "ref: refs/heads/"
        if content.hasPrefix(prefix) {
            return String(content.dropFirst(prefix.count))
        }
        return String(content.prefix(8))
    }

    @discardableResult
    private func shellRun(_ command: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
