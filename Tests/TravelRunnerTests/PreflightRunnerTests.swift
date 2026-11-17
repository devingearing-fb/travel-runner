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

    func testThePortCheckForEachStateOfThePort() async throws {
        let free = try Self.freePort()
        let held = try Self.listen()
        defer { close(held.socket) }
        let rows: [(name: String, port: Int, lsof: String, ps: String, expected: String)] = [
            ("a free port", free, "", "", "passed: Free"),
            ("a port that a process holds", held.port, "4242\n", "/usr/local/bin/node\n",
             "failed: Port \(held.port) in use by node (PID 4242) | fix: kill 4242"),
            ("a held port whose owner is not found", held.port, "", "",
             "failed: Port \(held.port) in use | fix: lsof -ti TCP:\(held.port) -sTCP:LISTEN | xargs kill"),
            ("a number that is not a port", 70000, "", "", "passed: Free"),
        ]
        for row in rows {
            let (preflight, _) = runner([
                "lsof -ti TCP:\(row.port)": FakeCommandRunner.ok(row.lsof),
                "ps -p": FakeCommandRunner.ok(row.ps),
            ])
            let result = await preflight.run(check: PreflightCheck(id: "port-\(row.port)", name: "Port \(row.port) available"))
            XCTAssertEqual(describe(result), row.expected, row.name)
        }
    }

    func testTheFolderCheck() async throws {
        let present = try folder("apps/partner-portal")
        let rows: [(name: String, path: String, expected: String)] = [
            ("the folder is there", present, "passed: Found"),
            ("a path in services.json that is not there", workDir.appendingPathComponent("moved").path,
             "failed: Directory not found | fix: Check services.json paths"),
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

    /// A port that was free a moment ago.
    private static func freePort() throws -> Int {
        let bound = try listen()
        close(bound.socket)
        return bound.port
    }

    /// A socket that listens on a port of the system's choice, on 127.0.0.1.
    private static func listen() throws -> (socket: Int32, port: Int) {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw XCTSkip("no socket") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(sock, 1) == 0 else {
            close(sock)
            throw XCTSkip("could not listen on 127.0.0.1")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        return (sock, Int(UInt16(bigEndian: addr.sin_port)))
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
