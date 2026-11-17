import Foundation

struct DetectedRepos: Sendable {
    var monorepo: String?
    var universalLogin: String?
    var streamServices: String?
    var loadTest: String?
    /// Every checkout of the monorepo that the scan found, the preferred one first.
    /// The wizard shows a chooser when there are several.
    var monorepoCheckouts: [MonorepoCheckout] = []
    /// A checkout of the normal monorepo that the hackathon app cannot use.
    var otherFlavorMonorepo: String?

    var allDetected: Bool {
        monorepo != nil && universalLogin != nil && streamServices != nil && loadTest != nil
    }

    var detectedCount: Int {
        [monorepo, universalLogin, streamServices, loadTest].compactMap { $0 }.count
    }
}

/// A checkout of the monorepo: the main worktree or a linked one.
struct MonorepoCheckout: Sendable, Equatable {
    let path: String
    /// The main worktree has a `.git` folder. A linked worktree has a `.git` file.
    let isMainWorktree: Bool
    /// The branch that is checked out. `nil` when HEAD is detached or cannot be read.
    let branch: String?

    /// For the chooser, e.g. "main checkout · dev".
    var label: String {
        let kind = isMainWorktree ? "main checkout" : "worktree"
        return branch.map { "\(kind) · \($0)" } ?? kind
    }
}

enum RepoDetector {
    /// Scans the dropped folder itself, its children and its grandchildren.
    /// When several checkouts of the monorepo match, the main worktree wins over
    /// a linked one. The main worktree of a linked one is added when the scan did
    /// not reach it, as `git worktree list` would name it.
    static func scan(directory: String, flavor: Flavor = .current) -> DetectedRepos {
        let fm = FileManager.default
        let path = NSString(string: directory).expandingTildeInPath
        var result = DetectedRepos()
        var monorepos: [String] = []
        checkDirectory(path, flavor: flavor, result: &result, monorepos: &monorepos)

        for child in subdirectories(of: path) {
            checkDirectory(child, flavor: flavor, result: &result, monorepos: &monorepos)
            // One level deeper too (e.g. "Codebases/TRAVEL BOOKING/fb-travel-monolith"),
            // but never inside a monorepo checkout (of either app).
            guard !isMonorepo(child, flavor: .standard) else { continue }
            for grandchild in subdirectories(of: child) where fm.fileExists(atPath: grandchild) {
                checkDirectory(grandchild, flavor: flavor, result: &result, monorepos: &monorepos)
            }
        }

        for found in monorepos {
            if let main = mainWorktree(of: found), !monorepos.contains(main), isMonorepo(main, flavor: flavor) {
                monorepos.append(main)
            }
        }
        result.monorepoCheckouts = preferred(monorepos).map(checkout(at:))
        result.monorepo = result.monorepoCheckouts.first?.path
        return result
    }

    /// The main worktrees first, then by path. The first one is the default.
    static func preferred(_ paths: [String]) -> [String] {
        paths.sorted { a, b in
            let mainA = isMainWorktree(a), mainB = isMainWorktree(b)
            return mainA != mainB ? mainA : a < b
        }
    }

