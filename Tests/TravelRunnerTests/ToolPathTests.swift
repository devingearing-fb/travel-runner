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

    func testOnlyABareCommandNameIsATool() {
        XCTAssertEqual(ToolPath.toolName(of: ["pnpm", "dev"]), "pnpm")
        XCTAssertNil(ToolPath.toolName(of: ["./scripts/dev.sh"]))
        XCTAssertNil(ToolPath.toolName(of: ["/bin/sh", "-c", "true"]))
        XCTAssertNil(ToolPath.toolName(of: []))
    }

    func testTheNotFoundText() {
        XCTAssertEqual(
            ToolPath.notFoundText(tool: "node", searchedPath: "/usr/bin:/bin"),
            "node was not found. Travel Runner looked in: /usr/bin:/bin."
        )
    }
}
