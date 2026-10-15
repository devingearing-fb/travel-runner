import Foundation
import XCTest
@testable import TravelRunner

final class ShellQuoteTests: XCTestCase {
    func testPlainArgumentsStayUnquoted() {
        XCTAssertEqual(ShellQuote.join(["pnpm", "dev", "--", "-p", "3006"]), "pnpm dev -- -p 3006")
        XCTAssertEqual(ShellQuote.quote("--env-file=../x/.env.local"), "--env-file=../x/.env.local")
    }

    func testPathWithSpaceStaysOneArgument() throws {
        let path = "/tmp/TRAVEL BOOKING/apps/booking-portal/.env.local"
        let output = try runZsh(ShellQuote.join(["printf", "%s\\n", "--env-file=\(path)"]))
        XCTAssertEqual(output, "--env-file=\(path)\n")
    }

    func testShellMetacharactersAreLiteral() throws {
        let tricky = "it's $HOME && `id` ; *"
        let output = try runZsh(ShellQuote.join(["printf", "%s", tricky]))
        XCTAssertEqual(output, tricky)
    }

    func testEmptyArgumentIsKept() {
        XCTAssertEqual(ShellQuote.join(["a", "", "b"]), "a '' b")
    }

    func testLanCommandKeepsPackageManagerAndPort() {
        XCTAssertEqual(
            EnvironmentSupervisor.lanCommand(["pnpm", "dev"], ip: "10.0.0.5"),
            ["pnpm", "dev", "--hostname", "10.0.0.5"]
        )
        XCTAssertEqual(
            EnvironmentSupervisor.lanCommand(["npm", "run", "dev"], ip: "10.0.0.5"),
            ["npm", "run", "dev", "--", "--hostname", "10.0.0.5"]
        )
        XCTAssertEqual(
            EnvironmentSupervisor.lanCommand(["npm", "run", "dev", "--", "-p", "3006"], ip: "10.0.0.5"),
            ["npm", "run", "dev", "--", "-p", "3006", "--hostname", "10.0.0.5"]
        )
    }

    private func runZsh(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }
}