    /// The text for a checkout of the normal monorepo in the hackathon app. `nil` when
    /// the path fits this app or is not a monorepo.
    static func flavorMismatch(path: String, flavor: Flavor = .current) -> String? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard flavor.runsAgent, !isMonorepo(expanded, flavor: flavor), isMonorepo(expanded, flavor: .standard) else {
            return nil
        }
        return "This is the normal \(Flavor.standard.monorepoName). \(flavor.displayName) needs the hackathon fork "
            + "(\(agentDirectory)). For this repo, install \(Flavor.standard.displayName)."
    }

    static func validate(path: String, role: RepoRole, flavor: Flavor = .current) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        switch role {
        case .monorepo:
            return isMonorepo(expanded, flavor: flavor)
        case .universalLogin, .streamServices, .loadTest:
            return FileManager.default.fileExists(atPath: (expanded as NSString).appendingPathComponent("package.json"))
        }
    }

    /// The fb-travel monorepo: a pnpm workspace with the booking app and the shared supabase/ directory.
    /// The hackathon app takes only the fork, which also has the agent app. Thus a folder
    /// that holds the two checkouts gives each app its own repo.
    static func isMonorepo(_ path: String, flavor: Flavor = .current) -> Bool {
        let fm = FileManager.default
        var markers = ["pnpm-workspace.yaml", "apps/booking-portal/package.json", "supabase/config.toml"]
        if flavor.runsAgent { markers.append("\(agentDirectory)/package.json") }
        return markers.allSatisfy {
            fm.fileExists(atPath: (path as NSString).appendingPathComponent($0))
        }
    }

    /// The agent app of the hackathon fork, from the monorepo root.
    static let agentDirectory = "apps/amateur-agent"
    /// Platform core of the hackathon fork, from the monorepo root.
    static let platformCoreDirectory = "apps/platform-core"
    /// The event listing site of the hackathon fork, from the monorepo root.
    static let eventDirectory = "apps/event-directory"

    /// Finds the monorepo for a config that still points at an old sibling repo: the path
    /// itself or one of its ancestors, then the siblings at each of the three levels above it.
    static func findMonorepo(near path: String, flavor: Flavor = .current) -> String? {
        var current = NSString(string: path).expandingTildeInPath
        for _ in 0..<3 {
            if isMonorepo(current, flavor: flavor) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current else { break }
            if let sibling = preferred(subdirectories(of: parent).filter { isMonorepo($0, flavor: flavor) }).first {
                return sibling
            }
            current = parent
        }
        return nil
    }

    private static func subdirectories(of path: String) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        return names.compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let child = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: child, isDirectory: &isDir) && isDir.boolValue ? child : nil
        }
    }

    private static func packageName(at path: String) -> String? {
        let pkg = (path as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: pkg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["name"] as? String
    }

    private static func checkDirectory(
        _ path: String, flavor: Flavor, result: inout DetectedRepos, monorepos: inout [String]
    ) {
        let name = (path as NSString).lastPathComponent.lowercased()

        if isMonorepo(path, flavor: flavor) {
            if !monorepos.contains(path) { monorepos.append(path) }
            return
        }
        if flavor.runsAgent, result.otherFlavorMonorepo == nil, isMonorepo(path, flavor: .standard) {
            result.otherFlavorMonorepo = path
            return
        }

        // Universal login: its package name is unrelated. The folder name or the
        // origin remote names it, so a clone with another folder name is found too.
        if result.universalLogin == nil, packageName(at: path) != nil,
           name.contains("universal-login") || originURL(of: path)?.contains("universal-login") == true {
            result.universalLogin = path
        }

        switch packageName(at: path) {
        case "fb-amateur-stream-services" where result.streamServices == nil:
            result.streamServices = path
        case "@fastbreak-amateur/travel-load-test" where result.loadTest == nil:
            result.loadTest = path
        default:
            break
        }
    }

    // MARK: - Git metadata

    /// The files are read directly: no `git` process, so the wizard does not wait.

    /// True when `.git` in the folder is a folder: the main worktree of its repo.
    static func isMainWorktree(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let dotGit = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The git folder of a checkout: `.git` itself, or the folder that a `.git` file names.
    static func gitDirectory(of path: String) -> String? {
        let dotGit = (path as NSString).appendingPathComponent(".git")
        if isMainWorktree(path) { return dotGit }
        guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else {
            return nil
        }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return absolute(target, relativeTo: path)
    }

    /// The shared git folder of all worktrees of the repo.
    static func commonGitDirectory(of path: String) -> String? {
        guard let gitDir = gitDirectory(of: path) else { return nil }
        let commondir = (gitDir as NSString).appendingPathComponent("commondir")
        guard let text = try? String(contentsOfFile: commondir, encoding: .utf8) else { return gitDir }
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? gitDir : absolute(target, relativeTo: gitDir)
    }

    /// The main worktree of a linked worktree. `nil` for a main worktree or a bare repo.
    static func mainWorktree(of path: String) -> String? {
        guard !isMainWorktree(path), let common = commonGitDirectory(of: path),
              (common as NSString).lastPathComponent == ".git" else { return nil }
        return (common as NSString).deletingLastPathComponent
    }

    /// The checked-out branch, from HEAD.
    static func branch(of path: String) -> String? {
        guard let gitDir = gitDirectory(of: path),
              let head = try? String(contentsOfFile: (gitDir as NSString).appendingPathComponent("HEAD"), encoding: .utf8)
        else { return nil }
        let prefix = "ref: refs/heads/"
        let line = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
    }

    /// `remote.origin.url` from the repo's config.
    static func originURL(of path: String) -> String? {
        guard let common = commonGitDirectory(of: path),
              let text = try? String(contentsOfFile: (common as NSString).appendingPathComponent("config"), encoding: .utf8)
        else { return nil }
        var inOrigin = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line.replacingOccurrences(of: " ", with: "") == "[remote\"origin\"]"
                continue
            }
            guard inOrigin, let equals = line.firstIndex(of: "=") else { continue }
            if line[..<equals].trimmingCharacters(in: .whitespaces) == "url" {
                return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func checkout(at path: String) -> MonorepoCheckout {
        MonorepoCheckout(path: path, isMainWorktree: isMainWorktree(path), branch: branch(of: path))
    }

    private static func absolute(_ path: String, relativeTo base: String) -> String {
        let joined = path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
        return (joined as NSString).standardizingPath
    }

    enum RepoRole: String, CaseIterable, Sendable {
        case monorepo = "fb-travel Monorepo"
        case universalLogin = "Universal Login"
        case streamServices = "Stream Services"
        case loadTest = "Travel Load Test"

        var description: String {
            switch self {
            case .monorepo:
                Flavor.current.runsAgent
                    ? "The hackathon fork: Supabase, booking portal (3002), partner portal (3006), agent (2000), platform core (3007), event directory (3004)"
                    : "Supabase, booking portal (3002), partner portal (3006), travel-data"
            case .universalLogin: "Auth gateway (port 3000)"
            case .streamServices: "CDC ingest and reaction worker (port 3003)"
            case .loadTest: "Verification runs for the full profile"
            }
        }

        var icon: String {
            switch self {
            case .monorepo: "shippingbox"
            case .universalLogin: "person.badge.key"
            case .streamServices: "arrow.triangle.branch"
            case .loadTest: "gauge.with.dots.needle.67percent"
            }
        }

        /// Repos the core profiles need. Stream services and the load test serve only `full`.
        var isRequired: Bool {
            switch self {
            case .monorepo, .universalLogin: true
            case .streamServices, .loadTest: false
            }
        }
    }
}
