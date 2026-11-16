import Foundation
import XCTest
@testable import TravelRunner

final class ToolPathTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tool-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(path), withIntermediateDirectories: true
        )
    }

    private func makeNode(_ version: String) throws -> String {
        let bin = ".nvm/versions/node/\(version)/bin"
        try makeDirectory(bin)
        let node = home.appendingPathComponent("\(bin)/node")
        try "#!/bin/sh\n".write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        return home.appendingPathComponent(bin).path
    }

    func testOnlyTheStaticDirectoriesThatExistAreAdded() throws {
        try makeDirectory("Library/pnpm")
        try makeDirectory(".volta/bin")

        let directories = ToolPath.directories(cwd: nil, home: home.path)

        XCTAssertTrue(directories.contains("\(home.path)/Library/pnpm"))
        XCTAssertTrue(directories.contains("\(home.path)/.volta/bin"))
        XCTAssertFalse(directories.contains("\(home.path)/.asdf/shims"))
        XCTAssertFalse(directories.contains("\(home.path)/.local/bin"))
    }

    func testTheNodeOfTheNvmrcIsAdded() throws {
        // A major that no real install has, so the Node versions of this Mac do not count.
        let wanted = try makeNode("v98.2.0")
        let newer = try makeNode("v99.0.0")
        let checkout = home.appendingPathComponent("repo")
        try makeDirectory("repo/apps/portal")
        try "v98\n".write(to: checkout.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)

        let cwd = checkout.appendingPathComponent("apps/portal").path
        XCTAssertEqual(ToolPath.nodeMajor(forCwd: cwd), 98)
        let directories = ToolPath.directories(cwd: cwd, home: home.path)

        XCTAssertEqual(directories.last, wanted)
        XCTAssertFalse(directories.contains(newer))
    }

    func testNoNvmrcGivesNoMajor() throws {
        XCTAssertNil(ToolPath.nodeMajor(forCwd: nil))
        try "lts/iron\n".write(to: home.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        XCTAssertNil(ToolPath.nodeMajor(forCwd: home.path))
    }

    func testWrapAddsTheDirectoriesAfterThePathOfTheShell() {
        XCTAssertEqual(ToolPath.wrap("pnpm dev", directories: []), "pnpm dev")
        XCTAssertEqual(
            ToolPath.wrap("pnpm dev", directories: ["/opt/homebrew/bin", "/Users/a b/Library/pnpm"]),
            "export PATH=\"$PATH\":/opt/homebrew/bin:'/Users/a b/Library/pnpm'; pnpm dev"
        )
    }

    /// The preflight of a start ran `node --version` in a bare login shell, so a Node
    /// from `~/.zshrc` failed the start before any service ran.
    func testAPreflightCommandFindsAToolInAnInjectedDirectory() async throws {
        // A name that no Mac has, so the tools of this machine do not count.
        let tool = "tr-fake-node-\(UUID().uuidString)"
        try makeDirectory("tools")
        let file = home.appendingPathComponent("tools/\(tool)")
        try "#!/bin/sh\necho v98.1.0\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let tools = home.appendingPathComponent("tools").path

        let found = await PreflightRunner(toolDirectories: { _ in [tools] }).shellOutput("\(tool) --version")
        XCTAssertEqual(found.trimmingCharacters(in: .whitespacesAndNewlines), "v98.1.0")

        // Negative control: without the directory the shell does not find it.
        let missing = await PreflightRunner(toolDirectories: { _ in [] }).shellOutput("\(tool) --version")
        XCTAssertEqual(missing.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    /// The Node check of the preflight asks in the cwd of a portal, so it gets the
    /// Node that the services get.
    func testTheNodeCheckOfThePreflightCarriesTheCwdOfThePortal() {
        func service(_ id: String, cwd: String) -> ServiceDefinition {
            ServiceDefinition(
                id: id, name: id, cmd: ["true"], cwd: cwd, probe: nil, type: .daemon, restart: .never,
                dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
            )
        }
        let services = [service("supabase", cwd: "/mono"), service("travel-portal", cwd: "/mono/apps/booking-portal")]

        let checks = PreflightRunner().allChecks(for: services)

        XCTAssertEqual(checks.first { $0.id == "node-version" }?.metadata["cwd"], "/mono/apps/booking-portal")
    }

    func testOnlyABareCommandNameIsATool() {
        XCTAssertEqual(ToolPath.toolName(of: ["pnpm", "dev"]), "pnpm")
        XCTAssertNil(ToolPath.toolName(of: ["./scripts/dev.sh"]))
        XCTAssertNil(ToolPath.toolName(of: ["/bin/sh", "-c", "true"]))
        XCTAssertNil(ToolPath.toolName(of: []))
    }

    func testTheNotFoundText() {
        XCTAssertEqual(
            ToolPath.notFoundText(tool: "node", searchedPath: "/usr/bin:/bin", appName: "Travel Runner"),
            "node was not found. Travel Runner looked in: /usr/bin:/bin. Install node or add its folder to ~/.zprofile, then restart the service."
        )
        // The hackathon app says its own name.
        XCTAssertTrue(
            ToolPath.notFoundText(tool: "node", searchedPath: "/bin", appName: Flavor.hackathon.displayName)
                .contains("\(Flavor.hackathon.displayName) looked in: /bin.")
        )
    }
}
