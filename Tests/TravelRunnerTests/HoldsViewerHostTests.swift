import Foundation
import XCTest
@testable import TravelRunner

/// The host of the Rooms tab, with a small stand-in for the monolith's viewer.
@MainActor
final class HoldsViewerHostTests: XCTestCase {
    private var root: URL!
    private var repo: URL!
    private var cache: URL!
    private var defaults: UserDefaults!
    private var hosts: [HoldsViewerHost] = []

    /// Answers /api/envs with its own arguments, as the real viewer answers with its environments.
    private static let stubServer = """
    import http from "node:http";
    const args = process.argv.slice(2);
    const port = Number(args[args.indexOf("--port") + 1]);
    http.createServer((req, res) => {
      res.writeHead(req.url.startsWith("/api/envs") ? 200 : 404, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ envs: ["local", "dev"], args, marker: MARKER }));
    }).listen(port, "127.0.0.1");
    """

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("HoldsViewerHostTests-\(UUID().uuidString)")
        repo = root.appendingPathComponent("TRAVEL BOOKING/fb-travel-monolith")
        cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defaults = try XCTUnwrap(UserDefaults(suiteName: "HoldsViewerHostTests-\(UUID().uuidString)"))
        hosts = []
    }

    override func tearDown() async throws {
        for host in hosts { await host.stop() }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private func makeHost(nodeCommand: String = "node", idleSeconds: Double = 600) -> HoldsViewerHost {
        let host = HoldsViewerHost(nodeCommand: nodeCommand, cacheRoot: cache.path, defaults: defaults, idleSeconds: idleSeconds)
        let path = repo.path
        host.monorepo = { path }
        hosts.append(host)
        return host
    }

    @discardableResult
    private func writeViewer(in folder: URL, marker: String, script: String? = nil) throws -> URL {
        let directory = folder.appendingPathComponent(HoldsViewerLocator.relativePath)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = (script ?? Self.stubServer).replacingOccurrences(of: "MARKER", with: "\"\(marker)\"")
        try text.write(to: directory.appendingPathComponent("server.mjs"), atomically: true, encoding: .utf8)
        return directory
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repo.path, "-c", "user.email=test@example.com", "-c", "user.name=Test", "-c", "commit.gpgsign=false"] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Makes `origin/dev` a commit that has the viewer, and takes the viewer out of the checkout.
    private func putViewerOnOriginDevOnly(marker: String) throws {
        try git("init", "--quiet")
        try writeViewer(in: repo, marker: marker)
        try git("add", "-A")
        try git("commit", "--quiet", "-m", "viewer")
        try git("update-ref", "refs/remotes/origin/dev", "HEAD")
        try git("rm", "--quiet", "-r", "scripts")
        try git("commit", "--quiet", "-m", "an old branch with no viewer")
    }

    private func envs(port: Int) async throws -> (args: [String], marker: String) {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/api/envs")!)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (json["args"] as? [String] ?? [], json["marker"] as? String ?? "")
    }

    private func port(of host: HoldsViewerHost, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        guard case .running(let port) = host.state else {
            XCTFail("the viewer is \(host.state)", file: file, line: line)
            throw CancellationError()
        }
        return port
    }

    private func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: - Which copy

    func testTheCheckoutCopyRunsWithTheArgumentsOfTheTab() async throws {
        try writeViewer(in: repo, marker: "checkout")
        let host = makeHost()

        await host.ensureRunning()

        let port = try port(of: host)
        XCTAssertEqual(host.copy?.origin, .workingTree)
        let answer = try await envs(port: port)
        XCTAssertEqual(answer.marker, "checkout")
        XCTAssertEqual(answer.args, ["--envs", "local,dev", "--port", String(port), "--no-open", "--main-checkout", repo.path])
    }

    func testABranchWithoutTheViewerRunsTheCopyOfOriginDev() async throws {
        try putViewerOnOriginDevOnly(marker: "origin-dev")
        let host = makeHost()

        await host.ensureRunning()

        let port = try port(of: host)
        guard case .originDev(let tree) = host.copy?.origin else { return XCTFail("copy is \(String(describing: host.copy))") }
        XCTAssertEqual(tree, try git("rev-parse", "origin/dev:scripts/holds-viewer"))
        XCTAssertTrue(host.copy!.directory.hasPrefix(cache.path))
        let answer = try await envs(port: port)
        XCTAssertEqual(answer.marker, "origin-dev")
        // The checkout for the env files stays the working tree, not the cache.
        XCTAssertEqual(answer.args.last, repo.path)
    }

    func testTheExtractIsReusedUntilTheViewerChanges() throws {
        try putViewerOnOriginDevOnly(marker: "first")
        let first = try XCTUnwrap(HoldsViewerLocator.locate(monorepo: repo.path, overridePath: nil, cacheRoot: cache.path))
        let stamp = cache.appendingPathComponent("stamp")
        try "x".write(to: URL(fileURLWithPath: first.directory).appendingPathComponent("stamp"), atomically: true, encoding: .utf8)

        let again = try XCTUnwrap(HoldsViewerLocator.locate(monorepo: repo.path, overridePath: nil, cacheRoot: cache.path))
        XCTAssertEqual(again, first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (first.directory as NSString).appendingPathComponent("stamp")), "no second extract")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stamp.path))
    }

    func testTheOverrideFolderComesFirstAndTheCheckoutComesBeforeOriginDev() throws {
        try putViewerOnOriginDevOnly(marker: "origin-dev")
        XCTAssertNotEqual(HoldsViewerLocator.locate(monorepo: repo.path, overridePath: nil, cacheRoot: cache.path)?.origin, .workingTree)

        try writeViewer(in: repo, marker: "checkout")
        XCTAssertEqual(HoldsViewerLocator.locate(monorepo: repo.path, overridePath: nil, cacheRoot: cache.path)?.origin, .workingTree)

        let other = try writeViewer(in: root.appendingPathComponent("elsewhere"), marker: "override")
        let copy = HoldsViewerLocator.locate(monorepo: repo.path, overridePath: other.path, cacheRoot: cache.path)
        XCTAssertEqual(copy, HoldsViewerCopy(origin: .override, directory: other.path))

        // An override folder with no viewer is not used.
        XCTAssertEqual(HoldsViewerLocator.locate(monorepo: repo.path, overridePath: root.path, cacheRoot: cache.path)?.origin, .workingTree)
    }

    // MARK: - States the tab shows

    func testNoCopyAnywhereIsAStateOfItsOwn() async throws {
        try git("init", "--quiet")
        let host = makeHost()

        await host.ensureRunning()

        XCTAssertEqual(host.state, .unavailable(.noViewer))
        XCTAssertNil(host.pid)
    }

    func testNoMonolithIsAStateOfItsOwn() async {
        let host = makeHost()
        host.monorepo = { nil }
        await host.ensureRunning()
        XCTAssertEqual(host.state, .unavailable(.noMonorepo))
    }

    func testNodeThatIsNotFoundIsAStateOfItsOwn() async throws {
        try writeViewer(in: repo, marker: "checkout")
        let host = makeHost(nodeCommand: "no-such-node-\(UUID().uuidString)")

        await host.ensureRunning()
        let settled = await waitUntil(10) { host.state != .starting }

        XCTAssertTrue(settled)
        XCTAssertEqual(host.state, .unavailable(.nodeNotFound))
    }

    func testAViewerThatExitsShowsItsLastLine() async throws {
        try writeViewer(in: repo, marker: "x", script: "console.error('boom: no config'); process.exit(3);")
        let host = makeHost()

        await host.ensureRunning()
        let settled = await waitUntil(10) { host.state != .starting }

        XCTAssertTrue(settled)
        guard case .failed(let reason) = host.state else { return XCTFail("state is \(host.state)") }
        XCTAssertTrue(reason.contains("exited with code 3"), reason)
        XCTAssertTrue(reason.contains("boom: no config"), reason)
    }

    // MARK: - Lifecycle

    func testStopLeavesNoProcess() async throws {
        try writeViewer(in: repo, marker: "checkout")
        let host = makeHost()
        await host.ensureRunning()
        let port = try port(of: host)
        let pid = try XCTUnwrap(host.pid)

        await host.stop()

        XCTAssertEqual(host.state, .stopped)
        XCTAssertNil(host.pid)
        XCTAssertNotEqual(kill(pid, 0), 0, "the process is gone")
        do {
            _ = try await envs(port: port)
            XCTFail("the port must be closed")
        } catch {}
    }

    func testASecondCallKeepsTheRunningViewer() async throws {
        try writeViewer(in: repo, marker: "checkout")
        let host = makeHost()
        await host.ensureRunning()
        let pid = host.pid

        await host.ensureRunning()

        XCTAssertEqual(host.pid, pid)
    }

    func testAChangeOfTheCopyStartsTheNewOne() async throws {
        try writeViewer(in: repo, marker: "checkout")
        let host = makeHost()
        await host.ensureRunning()
        let oldPid = try XCTUnwrap(host.pid)

        let other = try writeViewer(in: root.appendingPathComponent("elsewhere"), marker: "override")
        defaults.set(other.path, forKey: HoldsViewerHost.overrideDefaultsKey)
        await host.ensureRunning()

        let port = try port(of: host)
        XCTAssertEqual(host.copy?.origin, .override)
        let answer = try await envs(port: port)
        XCTAssertEqual(answer.marker, "override")
        XCTAssertNotEqual(kill(oldPid, 0), 0, "the old viewer is gone")
    }

    func testTheViewerStopsAWhileAfterTheTabGoesAway() async throws {
        try writeViewer(in: repo, marker: "checkout")
        let host = makeHost(idleSeconds: 0.4)
        host.tabAppeared()
        let running = await waitUntil(15) { if case .running = host.state { true } else { false } }
        XCTAssertTrue(running, "state is \(host.state)")

        host.tabDisappeared()

        let stopped = await waitUntil(5) { host.state == .stopped }
        XCTAssertTrue(stopped)
    }

    func testNegativeControlATabThatComesBackKeepsTheViewer() async throws {
        try writeViewer(in: repo, marker: "checkout")
        let host = makeHost(idleSeconds: 0.4)
        host.tabAppeared()
        let running = await waitUntil(15) { if case .running = host.state { true } else { false } }
        XCTAssertTrue(running)
        let pid = host.pid

        host.tabDisappeared()
        host.tabAppeared()
        try await Task.sleep(for: .seconds(1.2))

        XCTAssertEqual(host.pid, pid)
        guard case .running = host.state else { return XCTFail("state is \(host.state)") }
    }

    // MARK: - The page address

    func testThePageStartsOnLocalAndComesBackToTheLastQuery() {
        let host = makeHost()
        XCTAssertEqual(host.pageURL(port: 5000).absoluteString, "http://127.0.0.1:5000/?env=local&view=rooms&embed=1")

        host.lastQuery = "env=dev&view=holds&event=7&hotel=50&embed=1"
        XCTAssertEqual(host.pageURL(port: 5000).absoluteString, "http://127.0.0.1:5000/?env=dev&view=holds&event=7&hotel=50&embed=1")
        XCTAssertEqual(host.browserURL(port: 5000).absoluteString, "http://127.0.0.1:5000/?env=dev&view=holds&event=7&hotel=50")
    }
}
