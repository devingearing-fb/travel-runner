import Foundation

actor GitBranchWatcher {
    private let repos: [String: String]
    private(set) var branches: [String: String] = [:]
    private(set) var changedServices: Set<String> = []

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
            }
            if let branch {
                branches[serviceID] = branch
            }
        }
        changedServices = changed
        return changed
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
}
