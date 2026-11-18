import Foundation
import XCTest
@testable import TravelRunner

final class WatcherTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPnpmWorkspaceUsesTheRootInstallMarker() throws {
        let workspace = root.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith")
        let app = workspace.appendingPathComponent("apps/booking-portal")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try touch(workspace.appendingPathComponent("pnpm-workspace.yaml"), at: date(0))
        try touch(workspace.appendingPathComponent("pnpm-lock.yaml"), at: date(10))
        try touch(app.appendingPathComponent("package.json"), at: date(10))

        XCTAssertEqual(DependencyWatcher.pnpmWorkspaceRoot(containing: app.path), workspace.path)
        XCTAssertTrue(DependencyWatcher.needsInstall(app.path), "no node_modules/.modules.yaml yet")

        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try touch(workspace.appendingPathComponent("node_modules/.modules.yaml"), at: date(20))
        XCTAssertFalse(DependencyWatcher.needsInstall(app.path))
        XCTAssertFalse(DependencyWatcher.needsInstall(workspace.path))

        try touch(workspace.appendingPathComponent("pnpm-lock.yaml"), at: date(30))
        XCTAssertTrue(DependencyWatcher.needsInstall(app.path), "lockfile changed after the install")
    }

    func testStandaloneNpmRepoKeepsThePackageLockMarker() throws {
        let repo = root.appendingPathComponent("universal-login")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try touch(repo.appendingPathComponent("package.json"), at: date(10))
        try touch(repo.appendingPathComponent("node_modules/.package-lock.json"), at: date(20))
        XCTAssertFalse(DependencyWatcher.needsInstall(repo.path))
        try touch(repo.appendingPathComponent("package.json"), at: date(30))
        XCTAssertTrue(DependencyWatcher.needsInstall(repo.path))
    }

    /// A pnpm workspace with an app, its lockfile written at time 10.
    private func workspace(lock: String = "lock A") throws -> (root: URL, app: URL) {
        let workspace = root.appendingPathComponent("mono")
        let app = workspace.appendingPathComponent("apps/booking-portal")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try touch(workspace.appendingPathComponent("pnpm-workspace.yaml"), at: date(0))
        try touch(app.appendingPathComponent("package.json"), at: date(0))
        try write(lock, to: workspace.appendingPathComponent("pnpm-lock.yaml"), at: date(10))
        return (workspace, app)
    }

    private func installed(_ workspace: URL, at offset: TimeInterval) throws {
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try touch(workspace.appendingPathComponent("node_modules/.modules.yaml"), at: date(offset))
    }

    private func record() -> DependencyRecord {
        DependencyRecord(path: root.appendingPathComponent("config/deps.json").path)
    }

    func testNoInstallMarkerIsMissing() throws {
        let (_, app) = try workspace()
        XCTAssertEqual(DependencyWatcher.state(of: app.path, record: record()), .missing)
        XCTAssertEqual(DependencyWatcher.installTarget(for: app.path).command, "pnpm install --frozen-lockfile")
    }

    /// An npm repo without node_modules is missing; with node_modules but an older
    /// marker it is stale, not missing. A folder without package.json needs nothing.
    func testNpmRepoMissingAndStaleAreDifferent() throws {
        let repo = root.appendingPathComponent("universal-login")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        XCTAssertEqual(DependencyWatcher.state(of: repo.path, record: record()), .fresh, "no package.json")
        try touch(repo.appendingPathComponent("package.json"), at: date(30))
        XCTAssertEqual(DependencyWatcher.state(of: repo.path, record: record()), .missing)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try touch(repo.appendingPathComponent("node_modules/.package-lock.json"), at: date(20))
        XCTAssertEqual(DependencyWatcher.state(of: repo.path, record: record()), .stale)
        XCTAssertEqual(DependencyWatcher.installTarget(for: repo.path).command, "npm install")
    }

    /// The lockfile hash decides: a branch that changes the lockfile is stale, and a
    /// branch that changes it back is fresh again, although the file is newer than
    /// the install. The file time alone says stale there.
    func testLockfileHashDecidesStaleAndFresh() throws {
        let (workspace, app) = try workspace(lock: "lock A")
        try installed(workspace, at: 20)
        let deps = record()
        XCTAssertEqual(DependencyWatcher.state(of: app.path, record: deps), .fresh)
        XCTAssertEqual(deps.hash(for: workspace.path), DependencyWatcher.lockHash(folder: workspace.path),
                       "an install found on disk becomes the baseline")

        try write("lock B", to: workspace.appendingPathComponent("pnpm-lock.yaml"), at: date(30))
        XCTAssertEqual(DependencyWatcher.state(of: app.path, record: deps), .stale)

        try write("lock A", to: workspace.appendingPathComponent("pnpm-lock.yaml"), at: date(40))
        XCTAssertTrue(DependencyWatcher.needsInstall(app.path), "negative control: the file time says stale")
        XCTAssertEqual(DependencyWatcher.state(of: app.path, record: deps), .fresh)
    }

    /// An install by hand after the lockfile changed counts: its hash is recorded.
    func testAnInstallByHandIsRecorded() throws {
        let (workspace, app) = try workspace(lock: "lock A")
        try installed(workspace, at: 20)
        let deps = record()
        deps.record("an older hash", marker: nil, for: workspace.path)
        XCTAssertEqual(DependencyWatcher.state(of: app.path, record: deps), .fresh)
        XCTAssertEqual(deps.hash(for: workspace.path), DependencyWatcher.lockHash(folder: workspace.path))
    }

    /// deps.json keeps one hash per install folder and reads back after a new instance.
    func testRecordPersists() throws {
        let deps = record()
        XCTAssertNil(deps.hash(for: "/repo"))
        deps.record("abc", marker: date(20), for: "/repo")
        deps.record("def", marker: nil, for: "/other")
        let again = record()
        XCTAssertEqual(again.entry(for: "/repo"), DependencyRecord.Entry(hash: "abc", marker: date(20).timeIntervalSince1970))
        XCTAssertEqual(again.entry(for: "/other"), DependencyRecord.Entry(hash: "def", marker: nil))
    }

    /// A matching hash counts only while the install marker is unchanged. Install on
    /// lock A, install lock B by hand, then check out lock A again: the packages are
    /// B's, so the state is stale although the hash of lock A is in the record.
    func testAHandInstallOnAnotherLockfileMakesTheRecordedHashStale() throws {
        let (workspace, app) = try workspace(lock: "lock A")
        try installed(workspace, at: 20)
        let deps = record()
        XCTAssertEqual(DependencyWatcher.state(of: app.path, record: deps), .fresh)
        XCTAssertEqual(deps.hash(for: workspace.path), DependencyWatcher.lockHash(folder: workspace.path))

        // No check runs between these steps: the runner was closed.
        try write("lock B", to: workspace.appendingPathComponent("pnpm-lock.yaml"), at: date(30))
        try installed(workspace, at: 40)
        try write("lock A", to: workspace.appendingPathComponent("pnpm-lock.yaml"), at: date(50))
        XCTAssertEqual(DependencyWatcher.state(of: app.path, record: deps), .stale)

        // The same steps with a check after the hand install: still stale.
        try write("lock B", to: workspace.appendingPathComponent("pnpm-lock.yaml"), at: date(60))
        try installed(workspace, at: 70)
        XCTAssertEqual(DependencyWatcher.state(of: app.path, record: deps), .fresh, "the hand install of lock B")
        try write("lock A", to: workspace.appendingPathComponent("pnpm-lock.yaml"), at: date(80))
        XCTAssertEqual(DependencyWatcher.state(of: app.path, record: deps), .stale)
    }

    /// The watcher lists missing and stale services, once per folder.
    func testWatcherListsServicesThatAreNotFresh() async throws {
        let (workspace, app) = try workspace()
        let other = root.appendingPathComponent("no-node")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let watcher = DependencyWatcher(
            repoPaths: ["travel-portal": app.path, "supabase": workspace.path, "plain": other.path], record: record()
        )
        let missing = await watcher.check()
        XCTAssertEqual(missing, ["travel-portal", "supabase"])
        try installed(workspace, at: 20)
        let fresh = await watcher.check()
        XCTAssertEqual(fresh, [])
    }

    // MARK: - Branch watcher

    /// A git that a test drives: one repo, its branch, its commit and its git folder.
    private final class FakeGit: @unchecked Sendable {
        private let lock = NSLock()
        let gitDir: URL
        private var _branch: String? = "dev"
        private var _commit = "aaaaaaaa1111"
        private var _diff: CommandResult = FakeCommandRunner.ok("")
        private var _fetch: CommandResult = FakeCommandRunner.ok()

        init(gitDir: URL) { self.gitDir = gitDir }

        var branch: String? {
            get { lock.lock(); defer { lock.unlock() }; return _branch }
            set { lock.lock(); _branch = newValue; lock.unlock() }
        }
        var commit: String {
            get { lock.lock(); defer { lock.unlock() }; return _commit }
            set { lock.lock(); _commit = newValue; lock.unlock() }
        }
        var diff: CommandResult {
            get { lock.lock(); defer { lock.unlock() }; return _diff }
            set { lock.lock(); _diff = newValue; lock.unlock() }
        }
        var fetch: CommandResult {
            get { lock.lock(); defer { lock.unlock() }; return _fetch }
            set { lock.lock(); _fetch = newValue; lock.unlock() }
        }

        func runner(root: String) -> FakeCommandRunner {
            FakeCommandRunner { call in
                let command = call.command
                if command.contains("--show-toplevel") { return FakeCommandRunner.ok(root + "\n") }
                if command.contains("--absolute-git-dir") {
                    return FakeCommandRunner.ok("\(self.gitDir.path)\n\(self.commit)\n")
                }
                if command.contains("symbolic-ref") {
                    return self.branch.map { FakeCommandRunner.ok($0 + "\n") } ?? FakeCommandRunner.failed(1)
                }
                if command.contains("diff --name-only") { return self.diff }
                if command.contains(" fetch ") { return self.fetch }
                if command.contains("rev-list") { return FakeCommandRunner.ok("3\n") }
                return FakeCommandRunner.failed(128)
            }
        }
    }

    /// A watcher of one repo that the monorepo's supabase and booking portal share.
    private func branchWatcher(clock: RunnerClock = .live) async throws -> (GitBranchWatcher, FakeGit, FakeCommandRunner) {
        let gitDir = root.appendingPathComponent("mono/.git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        let git = FakeGit(gitDir: gitDir)
        let shell = git.runner(root: root.appendingPathComponent("mono").path)
        let roots = await GitBranchWatcher.resolveRoots(
            repos: ["supabase": root.appendingPathComponent("mono").path,
                    "travel-portal": root.appendingPathComponent("mono/apps/booking-portal").path],
            shell: shell
        )
        return (GitBranchWatcher(roots: roots, shell: shell, clock: clock), git, shell)
    }

    func testServicesInOneRepositoryShareOneRootAndBranch() async throws {
        let (watcher, _, _) = try await branchWatcher()
        XCTAssertEqual(Set(watcher.repoRoots.values).count, 1)
        _ = await watcher.check()
        let branches = await watcher.branches
        XCTAssertEqual(branches["supabase"], "dev")
        XCTAssertEqual(branches["travel-portal"], "dev")
    }

    /// One poll that sees a new branch reports nothing; the next one that agrees
    /// reports it once, for every service of the repo, with the files that changed.
    func testAChangeCountsOnlyWhenTwoPollsAgree() async throws {
        let (watcher, git, _) = try await branchWatcher()
        _ = await watcher.check()

        git.branch = "feature"
        git.commit = "bbbbbbbb2222"
        git.diff = FakeCommandRunner.ok("apps/booking-portal/src/page.tsx\n")
        let first = await watcher.check()
        XCTAssertEqual(first, [])
        let second = await watcher.check()
        XCTAssertEqual(second, [GitBranchWatcher.Change(
            serviceIDs: ["supabase", "travel-portal"], branch: "feature",
            changedFiles: ["apps/booking-portal/src/page.tsx"]
        )])
        let third = await watcher.check()
        XCTAssertEqual(third, [], "a change is reported once")

        // A branch that one poll saw and the next did not is no change.
        git.branch = "other"
        _ = await watcher.check()
        git.branch = "feature"
        let back = await watcher.check()
        XCTAssertEqual(back, [])
    }

    /// A rebase, merge, cherry-pick, revert or bisect moves HEAD step by step, and
    /// a detached HEAD is no branch: none of them is a change. The display still
    /// follows HEAD.
    func testNoChangeDuringAGitOperationOrOnADetachedHead() async throws {
        let (watcher, git, _) = try await branchWatcher()
        _ = await watcher.check()

        for marker in GitBranchWatcher.busyMarkers {
            let path = git.gitDir.appendingPathComponent(marker)
            FileManager.default.createFile(atPath: path.path, contents: nil)
            git.branch = "rebase-step-\(marker)"
            let during = [await watcher.check(), await watcher.check()]
            XCTAssertEqual(during, [[], []], marker)
            try FileManager.default.removeItem(at: path)
            git.branch = "dev"
            let after = await watcher.check()
            XCTAssertEqual(after, [], marker)
        }

        git.branch = nil
        git.commit = "cccccccc3333"
        let detached = [await watcher.check(), await watcher.check()]
        XCTAssertEqual(detached, [[], []])
        let shown = await watcher.branches
        XCTAssertEqual(shown["travel-portal"], "cccccccc")

        // Control: the same switch with no marker and on a branch is a change.
        git.branch = "feature"
        _ = await watcher.check()
        let change = await watcher.check()
        XCTAssertEqual(change.map(\.branch), ["feature"])
    }

    /// Only packages, a lockfile, the Next config or an env file restart a dev
    /// server. A diff that git cannot give restarts, to be safe.
    func testOnlyPackageConfigAndEnvChangesNeedARestart() {
        for path in ["package.json", "apps/booking-portal/package.json", "pnpm-lock.yaml", "package-lock.json",
                     "apps/partner-portal/next.config.ts", "next.config.mjs", "apps/booking-portal/.env",
                     ".env.example", "pnpm-workspace.yaml"] {
            XCTAssertTrue(GitBranchWatcher.needsRestart(path), path)
        }
        for path in ["apps/booking-portal/src/app/page.tsx", "packages/travel-data/src/index.ts", "README.md",
                     "supabase/migrations/20261101_a.sql", "environment.ts"] {
            XCTAssertFalse(GitBranchWatcher.needsRestart(path), path)
        }
        func change(_ files: [String]?) -> GitBranchWatcher.Change {
            GitBranchWatcher.Change(serviceIDs: ["travel-portal"], branch: "x", changedFiles: files)
        }
        XCTAssertFalse(change(["src/a.ts", "README.md"]).needsRestart)
        XCTAssertTrue(change(["src/a.ts", "pnpm-lock.yaml"]).needsRestart)
        XCTAssertTrue(change(nil).needsRestart)
        XCTAssertFalse(change([]).needsRestart)
    }

    /// The fetch has a 20 s limit and never prompts. A failure leaves the tooltip
    /// with its time, and the next fetch waits longer; a success clears both.
    func testAFetchIsBoundedAndBacksOffAfterAFailure() async throws {
        let time = FakeClock()
        let (watcher, git, shell) = try await branchWatcher(clock: time.manual)
        func fetches() -> [FakeCommandRunner.Call] { shell.calls.filter { $0.command.contains(" fetch ") } }

        git.fetch = FakeCommandRunner.timedOut
        await watcher.fetchAndCount(fetchInterval: 0)
        XCTAssertEqual(fetches().count, 1)
        XCTAssertEqual(fetches().first?.timeout, .seconds(20))
        XCTAssertEqual(fetches().first?.environment["GIT_TERMINAL_PROMPT"], "0")
        let failures = await watcher.fetchFailures
        XCTAssertEqual(failures["travel-portal"], GitBranchWatcher.fetchFailedText(at: time.now))
        let behind = await watcher.behindCounts
        XCTAssertEqual(behind["travel-portal"], 3, "the count still comes from the last fetch")

        // A forced fetch right after the failure waits for its backoff.
        await watcher.fetchAndCount(fetchInterval: 0)
        XCTAssertEqual(fetches().count, 1)
        time.advance(by: .seconds(121))
        git.fetch = FakeCommandRunner.ok()
        await watcher.fetchAndCount(fetchInterval: 0)
        XCTAssertEqual(fetches().count, 2)
        let cleared = await watcher.fetchFailures
        XCTAssertEqual(cleared, [:])

        XCTAssertEqual(
            GitBranchWatcher.fetchFailedText(
                at: Date(timeIntervalSince1970: 1_800_021_720),  // 14:02 UTC
                timeZone: TimeZone(identifier: "UTC")!
            ),
            "fetch failed 14:02 (remote not reachable)"
        )
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    private func touch(_ url: URL, at date: Date) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func write(_ text: String, to url: URL, at date: Date) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
