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

    /// The quit of the app killed each listener on its ports, also the port helper
    /// of the container runtime.
    func testTheQuitSweepLeavesAContainerRuntimeAlive() {
        let listeners = [
            PortOwner.Listener(pid: 10, command: "node"),
            PortOwner.Listener(pid: 11, command: "OrbStack Helper"),
            PortOwner.Listener(pid: 12, command: "com.docker.backend"),
        ]

        XCTAssertEqual(PortOwner.killable(listeners), [PortOwner.Listener(pid: 10, command: "node")])
    }

    /// The reader of the quit gives what the reader of the start gives.
    func testTheReaderOfTheQuitFindsAListener() async throws {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(sock, 8), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))

        let now = PortOwner.listenersNow(on: port)

        XCTAssertEqual(now.map(\.pid), [getpid()])
        let viaAsync = await PortOwner.listeners(on: port)
        XCTAssertEqual(now, viaAsync)
    }

    func testCommandPatternMakesRegexCharactersLiteral() {
        XCTAssertEqual(PortOwner.commandPattern(for: ["a.b", "(c)*", "d|e"]), "a\\.b \\(c\\)\\* d\\|e")
    }
}
