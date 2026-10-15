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
