import Foundation
import XCTest
@testable import TravelRunner

/// The checks of Start All, one table per check. Each row is an answer that a
/// teammate's Mac gave. The commands go to a fake shell, so no row reads the tools
/// of this Mac; the port rows use ports that the system picks.
@MainActor
final class PreflightRunnerTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("PreflightRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Helpers

    /// A result as one line, so a row compares all of it.
    private func describe(_ result: PreflightResult) -> String {
        switch result {
        case .pending: "pending"
        case .passed(let detail): "passed: \(detail)"
        case .warning(let message): "warning: \(message)"
        case .failed(let message, let fix): "failed: \(message) | fix: \(fix ?? "none")"
        }
    }

    /// A runner whose shell answers each command that starts with a key of `answers`.
    /// Any other command succeeds with no output.
    private func runner(_ answers: [String: CommandResult], clock: RunnerClock = FakeClock().clock) -> (PreflightRunner, FakeCommandRunner) {
        let shell = FakeCommandRunner { call in
            answers.first { call.command.hasPrefix($0.key) }?.value ?? FakeCommandRunner.ok()
        }
        return (PreflightRunner(shell: shell, clock: clock), shell)
    }

    private func service(_ id: String, cwd: String?, port: Int? = nil) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: id, cmd: ["true"], cwd: cwd,
            probe: port.map { ProbeConfig(type: .tcp, port: $0, host: nil, url: nil, pattern: nil, artifact: nil, timeout: 5) },
            type: .daemon, restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
    }

    private func folder(_ path: String) throws -> String {
        let url = workDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    // MARK: - Node

    /// nvm, fnm and Volta put Node on the PATH only for some shells. The check runs
    /// in the cwd of the booking portal, where its `.nvmrc` is.
    func testTheNodeCheckForEachAnswerOfNode() async throws {
        let portal = try folder("apps/booking-portal")
        let check = PreflightRunner().allChecks(for: [service("travel-portal", cwd: portal)])
            .first { $0.id == "node-version" }!
        let install = "Install Node 22 via nvm or brew"
        let rows: [(name: String, answer: CommandResult, expected: String)] = [
            ("Node 22", FakeCommandRunner.ok("v22.3.0\n"), "passed: v22.3.0"),
            ("a newer Node", FakeCommandRunner.ok("v24.11.1\n"), "passed: v24.11.1"),
            ("a login profile that prints first", FakeCommandRunner.ok("Now using node v22.3.0 (npm v10.8.1)\nv22.3.0\n"),
             "passed: v22.3.0"),
            ("Node 20", FakeCommandRunner.ok("v20.11.1\n"), "warning: v20.11.1 — recommend v22+"),
            ("Node 16", FakeCommandRunner.ok("v16.20.2\n"), "failed: v16.20.2 — require v18+ | fix: \(install)"),
            ("no Node on the PATH of the shell", FakeCommandRunner.failed(127, stderr: "zsh:1: command not found: node"),
             "failed: Node.js not found | fix: \(install)"),
            ("a Node that prints no version", FakeCommandRunner.ok("nvm: N/A version is not installed\n"),
             "failed: node --version printed no version: nvm: N/A version is not installed | fix: Run node --version in the portal folder"),
            ("a Node that prints nothing", FakeCommandRunner.ok(""),
             "failed: Node.js not found | fix: \(install)"),
            ("a Node that hangs", FakeCommandRunner.timedOut,
             "failed: node --version did not answer in 15 s | fix: Run node --version in a terminal to see what it waits for"),
        ]
        for row in rows {
            let (preflight, shell) = runner(["node --version": row.answer])
            let result = await preflight.run(check: check)
            XCTAssertEqual(describe(result), row.expected, row.name)
            XCTAssertEqual(shell.calls.map(\.cwd), [portal], row.name)
            XCTAssertEqual(shell.calls.map(\.timeout), [PreflightRunner.checkTimeout], row.name)
        }
    }

    /// A portal folder that is not there is not the cwd of the command: the
    /// folder check reports it, and Node is still asked.
    func testTheNodeCheckOfAMissingFolderRunsWithoutACwd() async {
        let check = PreflightRunner().allChecks(for: [service("travel-portal", cwd: workDir.appendingPathComponent("gone").path)])
            .first { $0.id == "node-version" }!
        let (preflight, shell) = runner(["node --version": FakeCommandRunner.ok("v22.3.0\n")])
        let result = await preflight.run(check: check)
        XCTAssertEqual(describe(result), "passed: v22.3.0")
        XCTAssertEqual(shell.calls.map(\.cwd), [nil])
    }

    // MARK: - Container runtime

    func testTheDockerCheckForEachStateOfTheRuntime() async {
        let runtime = ContainerRuntime.detect()
        // Each row: the answers of `docker ps`, in order; the last one repeats.
        let rows: [(name: String, answers: [Bool], expected: String, opened: Int)] = [
            ("the runtime answers", [true], "passed: \(runtime.displayName)", 0),
            ("the runtime comes up after the runner opens it", [false, false, false, true],
             "passed: \(runtime.displayName) — auto-started", 1),
            ("the runtime never comes up", [false],
             "failed: \(runtime.displayName) not responding | fix: Open \(runtime.appName) manually", 1),
        ]
        for row in rows {
            let answers = AnswerQueue(row.answers)
            let shell = FakeCommandRunner { call in
                guard call.command.hasPrefix("docker ps") else { return FakeCommandRunner.ok() }
                return answers.next() ? FakeCommandRunner.ok() : FakeCommandRunner.failed(1, stderr: "Cannot connect to the Docker daemon")
            }
            let preflight = PreflightRunner(shell: shell, clock: FakeClock().clock)
            let result = await preflight.run(check: PreflightCheck(id: "docker", name: runtime.displayName))
            XCTAssertEqual(describe(result), row.expected, row.name)
            XCTAssertEqual(shell.commands.filter { $0.hasPrefix("open -a") }.count, row.opened, row.name)
        }
    }

    // MARK: - Stripe

    /// Stripe is optional: no row blocks the start. The test key goes to the CLI
    /// in its environment, never in the command.
    func testTheStripeCheckForEachKeyAndAnswer() async throws {
        let withKey = try folder("key/apps/booking-portal")
        let key = "sk_test_madeUpForThePreflightTests"
        try "STRIPE_SECRET_KEY=\(key)\n".write(toFile: (withKey as NSString).appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        let withoutKey = try folder("nokey/apps/booking-portal")
        let skipped = "Stripe will be skipped"

        let rows: [(name: String, portal: String, installed: Bool, auth: CommandResult, expected: String)] = [
            ("no Stripe CLI", withKey, false, FakeCommandRunner.ok(), "warning: Not installed — \(skipped)"),
            ("the test key works", withKey, true, FakeCommandRunner.ok(), "passed: Test key from apps/booking-portal/.env"),
            ("Stripe rejects the test key", withKey, true, FakeCommandRunner.failed(1),
             "warning: Stripe did not accept STRIPE_SECRET_KEY from apps/booking-portal/.env, or there is no network — \(skipped); import a current .env"),
            ("no key, and the login works", withoutKey, true, FakeCommandRunner.ok(), "passed: Authenticated"),
            ("no key, and the login expired", withoutKey, true, FakeCommandRunner.failed(1),
             "warning: Session invalid or expired — \(skipped); run: stripe login"),
            ("Stripe does not answer", withKey, true, FakeCommandRunner.timedOut,
             "warning: stripe balance retrieve did not answer in 15 s — \(skipped)"),
        ]
        for row in rows {
            let check = PreflightRunner().allChecks(for: [service("travel-portal", cwd: row.portal)])
                .first { $0.id == "stripe-auth" }!
            let (preflight, shell) = runner([
                "which stripe": row.installed ? FakeCommandRunner.ok() : FakeCommandRunner.failed(1),
                StripeLauncher.authCheckCommand: row.auth,
            ])
            let result = await preflight.run(check: check)
            XCTAssertEqual(describe(result), row.expected, row.name)
            XCTAssertFalse(result.isFailed, row.name)
            XCTAssertFalse(shell.commands.contains { $0.contains(key) }, row.name)
            let auth = shell.calls.first { $0.command == StripeLauncher.authCheckCommand }
            XCTAssertEqual(auth?.environment[StripeLauncher.apiKeyVariable], row.installed && row.portal == withKey ? key : nil, row.name)
        }
    }

    // MARK: - Shared env files

    /// A missing or stale shared `.env` warns: local mode runs without it.
    func testTheSharedEnvCheckForEachReportOfTheScript() async throws {
        let monorepo = try folder("mono")
        let portal = try folder("mono/apps/booking-portal")
        let recorded = try String(
            contentsOf: MonolithCheckout.snapshot.appendingPathComponent("recorded/env-check-booking.json"), encoding: .utf8
        )
        func report(exists: Bool, missing: [String] = []) -> String {
            let names = missing.map { "\"\($0)\"" }.joined(separator: ",")
            let ok = exists && missing.isEmpty
            return #"{"version":1,"ok":\#(ok),"apps":[{"app":"booking","dir":"apps/booking-portal","envFile":"x","exists":\#(exists),"shared":21,"missing":[\#(names)],"blank":[],"shadowed":[],"ok":\#(ok)}]}"#
        }
        let rows: [(name: String, output: String, expected: String)] = [
            ("a complete file", report(exists: true), "passed: All 21 shared keys"),
            ("no file", report(exists: false),
             "warning: Missing — import the shared file. Local mode runs without it; remote mode needs it"),
            ("an old copy (the recorded output of the script)", recorded,
             "warning: Out of date: 20 of 21 shared keys missing (AMATEUR_SUPABASE_URL, AMATEUR_SUPABASE_ANON_KEY, AMATEUR_SUPABASE_SIGNING_KEY +17 more) — import a fresh copy"),
            ("a checkout without the script", "node:internal/modules/cjs/loader: Cannot find module",
             "warning: Could not run scripts/env-check.mjs — pull the latest monorepo dev"),
        ]
        let check = PreflightRunner().allChecks(for: [service("travel-portal", cwd: portal)])
            .first { $0.id == "env-diff-travel-portal" }!
        for row in rows {
            let (preflight, shell) = runner(["node ": FakeCommandRunner.ok(row.output)])
            let result = await preflight.run(check: check)
            XCTAssertEqual(describe(result), row.expected, row.name)
            XCTAssertEqual(shell.calls.map(\.command), [SharedEnvFiles.command(monorepo: monorepo, app: .booking)], row.name)
            XCTAssertEqual(shell.calls.map(\.cwd), [monorepo], row.name)
        }
    }

    // MARK: - Ports and folders

    /// Each owner of a port has its row. A port in use only warns: the start of its
    /// service stops the runner's own processes and asks about the others.
    func testThePortCheckForEachOwnerOfThePort() async throws {
        let node = PortOwner.Listener(pid: 4242, command: "node")
        let orb = PortOwner.Listener(pid: 99, command: "OrbStack Helper")
        let otherApp = PortOwner.realPath(NSHomeDirectory()) + "/code/other-app"
        let rows: [(name: String, occupants: [PortOwner.Occupant], reuse: Bool, expected: String)] = [
            ("a free port", [], false, "passed: Free"),
            ("a stranger", [PortOwner.Occupant(listener: node, owner: .foreign, cwd: otherApp)], false,
             "warning: In use by node (PID 4242, ~/code/other-app), which Travel Runner did not start"),
            ("a stranger whose folder is not known", [PortOwner.Occupant(listener: node, owner: .foreign)], false,
             "warning: In use by node (PID 4242), which Travel Runner did not start"),
            ("a process of the last session", [PortOwner.Occupant(listener: node, owner: .ownLeftover(serviceID: "web"))], false,
             "passed: In use by Travel Runner"),
            ("a process of this session", [PortOwner.Occupant(listener: node, owner: .ownLaunch(serviceID: "web"))], false,
             "passed: In use by Travel Runner"),
            ("the container of Supabase", [PortOwner.Occupant(listener: orb, owner: .containerRuntime)], true,
             "passed: In use by OrbStack Helper (a container) — reused"),
            ("a container on the port of a portal", [PortOwner.Occupant(listener: orb, owner: .containerRuntime)], false,
             "warning: Published by OrbStack Helper (a container) — stop that container"),
        ]
        for row in rows {
            var (preflight, shell) = runner([:])
            let occupants = row.occupants
            preflight.inspectPort = { _ in occupants }
            let check = PreflightCheck(id: "port-3002", name: "Port 3002 available", metadata: row.reuse ? ["reuse": "true"] : [:])
            let result = await preflight.run(check: check)
            XCTAssertEqual(describe(result), row.expected, row.name)
            XCTAssertEqual(shell.commands, [], row.name)
        }

        // A number that is not a port is not asked about.
        var (preflight, _) = runner([:])
        preflight.inspectPort = { _ in XCTFail("asked about 70000"); return [] }
        let result = await preflight.run(check: PreflightCheck(id: "port-70000", name: "Port 70000 available"))
        XCTAssertEqual(describe(result), "passed: Free")
    }

    /// The old check bound 127.0.0.1 with SO_REUSEADDR and called a port free while a
    /// server listened on ::1 only (Node binds `localhost` there). The listeners
    /// come from `lsof` now.
    func testThePortCheckSeesAServerOnIPv6Loopback() async throws {
        let held = try Self.listenOnIPv6Loopback()
        defer { close(held.socket) }
        let (preflight, _) = runner([:])

        let result = await preflight.run(check: PreflightCheck(id: "port-\(held.port)", name: "Port \(held.port) available"))

        XCTAssertTrue(describe(result).hasPrefix("warning: In use by "), describe(result))
        XCTAssertTrue(describe(result).contains("PID \(getpid())"), describe(result))
    }

    /// The port of a reuse_if_running service (Supabase) is marked: its stack holds it.
    func testThePortOfAReusedServiceIsMarked() {
        let supabase = ServiceDefinition(
            id: "supabase", name: "Supabase", cmd: ["true"], cwd: nil,
            probe: ProbeConfig(type: .tcp, port: 54322, host: nil, url: nil, pattern: nil, artifact: nil, timeout: 5),
            type: .daemon, restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: true
        )
        let checks = PreflightRunner().allChecks(for: [supabase, service("travel-portal", cwd: nil, port: 3002)])
        XCTAssertEqual(checks.first { $0.id == "port-54322" }?.metadata, ["reuse": "true"])
        XCTAssertEqual(checks.first { $0.id == "port-3002" }?.metadata, [:])
    }

    func testTheFolderCheck() async throws {
        let present = try folder("apps/partner-portal")
        let rows: [(name: String, path: String, expected: String)] = [
            ("the folder is there", present, "passed: Found"),
            ("a path in services.json that is not there", workDir.appendingPathComponent("moved").path,
             "failed: Directory not found — open Settings → Reconfigure Repos | fix: none"),
        ]
        for row in rows {
            let (preflight, shell) = runner([:])
            let result = await preflight.run(check: PreflightCheck(id: "dir-x", name: "x exists", metadata: ["path": row.path]))
            XCTAssertEqual(describe(result), row.expected, row.name)
            XCTAssertEqual(shell.commands, [], row.name)
        }
    }

    // MARK: - Which checks run

    func testTheChecksOfAStack() throws {
        let monorepo = try folder("mono")
        let booking = try folder("mono/apps/booking-portal")
        let partner = try folder("mono/apps/partner-portal")
        let forkApp = try XCTUnwrap(ServiceCatalog.forkAppIDs.sorted().first)
        let services = [
            service("supabase", cwd: monorepo, port: 54322),
            service("travel-portal", cwd: booking, port: 3002),
            service("partner-portal", cwd: partner, port: 3003),
            // An app of the fork that an old checkout lacks is skipped at its start.
            service(forkApp, cwd: workDir.appendingPathComponent("mono/apps/not-in-this-checkout").path, port: 3010),
        ]

        let checks = PreflightRunner().allChecks(for: services)

        XCTAssertEqual(checks.map(\.id), [
            "docker", "node-version", "stripe-auth", "env-diff-travel-portal", "env-diff-partner-portal",
            "port-3002", "port-3003", "port-3010", "port-54322",
            "dir-mono", "dir-booking-portal", "dir-partner-portal",
        ])
        XCTAssertEqual(checks.first { $0.id == "node-version" }?.metadata["cwd"], booking)
        XCTAssertEqual(checks.first { $0.id == "stripe-auth" }?.metadata["cwd"], booking)
        // /api/preflight runs only the checks that change nothing.
        XCTAssertEqual(PreflightRunner().readOnlyChecks(for: services).map(\.id), [
            "node-version", "port-3002", "port-3003", "port-3010", "port-54322",
            "dir-mono", "dir-booking-portal", "dir-partner-portal",
        ])
        // Without a portal Node is asked in the first folder of the stack.
        XCTAssertEqual(
            PreflightRunner().allChecks(for: [service("supabase", cwd: monorepo)]).first { $0.id == "node-version" }?.metadata["cwd"],
            monorepo
        )
    }

    // MARK: - Sockets of the test

    /// A socket that listens on a port of the system's choice, on ::1 only.
    private static func listenOnIPv6Loopback() throws -> (socket: Int32, port: Int) {
        let sock = socket(AF_INET6, SOCK_STREAM, 0)
        guard sock >= 0 else { throw XCTSkip("no socket") }
        var only: Int32 = 1
        setsockopt(sock, IPPROTO_IPV6, IPV6_V6ONLY, &only, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_addr = in6addr_loopback
        addr.sin6_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard bound == 0, Darwin.listen(sock, 1) == 0 else {
            close(sock)
            throw XCTSkip("could not listen on ::1")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        return (sock, Int(UInt16(bigEndian: addr.sin6_port)))
    }
}

/// Answers in order; the last answer repeats.
private final class AnswerQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]

    init(_ answers: [Bool]) { self.answers = answers }

    func next() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}
