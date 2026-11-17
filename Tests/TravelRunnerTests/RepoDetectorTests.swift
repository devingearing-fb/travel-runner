import Foundation
import XCTest
@testable import TravelRunner

final class RepoDetectorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("travel-runner-repos-\(UUID().uuidString)")
            .appendingPathComponent("Codebases")
        let travel = root.appendingPathComponent("TRAVEL BOOKING")
        try makeMonorepo(at: travel.appendingPathComponent("fb-travel-monolith"))
        try writePackage(name: "@fastbreak-amateur/travel-load-test", at: travel.appendingPathComponent("travel-load-test"))
        try writePackage(name: "fb-amateur-booking-portal", at: travel.appendingPathComponent("travel-booking-portal"))
        try writePackage(name: "fb-amateur-accounting-webhooks", at: root.appendingPathComponent("fb-amateur-universal-login"))
        try writePackage(name: "fb-amateur-stream-services", at: root.appendingPathComponent("stream-services"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func testScanFindsMonorepoAndExternalRepos() {
        let detected = RepoDetector.scan(directory: root.path)

        XCTAssertEqual(detected.monorepo, root.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith").path)
        XCTAssertEqual(detected.universalLogin, root.appendingPathComponent("fb-amateur-universal-login").path)
        XCTAssertEqual(detected.streamServices, root.appendingPathComponent("stream-services").path)
        XCTAssertEqual(detected.loadTest, root.appendingPathComponent("TRAVEL BOOKING/travel-load-test").path)
        XCTAssertTrue(detected.allDetected)
    }

    func testDroppingTheMonorepoItselfDetectsIt() {
        let monorepo = root.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith").path
        XCTAssertEqual(RepoDetector.scan(directory: monorepo).monorepo, monorepo)
    }

    func testFindMonorepoNearOldSiblingRepo() {
        let oldPortal = root.appendingPathComponent("TRAVEL BOOKING/travel-booking-portal").path
        XCTAssertEqual(
            RepoDetector.findMonorepo(near: oldPortal),
            root.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith").path
        )
        XCTAssertNil(RepoDetector.findMonorepo(near: FileManager.default.temporaryDirectory.appendingPathComponent("nowhere").path))
    }

    func testMonorepoNeedsAllThreeMarkers() throws {
        let partial = root.appendingPathComponent("partial")
        try writePackage(name: "x", at: partial.appendingPathComponent("apps/booking-portal"))
        try Data().write(to: partial.appendingPathComponent("pnpm-workspace.yaml"))
        XCTAssertFalse(RepoDetector.isMonorepo(partial.path))
    }

    func testStreamServicesValidationRequiresPackageManifest() throws {
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertFalse(RepoDetector.validate(path: empty.path, role: .streamServices))
        XCTAssertTrue(RepoDetector.validate(path: root.appendingPathComponent("stream-services").path, role: .streamServices))
    }

    // MARK: - Universal login

    func testALoginCloneWithAnotherFolderNameIsFoundByItsOriginRemote() throws {
        let other = root.deletingLastPathComponent().appendingPathComponent("Other")
        let clone = other.appendingPathComponent("login")
        try writePackage(name: "fb-amateur-accounting-webhooks", at: clone)
        try writeGitConfig(origin: "git@github.com:fastbreak-amateur/fb-amateur-universal-login.git", at: clone)
        let unrelated = other.appendingPathComponent("tool")
        try writePackage(name: "tool", at: unrelated)
        try writeGitConfig(origin: "git@github.com:someone/tool.git", at: unrelated)

        XCTAssertEqual(RepoDetector.scan(directory: other.path).universalLogin, clone.path)
        XCTAssertEqual(RepoDetector.originURL(of: clone.path), "git@github.com:fastbreak-amateur/fb-amateur-universal-login.git")
    }

    func testTheLoginPathMustBeARepo() throws {
        let empty = root.appendingPathComponent("empty-login")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertFalse(RepoDetector.validate(path: empty.path, role: .universalLogin))
        XCTAssertFalse(RepoDetector.validate(path: root.appendingPathComponent("missing").path, role: .universalLogin))
        XCTAssertTrue(RepoDetector.validate(path: root.appendingPathComponent("fb-amateur-universal-login").path, role: .universalLogin))
    }

    // MARK: - Worktrees

    /// The main worktree wins over a linked one, also when the linked one comes first by name.
    func testTheMainWorktreeWinsAndEveryCheckoutIsListed() throws {
        let travel = root.appendingPathComponent("TRAVEL BOOKING")
        let main = travel.appendingPathComponent("fb-travel-monolith")
        try makeMainWorktree(at: main, branch: "dev")
        let linked = travel.appendingPathComponent("a-feature-worktree")
        try makeMonorepo(at: linked)
        try makeLinkedWorktree(at: linked, of: main, name: "a-feature-worktree", branch: "fix/thing")

        let detected = RepoDetector.scan(directory: root.path)

        XCTAssertEqual(detected.monorepo, main.path)
        XCTAssertEqual(detected.monorepoCheckouts, [
            MonorepoCheckout(path: main.path, isMainWorktree: true, branch: "dev"),
            MonorepoCheckout(path: linked.path, isMainWorktree: false, branch: "fix/thing"),
        ])
        XCTAssertEqual(detected.monorepoCheckouts.map(\.label), ["main checkout · dev", "worktree · fix/thing"])
    }

    /// Without git metadata (a copy, a download) the order is the path order, as before.
    func testCheckoutsWithoutGitAreOrderedByPath() throws {
        let travel = root.appendingPathComponent("TRAVEL BOOKING")
        try makeMonorepo(at: travel.appendingPathComponent("a-copy"))

        let detected = RepoDetector.scan(directory: root.path)

        XCTAssertEqual(detected.monorepoCheckouts.map(\.path), [
            travel.appendingPathComponent("a-copy").path,
            travel.appendingPathComponent("fb-travel-monolith").path,
        ])
        XCTAssertEqual(detected.monorepo, travel.appendingPathComponent("a-copy").path)
    }

    /// A dropped worktree adds its main worktree, as `git worktree list` names it.
    func testDroppingALinkedWorktreeOffersItsMainWorktreeFirst() throws {
        let main = root.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith")
        try makeMainWorktree(at: main, branch: "dev")
        let elsewhere = root.deletingLastPathComponent().appendingPathComponent("worktrees")
        let linked = elsewhere.appendingPathComponent("fb-travel-monolith-wip")
        try makeMonorepo(at: linked)
        try makeLinkedWorktree(at: linked, of: main, name: "wip", branch: "wip")

        let detected = RepoDetector.scan(directory: elsewhere.path)

        XCTAssertEqual(RepoDetector.mainWorktree(of: linked.path), main.path)
        XCTAssertNil(RepoDetector.mainWorktree(of: main.path))
        XCTAssertEqual(detected.monorepoCheckouts.map(\.path), [main.path, linked.path])
        XCTAssertEqual(detected.monorepo, main.path)
    }

    func testFindMonorepoPrefersTheMainWorktree() throws {
        let travel = root.appendingPathComponent("TRAVEL BOOKING")
        let main = travel.appendingPathComponent("fb-travel-monolith")
        try makeMainWorktree(at: main, branch: "dev")
        let linked = travel.appendingPathComponent("a-feature-worktree")
        try makeMonorepo(at: linked)
        try makeLinkedWorktree(at: linked, of: main, name: "a-feature-worktree", branch: "fix/thing")

        XCTAssertEqual(RepoDetector.findMonorepo(near: travel.appendingPathComponent("travel-booking-portal").path), main.path)
    }

    // MARK: - Hackathon mismatch

    func testTheNormalMonorepoInTheHackathonAppSaysWhichAppToInstall() throws {
        let monolith = root.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith").path

        XCTAssertEqual(
            RepoDetector.flavorMismatch(path: monolith, flavor: .hackathon),
            "This is the normal fb-travel-monolith. Travel Runner Hackathon needs the hackathon fork (apps/amateur-agent). "
                + "For this repo, install Travel Runner."
        )
        XCTAssertNil(RepoDetector.flavorMismatch(path: monolith, flavor: .standard))
        XCTAssertNil(RepoDetector.flavorMismatch(path: root.path, flavor: .hackathon))
        XCTAssertEqual(RepoDetector.scan(directory: root.path, flavor: .hackathon).otherFlavorMonorepo, monolith)
        XCTAssertNil(RepoDetector.scan(directory: root.path, flavor: .hackathon).monorepo)
    }

    // MARK: - Helpers

    private func makeMainWorktree(at directory: URL, branch: String) throws {
        let git = directory.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("ref: refs/heads/\(branch)\n".utf8).write(to: git.appendingPathComponent("HEAD"))
    }

    /// A linked worktree as `git worktree add` makes it: a `.git` file that names
    /// `.git/worktrees/<name>`, whose `commondir` leads back to the main `.git`.
    private func makeLinkedWorktree(at directory: URL, of main: URL, name: String, branch: String) throws {
        let gitDir = main.appendingPathComponent(".git/worktrees/\(name)")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("ref: refs/heads/\(branch)\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))
        try Data("../..\n".utf8).write(to: gitDir.appendingPathComponent("commondir"))
        try Data("gitdir: \(gitDir.path)\n".utf8).write(to: directory.appendingPathComponent(".git"))
    }

    private func writeGitConfig(origin: String, at directory: URL) throws {
        let git = directory.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        let config = """
        [core]
        \tbare = false
        [remote "upstream"]
        \turl = git@github.com:other/fb-amateur-universal-login.git
        [remote "origin"]
        \turl = \(origin)
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """
        try Data(config.utf8).write(to: git.appendingPathComponent("config"))
    }

    private func makeMonorepo(at directory: URL) throws {
        try writePackage(name: "fb-travel-monolith", at: directory)
        try writePackage(name: "booking-portal", at: directory.appendingPathComponent("apps/booking-portal"))
        try Data().write(to: directory.appendingPathComponent("pnpm-workspace.yaml"))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("supabase"), withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("supabase/config.toml"))
    }

    private func writePackage(name: String, at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["name": name])
        try data.write(to: directory.appendingPathComponent("package.json"))
    }
}
