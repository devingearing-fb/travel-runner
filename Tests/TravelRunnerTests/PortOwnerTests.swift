import Foundation
import XCTest
@testable import TravelRunner

final class PortOwnerTests: XCTestCase {
    func testParseReadsEachProcessOnce() {
        let output = "p4242\ncnode\nf21\nf22\np57752\ncOrbStack\\x20Helper\nf139\n"
        XCTAssertEqual(PortOwner.parse(output), [
            PortOwner.Listener(pid: 4242, command: "node"),
            PortOwner.Listener(pid: 57752, command: "OrbStack Helper"),
        ])
    }

    func testParseOfNoOutputIsEmpty() {
        XCTAssertEqual(PortOwner.parse(""), [])
        XCTAssertEqual(PortOwner.parse("lsof: no such thing\n"), [])
    }

    func testAskForTheListenersOfOnePortWithFullNames() {
        XCTAssertEqual(PortOwner.lsofArguments(port: 7376), ["+c", "0", "-nP", "-iTCP:7376", "-sTCP:LISTEN", "-Fpc"])
    }

    func testContainerRuntimesAreRecognised() {
        for command in [
            "OrbStack", "OrbStack Helper", "com.docker.backend", "com.docker.vpnkit", "vpnkit-bridge",
            "limactl", "colima",
            // Names that lsof or the kernel cut short.
            "com.docker.backe", "com.docke",
        ] {
            XCTAssertTrue(PortOwner.isContainerRuntime(command), command)
        }
    }

    func testOtherListenersAreNotContainerRuntimes() {
        for command in ["node", "python3.12", "stripe", "next-server", "com", "c", "", "Docker Desktop Helper"] {
            XCTAssertFalse(PortOwner.isContainerRuntime(command), command)
        }
    }

    /// The Stripe kill uses the command of the catalog, so it follows a change of that command.
    func testCommandPatternIsTheCatalogCommand() throws {
        let services = ServiceCatalog.services(
            paths: RepoPaths(monorepo: "/work/mono", universalLogin: "/work/login", streamServices: nil, loadTest: nil),
            flavor: .standard
        )
        let stripe = try XCTUnwrap(services.first { $0.id == "stripe" })
        let pattern = PortOwner.commandPattern(for: stripe.cmd)

        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ line: String) -> Bool {
            regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        XCTAssertTrue(matches(stripe.cmd.joined(separator: " ")))
        XCTAssertTrue(matches("/bin/zsh -l -c " + stripe.cmd.joined(separator: " ")))
        XCTAssertFalse(matches("stripe listen"))
        XCTAssertFalse(matches("stripe listen --forward-to http://localhost:4000/hooks"))
    }

    func testCommandPatternMakesRegexCharactersLiteral() {
        XCTAssertEqual(PortOwner.commandPattern(for: ["a.b", "(c)*", "d|e"]), "a\\.b \\(c\\)\\* d\\|e")
    }
}
