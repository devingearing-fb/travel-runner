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

    func testServicesInOneRepositoryShareOneRootAndBranch() async throws {
        let repo = root.appendingPathComponent("mono")
        let app = repo.appendingPathComponent("apps/booking-portal")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "dev", repo.path])
        try git(["-C", repo.path, "commit", "-q", "--allow-empty", "-m", "init"])

        let watcher = GitBranchWatcher(repos: ["supabase": repo.path, "travel-portal": app.path])
        XCTAssertEqual(Set(watcher.repoRoots.values).count, 1)
        _ = await watcher.check()
        let branches = await watcher.branches
        XCTAssertEqual(branches["supabase"], "dev")
        XCTAssertEqual(branches["travel-portal"], "dev")

        try git(["-C", repo.path, "checkout", "-q", "-b", "feature"])
        let changed = await watcher.check()
        XCTAssertEqual(changed, ["supabase", "travel-portal"])
    }

    func testBranchIsReadInsideAWorktree() async throws {
        let repo = root.appendingPathComponent("mono")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(["init", "-q", "-b", "dev", repo.path])
        try git(["-C", repo.path, "commit", "-q", "--allow-empty", "-m", "init"])
        let worktree = root.appendingPathComponent("mono-wt")
        try git(["-C", repo.path, "worktree", "add", "-q", "-b", "wt-branch", worktree.path])

        let watcher = GitBranchWatcher(repos: ["travel-portal": worktree.path])
        _ = await watcher.check()
        let branches = await watcher.branches
        XCTAssertEqual(branches["travel-portal"], "wt-branch")
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

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "test@example.com",
            "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "test@example.com",
        ]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, arguments.joined(separator: " "))
    }
}
