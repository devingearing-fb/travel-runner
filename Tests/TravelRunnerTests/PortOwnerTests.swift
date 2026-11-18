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

    // MARK: - Ownership

    private let root = "/work/mono"

    /// Ledger: 100 started this session (its child is 101), 200 started in an
    /// earlier session. Each pid has a folder.
    private func knowledge(cwds: [pid_t: String] = [:]) -> PortOwner.Knowledge {
        let parents: [pid_t: pid_t] = [101: 100, 100: 1, 201: 200, 200: 1]
        return PortOwner.Knowledge(
            ledger: [
                LaunchLedger.Entry(serviceID: "travel-portal", pid: 100, startTime: 1, cwd: root, command: ["pnpm", "dev"]),
                LaunchLedger.Entry(serviceID: "partner-portal", pid: 200, startTime: 2, cwd: root, command: ["pnpm", "dev"]),
            ],
            sessionPIDs: [100],
            roots: [root],
            facts: { pid in ProcessFacts(pid: pid, startTime: 9, cwd: cwds[pid]) },
            ancestors: { ProcessTree.ancestors(of: $0, parents: parents) }
        )
    }

    func testEachOwnerOfAListener() {
        let known = knowledge(cwds: [
            300: "/work/mono/apps/booking-portal", 301: "/work/mono", 302: "/work/mono-other",
            303: "/Users/x/code/other-app", 305: "/work/mono",
        ])
        let rows: [(name: String, listener: PortOwner.Listener, owner: PortOwner.Owner)] = [
            ("a launch of this session", .init(pid: 100, command: "node"), .ownLaunch(serviceID: "travel-portal")),
            ("the child of a launch", .init(pid: 101, command: "node"), .ownLaunch(serviceID: "travel-portal")),
            ("a launch of the last session", .init(pid: 200, command: "node"), .ownLeftover(serviceID: "partner-portal")),
            ("the child of that one", .init(pid: 201, command: "node"), .ownLeftover(serviceID: "partner-portal")),
            ("a process in a folder of the repo", .init(pid: 300, command: "node"), .ownLeftover(serviceID: nil)),
            ("a process at the root of the repo", .init(pid: 301, command: "node"), .ownLeftover(serviceID: nil)),
            ("a folder whose name starts like the repo", .init(pid: 302, command: "node"), .foreign),
            ("a process of another app", .init(pid: 303, command: "node"), .foreign),
            ("a process whose folder is not known", .init(pid: 304, command: "node"), .foreign),
            ("a container runtime, also in the repo", .init(pid: 305, command: "OrbStack Helper"), .containerRuntime),
        ]
        for row in rows {
            XCTAssertEqual(PortOwner.owner(of: row.listener, known).owner, row.owner, row.name)
        }
        // Negative control: without the ledger and the roots, each of them is a stranger.
        let empty = PortOwner.Knowledge(facts: known.facts, ancestors: known.ancestors)
        for row in rows where row.owner != .containerRuntime {
            XCTAssertEqual(PortOwner.owner(of: row.listener, empty).owner, .foreign, row.name)
        }
    }

    /// "" and "/" would make every process an own one.
    func testTheRootsLeaveOutTheEmptyFolderAndTheTopFolder() {
        XCTAssertEqual(PortOwner.roots(["", "/", "/work/mono", "/work/mono"]), ["/work/mono"])
    }

    func testTheRefusalNamesTheProcessAndItsFolder() {
        let occupant = PortOwner.Occupant(
            listener: .init(pid: 4242, command: "node"), owner: .foreign,
            cwd: PortOwner.realPath(NSHomeDirectory()) + "/code/other-app"
        )
        XCTAssertEqual(
            PortOwner.foreignText(port: 3000, occupant: occupant, service: "Universal Login"),
            "Port 3000 is in use by node (PID 4242, ~/code/other-app), which Travel Runner did not start. Universal Login was not started."
        )
    }

    // MARK: - Another next dev

    func testNextDevIsRecognised() {
        let rows: [(arguments: [String], isNextDev: Bool)] = [
            (["node", "/repo/node_modules/.bin/../next/dist/bin/next", "dev"], true),
            (["node", "/repo/node_modules/.bin/next", "dev", "--turbopack", "-p", "3006"], true),
            (["next-server (v16.2.6)"], true),
            (["node", "/repo/node_modules/.bin/next", "build"], false),
            (["pnpm", "dev"], false),
            (["node", "/repo/server.js", "dev"], false),
            ([], false),
        ]
        for row in rows {
            XCTAssertEqual(PortOwner.isNextDev(row.arguments), row.isNextDev, "\(row.arguments)")
        }
    }

    /// Of a parent and its server only the parent counts, and a process of the
    /// runner does not count.
    func testOtherNextDevsLeaveOutChildrenAndTheRunnersOwn() {
        let folder = "/work/mono/apps/booking-portal"
        let parent = ProcessFacts(pid: 57752, startTime: 1, cwd: folder, arguments: ["node", "/x/next", "dev"])
        let child = ProcessFacts(pid: 57753, startTime: 1, cwd: folder, arguments: ["next-server (v16.2.6)"])
        let own = ProcessFacts(pid: 100, startTime: 1, cwd: folder, arguments: ["next-server (v16.2.6)"])
        let pnpm = ProcessFacts(pid: 57751, startTime: 1, cwd: folder, arguments: ["pnpm", "dev"])
        var known = knowledge()
        let parents: [pid_t: pid_t] = [57753: 57752, 57752: 57751, 57751: 1, 100: 1]
        known.ancestors = { ProcessTree.ancestors(of: $0, parents: parents) }

        XCTAssertEqual(PortOwner.otherNextDevs([pnpm, parent, child, own], known), [parent])
        XCTAssertEqual(PortOwner.otherNextDevs([child], known), [child])
        XCTAssertEqual(PortOwner.otherNextDevs([own, pnpm], known), [])
    }

    func testTheTextOfAnotherNextDev() {
        let roots = ["/work/mono", "/work/login"]
        XCTAssertEqual(PortOwner.folderName("/work/mono/apps/booking-portal", roots: roots), "apps/booking-portal")
        XCTAssertEqual(PortOwner.folderName("/work/login", roots: roots), "login")
        XCTAssertEqual(
            PortOwner.otherNextDevText(pid: 57752, port: 3006, folder: "apps/booking-portal"),
            "Another next dev (PID 57752, port 3006) is running in apps/booking-portal. Next allows one dev server per folder."
        )
        XCTAssertEqual(
            PortOwner.otherNextDevText(pid: 57752, port: nil, folder: "apps/booking-portal"),
            "Another next dev (PID 57752) is running in apps/booking-portal. Next allows one dev server per folder."
        )
        XCTAssertEqual(RecoveryAction.stopProcessAndRetry(pid: 57752, sameFolder: true).title(), "Stop it and retry")
        XCTAssertEqual(RecoveryAction.stopProcessAndRetry(pid: 4242).title(), "Stop PID 4242 and retry")
    }

    func testListeningPortsAreReadFromLsof() {
        let output = "p57752\nf23\nn*:3006\nf24\nn[::1]:3006\np57753\nf25\nn127.0.0.1:9229\n"
        XCTAssertEqual(PortOwner.parsePorts(output), [3006, 9229])
        XCTAssertEqual(PortOwner.parsePorts(""), [])
    }

    // MARK: - The process table

    func testTheParentsOfAProcess() {
        let parents: [pid_t: pid_t] = [30: 20, 20: 10, 10: 1, 1: 0]
        XCTAssertEqual(ProcessTree.ancestors(of: 30, parents: parents), [20, 10, 1])
        XCTAssertEqual(ProcessTree.ancestors(of: 99, parents: parents), [])
        // A loop in a table that changed while it was read ends the walk.
        XCTAssertEqual(ProcessTree.ancestors(of: 5, parents: [5: 6, 6: 5]), [6])
    }

    func testTheArgumentsOfAProcessTable() {
        var buffer: [UInt8] = []
        withUnsafeBytes(of: Int32(3)) { buffer += $0 }
        buffer += Array("/usr/local/bin/node".utf8) + [0, 0, 0]
        buffer += Array("node".utf8) + [0] + Array("/x/next".utf8) + [0] + Array("dev".utf8) + [0]
        buffer += Array("PATH=/usr/bin".utf8) + [0]
        XCTAssertEqual(ProcessTree.parseArguments(buffer), ["node", "/x/next", "dev"])
        XCTAssertEqual(ProcessTree.parseArguments([1, 0]), [])
    }

    /// The facts of a process of this test: its start, its folder and its arguments.
    func testTheFactsOfAProcessThatThisTestStarted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PortOwnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        process.currentDirectoryURL = folder
        try process.run()
        defer { process.terminate() }

        let facts = try XCTUnwrap(ProcessTree.facts(of: process.processIdentifier))
        XCTAssertEqual(facts.cwd, PortOwner.realPath(folder.path))
        XCTAssertEqual(facts.arguments, ["/bin/sleep", "30"])
        XCTAssertGreaterThan(facts.startTime, 0)
        // The same process gives the same start time: the ledger compares it.
        XCTAssertEqual(ProcessTree.facts(of: process.processIdentifier)?.startTime, facts.startTime)
        XCTAssertEqual(ProcessTree.ancestors(of: process.processIdentifier).first, getpid())
        XCTAssertEqual(ProcessTree.processes(in: folder.path).map(\.pid), [process.processIdentifier])
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
