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

    // MARK: - The checks of the registry

    /// A checker of Health for a checkout in the folder of the test, or without a
    /// checkout. Its commands go to `shell`, and it reads no tool of this Mac.
    private func environment(_ shell: FakeCommandRunner, monorepo: String? = nil, login: String? = nil) -> EnvironmentChecker {
        let checker = EnvironmentChecker(
            monorepoPath: monorepo ?? "",
            loginPath: login ?? "",
            streamServicesPath: "",
            flavor: .standard, shell: shell, tools: ToolEnvironment(home: "/nonexistent/home")
        )
        checker.buildChecks()
        return checker
    }

    /// The preflight with the checks of the registry, and the shell of both.
    private func preflight(_ answers: [String: CommandResult], profile: RunProfile = .both, monorepo: String? = nil, login: String? = nil)
        -> (PreflightRunner, FakeCommandRunner, EnvironmentChecker) {
        let (runner, shell) = runner(answers)
        var preflight = runner
        let checker = environment(shell, monorepo: monorepo, login: login)
        preflight.environment = checker
        preflight.profile = profile
        return (preflight, shell, checker)
    }

    /// One Node check: the Node row of Health. nvm, fnm and Volta put Node on the
    /// PATH only for some shells; the check runs in the monorepo, where its `.nvmrc` is.
    /// The threshold is `engines.node` of the monorepo, here 22.
    func testTheNodeCheckForEachAnswerOfNode() async throws {
        let monorepo = try folder("mono")
        try #"{"engines":{"node":">=22"}}"#.write(toFile: (monorepo as NSString).appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let fix = "Open Health → How to install"
        let rows: [(name: String, answer: CommandResult, expected: String)] = [
            ("Node 22", FakeCommandRunner.ok("v22.3.0\n"), "passed: v22.3.0"),
            ("a newer Node", FakeCommandRunner.ok("v24.11.1\n"), "passed: v24.11.1"),
            ("a login profile that prints first", FakeCommandRunner.ok("Now using node v22.3.0 (npm v10.8.1)\nv22.3.0\n"),
             "passed: v22.3.0"),
            // The wizard said "need 22+" and the preflight let Node 20 start: one threshold now.
            ("Node 20", FakeCommandRunner.ok("v20.11.1\n"), "failed: v20.11.1 — need 22+ | fix: \(fix)"),
            ("Node 16", FakeCommandRunner.ok("v16.20.2\n"), "failed: v16.20.2 — need 22+ | fix: \(fix)"),
            ("no Node on the PATH of the shell", FakeCommandRunner.failed(127, stderr: "zsh:1: command not found: node"),
             "failed: Node.js not found | fix: \(fix)"),
            ("a Node that prints no version", FakeCommandRunner.ok("nvm: N/A version is not installed\n"),
             "failed: node --version printed no version: nvm: N/A version is not installed | fix: \(fix)"),
            ("a Node that prints nothing", FakeCommandRunner.ok(""),
             "failed: Node.js not found | fix: \(fix)"),
            ("a Node that hangs", FakeCommandRunner.timedOut,
             "failed: node --version did not answer in 3 s | fix: \(fix)"),
        ]
        for row in rows {
            let (preflight, shell, checker) = self.preflight(["node --version": row.answer], monorepo: monorepo)
            let check = try XCTUnwrap(preflight.allChecks(for: []).first { $0.id == "node" }, row.name)
            let result = await preflight.run(check: check)
            XCTAssertEqual(describe(result), row.expected, row.name)
            XCTAssertEqual(shell.calls.map(\.cwd), [monorepo], row.name)
            XCTAssertEqual(shell.calls.map(\.timeout), [CheckRegistry.preflightLimit], row.name)
            // The Health row shows the same result.
            let health = checker.checks.first { $0.id == "node" }?.status
            XCTAssertEqual(health.map { CheckRegistry.preflightResult($0, severity: .blocksStart, fixLabel: "How to install") }.map(describe),
                           row.expected, row.name)
        }
    }

    /// The preflight runs the fast checks of the registry that the setup needs,
    /// for the profile. A check that asks the network, an optional check, and a
    /// check that the preflight runs as its own start step are left out.
    func testThePreflightTakesTheFastChecksOfTheRegistry() throws {
        let monorepo = try folder("mono")
        let login = try folder("login")
        let (preflight, _, checker) = self.preflight([:], monorepo: monorepo, login: login)

        let ids = preflight.allChecks(for: []).map(\.id)

        XCTAssertEqual(ids, ["node", "workspace-modules", "login-modules", "login-env", "docker"])
        for id in ["pnpm", "registry-auth", "stripe-auth", "booking-env", "partner-env", "hotel-data"] {
            XCTAssertEqual(checker.checks.first { $0.id == id }?.cost, .slow, id)
            XCTAssertFalse(ids.contains(id), id)
        }
        // Negative control: without the registry the preflight has only its own steps.
        XCTAssertEqual(PreflightRunner().allChecks(for: []).map(\.id), ["docker"])
    }

    /// Only a check that blocks the start fails the preflight. Packages that are
    /// not installed warn: the start installs them.
    func testOnlyACheckThatBlocksTheStartFailsThePreflight() async throws {
        let monorepo = try folder("mono")
        let login = try folder("login")
        let (preflight, _, _) = self.preflight(["node --version": FakeCommandRunner.ok("v22.3.0\n")], monorepo: monorepo, login: login)
        let checks = preflight.allChecks(for: [])

        await preflight.runAll(checks)

        let results = Dictionary(uniqueKeysWithValues: checks.map { ($0.id, describe($0.result)) })
        XCTAssertEqual(results["node"], "passed: v22.3.0")
        XCTAssertEqual(results["workspace-modules"], "warning: Run pnpm install at the monorepo root")
        XCTAssertEqual(results["login-modules"], "warning: Run npm install")
        XCTAssertEqual(results["login-env"], "warning: Missing")
    }

    /// The checks run in parallel: the Node check waits for the container runtime
    /// step, which a run one by one would start only after it.
    func testThePreflightChecksRunInParallel() async throws {
        let dockerAsked = Gate()
        let shell = FakeCommandRunner { call in
            if call.command.hasPrefix("docker ps") {
                await dockerAsked.open()
                return FakeCommandRunner.ok()
            }
            if call.command == "node --version" {
                await dockerAsked.wait()
                return FakeCommandRunner.ok("v22.3.0\n")
            }
            return FakeCommandRunner.ok()
        }
        var preflight = PreflightRunner(shell: shell, clock: FakeClock().clock)
        preflight.environment = environment(shell)
        let checks = preflight.allChecks(for: [])
        XCTAssertEqual(checks.map(\.id), ["node", "docker"], "Node comes first")

        let ran = Task { await preflight.runAll(checks) }
        let finished = await waitUntil(5) { checks.allSatisfy { if case .pending = $0.result { false } else { true } } }
        if !finished { await dockerAsked.open() }
        await ran.value

        XCTAssertTrue(finished, "the Node check waited for a step that never ran")
        XCTAssertTrue(checks.allSatisfy { $0.result.isPassed }, "\(checks.map { describe($0.result) })")
    }

    private func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
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
        let (preflight, _, _) = self.preflight([:])

        let checks = preflight.allChecks(for: services)

        // Without a checkout only the Node check of the registry applies.
        XCTAssertEqual(checks.map(\.id), [
            "node", "docker",
            "port-3002", "port-3003", "port-3010", "port-54322",
            "dir-mono", "dir-booking-portal", "dir-partner-portal",
        ])
        // /api/preflight runs only the checks that change nothing.
        XCTAssertEqual(preflight.readOnlyChecks(for: services).map(\.id), [
            "node", "port-3002", "port-3003", "port-3010", "port-54322",
            "dir-mono", "dir-booking-portal", "dir-partner-portal",
        ])
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
