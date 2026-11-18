import Foundation

/// Tracks the branch and the commits-behind count of each service's git repository.
/// Services are grouped by repository root: in the monorepo, supabase, both portals and
/// the local CDC scripts share one repository, so it is read and fetched once.
///
/// Every git command runs through `CommandRunning` with a time limit and without a
/// terminal prompt, off the main thread. A branch change counts only when two polls
/// agree and no rebase, merge, cherry-pick or bisect runs, and HEAD is on a branch.
actor GitBranchWatcher {
    /// serviceID → repository root (`git rev-parse --show-toplevel`); services outside git are absent.
    nonisolated let repoRoots: [String: String]
    private let shell: any CommandRunning
    private let clock: RunnerClock
    private(set) var branches: [String: String] = [:]
    private(set) var behindCounts: [String: Int] = [:]
    /// The tooltip of a repo whose last fetch failed, by service: "fetch failed 14:02 (remote not reachable)".
    private(set) var fetchFailures: [String: String] = [:]

    /// The last branch and commit that two polls agreed on, by root.
    private var confirmed: [String: Head] = [:]
    /// A new branch that one poll saw, by root. The next poll confirms it or drops it.
    private var candidate: [String: Head] = [:]
    private var lastFetchedAt: [String: Date] = [:]
    /// Failed fetches in a row, and when the next fetch may run, by root.
    private var fetchBackoff: [String: (failures: Int, nextAt: Date)] = [:]

    /// The time limit of a fetch. A remote that does not answer (a VPN, no network) ends here.
    static let fetchTimeout: Duration = .seconds(20)
    /// The time limit of a local git command.
    static let localTimeout: Duration = .seconds(10)
    /// The longest wait between two fetches of a remote that keeps failing.
    static let maxFetchBackoff: TimeInterval = 30 * 60
    /// git never asks for a password: the fetch fails instead of waiting for a prompt.
    /// Git Credential Manager and ssh-askpass open no window either. An askpass
    /// program that always fails overrides the one of the parent (VS Code sets one)
    /// and core.askPass, so git gets no answer and gives up at once.
    static let environment = [
        "GIT_ASKPASS": "/usr/bin/false",
        "GIT_TERMINAL_PROMPT": "0",
        "GCM_INTERACTIVE": "never",
        "SSH_ASKPASS_REQUIRE": "never",
    ]
    /// A file in the git folder while one of these runs. HEAD moves step by step then.
    static let busyMarkers = ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"]

    struct Head: Equatable, Sendable {
        let branch: String
        let commit: String
    }

    /// A branch change that two polls agreed on.
    struct Change: Equatable, Sendable {
        let serviceIDs: Set<String>
        let branch: String
        /// The files that differ between the old and the new commit; nil when git could not say.
        let changedFiles: [String]?

        /// True when a dev server must restart: its dependencies, its Next config or
        /// its env changed. Other files hot-reload. Unknown files restart, to be safe.
        var needsRestart: Bool {
            guard let changedFiles else { return true }
            return changedFiles.contains(where: GitBranchWatcher.needsRestart)
        }
    }

    init(roots: [String: String], shell: any CommandRunning, clock: RunnerClock = .live) {
        self.repoRoots = roots
        self.shell = shell
        self.clock = clock
    }

    /// The repository root of each folder. A folder outside git is left out.
    static func resolveRoots(repos: [String: String], shell: any CommandRunning) async -> [String: String] {
        var roots: [String: String] = [:]
        var cache: [String: String?] = [:]
        for (serviceID, path) in repos.sorted(by: { $0.key < $1.key }) {
            let root: String?
            if let cached = cache[path] {
                root = cached
            } else {
                let result = await shell.run(
                    "git -C \(ShellQuote.quote(path)) rev-parse --show-toplevel",
                    environment: environment, timeout: localTimeout
                )
                root = result.succeeded && !result.trimmedOutput.isEmpty ? result.trimmedOutput : nil
                cache[path] = root
            }
            if let root { roots[serviceID] = root }
        }
        return roots
    }

    /// True for a file whose change a running dev server does not pick up by itself.
    static func needsRestart(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name == "package.json"
            || ["pnpm-lock.yaml", "package-lock.json", "yarn.lock", "npm-shrinkwrap.json", "pnpm-workspace.yaml"].contains(name)
            || name.hasPrefix("next.config.")
            || name == ".env" || name.hasPrefix(".env.")
    }

    private var servicesByRoot: [String: [String]] {
        Dictionary(grouping: repoRoots.keys, by: { repoRoots[$0] ?? "" })
    }

    /// One poll. Returns the branch changes that this poll confirmed.
    @discardableResult
    func check() async -> [Change] {
        var changes: [Change] = []
        for (root, serviceIDs) in servicesByRoot.sorted(by: { $0.key < $1.key }) {
            guard let state = await readHead(root) else { continue }
            let shown = state.branch ?? String(state.commit.prefix(8))
            for serviceID in serviceIDs { branches[serviceID] = shown }
            // A rebase, merge, cherry-pick or bisect moves HEAD step by step, and a
            // detached HEAD is no branch: none of them is a branch change.
            guard !state.busy, let branch = state.branch else {
                candidate[root] = nil
                continue
            }
            let head = Head(branch: branch, commit: state.commit)
            guard let old = confirmed[root] else {
                confirmed[root] = head
                continue
            }
            if head.branch == old.branch {
                confirmed[root] = head
                candidate[root] = nil
                continue
            }
            // A change counts when the next poll sees the same branch and commit.
            guard candidate[root] == head else {
                candidate[root] = head
                continue
            }
            candidate[root] = nil
            confirmed[root] = head
            lastFetchedAt[root] = nil
            changes.append(Change(
                serviceIDs: Set(serviceIDs), branch: branch,
                changedFiles: await changedFiles(root, from: old.commit, to: head.commit)
            ))
        }
        return changes
    }

    private struct HeadState {
        let branch: String?
        let commit: String
        let busy: Bool
    }

    /// The branch (nil when detached), the commit, and whether an operation runs.
    private func readHead(_ root: String) async -> HeadState? {
        let quoted = ShellQuote.quote(root)
        let paths = await shell.run(
            "git -C \(quoted) rev-parse --absolute-git-dir HEAD", environment: Self.environment, timeout: Self.localTimeout
        )
        let lines = paths.trimmedOutput.split(separator: "\n").map(String.init)
        guard paths.succeeded, lines.count == 2 else { return nil }
        let (gitDir, commit) = (lines[0], lines[1])
        let busy = Self.busyMarkers.contains {
            FileManager.default.fileExists(atPath: (gitDir as NSString).appendingPathComponent($0))
        }
        let ref = await shell.run(
            "git -C \(quoted) symbolic-ref -q --short HEAD", environment: Self.environment, timeout: Self.localTimeout
        )
        let branch = ref.succeeded && !ref.trimmedOutput.isEmpty ? ref.trimmedOutput : nil
        return HeadState(branch: branch, commit: commit, busy: busy)
    }

    private func changedFiles(_ root: String, from old: String, to new: String) async -> [String]? {
        let result = await shell.run(
            "git -C \(ShellQuote.quote(root)) diff --name-only \(ShellQuote.quote(old)) \(ShellQuote.quote(new))",
            environment: Self.environment, timeout: Self.localTimeout
        )
        guard result.succeeded else { return nil }
        return result.trimmedOutput.split(separator: "\n").map(String.init)
    }

    /// Fetches each repo when its last fetch is `fetchInterval` old, and counts the
    /// commits behind its upstream. A failed fetch waits longer each time (up to 30
    /// min) and leaves a tooltip; the count then uses what the last fetch brought.
    func fetchAndCount(fetchInterval: TimeInterval = 120) async {
        for (root, serviceIDs) in servicesByRoot.sorted(by: { $0.key < $1.key }) {
            let now = clock.date()
            let due = lastFetchedAt[root].map { now.timeIntervalSince($0) >= fetchInterval } ?? true
            let allowed = fetchBackoff[root].map { now >= $0.nextAt } ?? true
            if due && allowed {
                lastFetchedAt[root] = now
                let result = await shell.run(
                    "git -C \(ShellQuote.quote(root)) fetch --quiet", environment: Self.environment, timeout: Self.fetchTimeout
                )
                if result.succeeded {
                    fetchBackoff[root] = nil
                    for serviceID in serviceIDs { fetchFailures[serviceID] = nil }
                } else {
                    let failures = (fetchBackoff[root]?.failures ?? 0) + 1
                    let wait = min(max(fetchInterval, 120) * pow(2, Double(failures - 1)), Self.maxFetchBackoff)
                    fetchBackoff[root] = (failures, now.addingTimeInterval(wait))
                    let text = Self.fetchFailedText(at: now)
                    for serviceID in serviceIDs { fetchFailures[serviceID] = text }
                }
            }
            let count = await shell.run(
                "git -C \(ShellQuote.quote(root)) rev-list HEAD..@{upstream} --count",
                environment: Self.environment, timeout: Self.localTimeout
            )
            let behind = count.succeeded ? Int(count.trimmedOutput) ?? 0 : 0
            for serviceID in serviceIDs { behindCounts[serviceID] = behind }
        }
    }

    /// "fetch failed 14:02 (remote not reachable)".
    static func fetchFailedText(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return "fetch failed \(formatter.string(from: date)) (remote not reachable)"
    }
}
