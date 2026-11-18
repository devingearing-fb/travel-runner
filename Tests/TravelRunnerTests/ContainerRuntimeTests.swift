import XCTest
@testable import TravelRunner

/// The probe of the container runtime and the wait for it. Every command is a
/// fake and every wait runs on a fake clock: no docker, no app is opened.
final class ContainerRuntimeTests: XCTestCase {
    private let refused = "permission denied while trying to connect to the Docker daemon socket at unix:///var/run/docker.sock: Get \"http://%2Fvar%2Frun%2Fdocker.sock/v1.24/containers/json\": dial unix /var/run/docker.sock: connect: permission denied"
    private let orbstackDown = "Cannot connect to the Docker daemon at unix:///Users/a/.orbstack/run/docker.sock. Is the docker daemon running?"
    private let desktopDown = "Cannot connect to the Docker daemon at unix:///Users/a/.docker/run/docker.sock. Is the docker daemon running?"

    override func tearDown() {
        ContainerRuntime.forgetProbed()
        super.tearDown()
    }

    /// A shell whose `docker context show` prints `context` and whose `docker ps`
    /// gives the answers in order; the last one repeats.
    private func shell(context: CommandResult, ps answers: [CommandResult]) -> FakeCommandRunner {
        let queue = Answers(answers)
        return FakeCommandRunner { call in
            if call.command == "docker context show" { return context }
            if call.command.hasPrefix("docker ps") { return queue.next() }
            return FakeCommandRunner.ok()
        }
    }

    // MARK: - Context and socket

    func testTheRuntimeComesFromTheDockerContext() {
        let rows: [(context: String?, socket: String?, expected: ContainerRuntime?)] = [
            ("orbstack", nil, .orbstack),
            ("desktop-linux", nil, .docker),
            // The context wins over the socket.
            ("desktop-linux", "/Users/a/.orbstack/run/docker.sock", .docker),
            ("default", "/Users/a/.orbstack/run/docker.sock", .orbstack),
            ("default", "/Users/a/.docker/run/docker.sock", .docker),
            ("default", "/var/run/docker.sock", nil),
            ("default", nil, nil),
            // Colima and Rancher are not supported yet: the runner does not guess.
            ("colima", nil, nil),
            (nil, nil, nil),
        ]
        for row in rows {
            XCTAssertEqual(
                ContainerRuntime.runtime(context: row.context, socket: row.socket), row.expected,
                "\(row.context ?? "nil") \(row.socket ?? "nil")"
            )
        }
    }

    func testTheSocketIsReadFromDockersError() {
        XCTAssertEqual(ContainerRuntime.socket(in: refused), "/var/run/docker.sock")
        XCTAssertEqual(ContainerRuntime.socket(in: orbstackDown), "/Users/a/.orbstack/run/docker.sock")
        XCTAssertNil(ContainerRuntime.socket(in: "error during connect"))
    }

    // MARK: - Probe

    func testTheProbeForEachStateOfTheRuntime() async {
        let orbstack = FakeCommandRunner.ok("orbstack\n")
        let rows: [(name: String, context: CommandResult, ps: CommandResult, expected: ContainerRuntimeProbe)] = [
            ("docker is not on the PATH",
             FakeCommandRunner.failed(127, stderr: "zsh:1: command not found: docker"), FakeCommandRunner.ok(),
             .cliMissing),
            ("the daemon is down", orbstack, FakeCommandRunner.failed(1, stderr: orbstackDown),
             .daemonDown(ContainerRuntimeContext(name: "orbstack", runtime: .orbstack))),
            ("the daemon hangs", orbstack, FakeCommandRunner.timedOut,
             .daemonDown(ContainerRuntimeContext(name: "orbstack", runtime: .orbstack, timedOut: true))),
            ("the socket refuses the user", FakeCommandRunner.ok("desktop-linux\n"), FakeCommandRunner.failed(1, stderr: refused),
             .permissionDenied(ContainerRuntimeContext(name: "desktop-linux", runtime: .docker), socket: "/var/run/docker.sock")),
            ("the runtime runs", orbstack, FakeCommandRunner.ok(),
             .running(ContainerRuntimeContext(name: "orbstack", runtime: .orbstack))),
            // A login profile prints a line before the context.
            ("a profile line comes first", FakeCommandRunner.ok("Now using node v22.3.0\ndesktop-linux\n"), FakeCommandRunner.ok(),
             .running(ContainerRuntimeContext(name: "desktop-linux", runtime: .docker))),
            ("the default context names the socket of Docker Desktop", FakeCommandRunner.ok("default\n"),
             FakeCommandRunner.failed(1, stderr: desktopDown),
             .daemonDown(ContainerRuntimeContext(name: "default", runtime: .docker))),
        ]
        for row in rows {
            let runner = shell(context: row.context, ps: [row.ps])
            let probe = await ContainerRuntime.probe(shell: runner)
            XCTAssertEqual(probe, row.expected, row.name)
            XCTAssertFalse(runner.commands.contains { $0.hasPrefix("open") }, "a probe opens nothing: \(row.name)")
            XCTAssertTrue(runner.calls.allSatisfy { $0.timeout == ContainerRuntime.commandTimeout }, row.name)
        }
    }

    /// A missing docker is found from `docker context show`; `docker ps` is not run.
    func testAMissingCliRunsNoOtherCommand() async {
        let runner = shell(context: FakeCommandRunner.failed(127), ps: [FakeCommandRunner.ok()])
        let probe = await ContainerRuntime.probe(shell: runner)
        XCTAssertEqual(probe, .cliMissing)
        XCTAssertEqual(runner.commands, ["docker context show"])
    }

    /// The views read the runtime of the last probe: a Docker Desktop context is
    /// Docker Desktop, even with OrbStack installed.
    func testDetectReturnsTheRuntimeOfTheLastProbe() async {
        _ = await ContainerRuntime.probe(shell: shell(context: FakeCommandRunner.ok("desktop-linux\n"), ps: [FakeCommandRunner.ok()]))
        XCTAssertEqual(ContainerRuntime.detect(), .docker)
        _ = await ContainerRuntime.probe(shell: shell(context: FakeCommandRunner.ok("orbstack\n"), ps: [FakeCommandRunner.ok()]))
        XCTAssertEqual(ContainerRuntime.detect(), .orbstack)
        // Negative control: a context that names no runtime keeps the last one.
        _ = await ContainerRuntime.probe(shell: shell(context: FakeCommandRunner.ok("colima\n"), ps: [FakeCommandRunner.ok()]))
        XCTAssertEqual(ContainerRuntime.detect(), .orbstack)
    }

    // MARK: - Wait

    func testARunningRuntimeIsNotOpenedAndNotWaitedFor() async {
        let runner = shell(context: FakeCommandRunner.ok("orbstack\n"), ps: [FakeCommandRunner.ok()])
        let time = FakeClock()
        let probe = await ContainerRuntime.ensureRunning(shell: runner, clock: time.clock)
        XCTAssertEqual(probe, .running(ContainerRuntimeContext(name: "orbstack", runtime: .orbstack)))
        XCTAssertEqual(time.sleeps, [])
        XCTAssertFalse(runner.commands.contains { $0.hasPrefix("open") })
    }

    /// The app to open comes from the docker context, not from the apps on disk.
    func testTheRunnerOpensTheRuntimeOfTheContextAndWaitsForIt() async {
        let down = FakeCommandRunner.failed(1, stderr: desktopDown)
        let runner = shell(context: FakeCommandRunner.ok("desktop-linux\n"), ps: [down, down, down, FakeCommandRunner.ok()])
        let time = FakeClock()
        let lines = Lines()

        let probe = await ContainerRuntime.ensureRunning(shell: runner, clock: time.clock) { lines.append($0) }

        XCTAssertEqual(probe, .running(ContainerRuntimeContext(name: "desktop-linux", runtime: .docker, opened: true)))
        XCTAssertEqual(runner.commands.filter { $0.hasPrefix("open") }, ["open -a Docker"])
        XCTAssertEqual(time.sleeps, Array(repeating: .seconds(2), count: 3))
        // The context is read once; the wait asks only the daemon.
        XCTAssertEqual(runner.commands.filter { $0 == "docker context show" }.count, 1)
        XCTAssertEqual(lines.all, ["Docker Desktop is not running — opening it and waiting up to 120 s"])
    }

    /// A runtime that never answers is waited for 120 s, not 20 s, and the wait reports its progress.
    func testARuntimeThatNeverAnswersIsWaitedFor120Seconds() async {
        let runner = shell(context: FakeCommandRunner.ok("orbstack\n"), ps: [FakeCommandRunner.failed(1, stderr: orbstackDown)])
        let time = FakeClock()
        let lines = Lines()
        let began = Date()

        let probe = await ContainerRuntime.ensureRunning(shell: runner, clock: time.clock) { lines.append($0) }

        XCTAssertEqual(probe, .daemonDown(ContainerRuntimeContext(name: "orbstack", runtime: .orbstack, opened: true)))
        XCTAssertEqual(time.sleeps, Array(repeating: .seconds(2), count: 60))
        XCTAssertEqual(time.uptime, .seconds(120))
        XCTAssertEqual(runner.commands.filter { $0.hasPrefix("open") }, ["open -a OrbStack"])
        XCTAssertEqual(lines.all.first, "OrbStack is not running — opening it and waiting up to 120 s")
        XCTAssertEqual(lines.all.dropFirst().first, "Waiting for OrbStack — 10 s of 120 s")
        XCTAssertEqual(lines.all.last, "Waiting for OrbStack — 110 s of 120 s")
        XCTAssertEqual(lines.all.count, 12)
        XCTAssertEqual(
            probe.failureText(waited: ContainerRuntime.startTimeout),
            "OrbStack did not answer after 120 s — open it, then press Retry"
        )
        XCTAssertLessThan(Date().timeIntervalSince(began), 10)
    }

    /// A missing CLI and a refused socket do not get better with time: no app is
    /// opened and the runner does not wait.
    func testAMissingCliOrARefusedSocketReturnsAtOnce() async {
        let rows: [(name: String, context: CommandResult, ps: CommandResult, text: String)] = [
            ("no docker", FakeCommandRunner.failed(127, stderr: "zsh:1: command not found: docker"), FakeCommandRunner.ok(),
             "docker was not found on Travel Runner's PATH — install OrbStack or Docker Desktop"),
            ("permission denied", FakeCommandRunner.ok("orbstack\n"), FakeCommandRunner.failed(1, stderr: refused),
             "Docker refused the connection (permission denied on /var/run/docker.sock)"),
        ]
        for row in rows {
            let runner = shell(context: row.context, ps: [row.ps])
            let time = FakeClock()
            let probe = await ContainerRuntime.ensureRunning(shell: runner, clock: time.clock)
            XCTAssertEqual(probe.failureText(waited: ContainerRuntime.startTimeout), row.text, row.name)
            XCTAssertEqual(time.sleeps, [], row.name)
            XCTAssertFalse(runner.commands.contains { $0.hasPrefix("open") }, row.name)
        }
    }

    /// A refused socket during the wait ends it: the runtime is up but will not let the user in.
    func testARefusedSocketDuringTheWaitEndsIt() async {
        let down = FakeCommandRunner.failed(1, stderr: orbstackDown)
        let runner = shell(context: FakeCommandRunner.ok("orbstack\n"), ps: [down, down, FakeCommandRunner.failed(1, stderr: refused)])
        let time = FakeClock()
        let probe = await ContainerRuntime.ensureRunning(shell: runner, clock: time.clock)
        guard case .permissionDenied(_, let socket) = probe else { return XCTFail("\(probe)") }
        XCTAssertEqual(socket, "/var/run/docker.sock")
        XCTAssertEqual(time.sleeps.count, 2)
    }

    func testTheTextOfARunningRuntimeIsNil() {
        XCTAssertNil(ContainerRuntimeProbe.running(ContainerRuntimeContext(name: "orbstack", runtime: .orbstack)).failureText(waited: nil))
        XCTAssertEqual(
            ContainerRuntimeProbe.daemonDown(ContainerRuntimeContext(name: nil, runtime: .docker)).failureText(waited: nil),
            "Docker Desktop not responding"
        )
    }
}

private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [CommandResult]

    init(_ answers: [CommandResult]) { self.answers = answers }

    func next() -> CommandResult {
        lock.lock()
        defer { lock.unlock() }
        return answers.count > 1 ? answers.removeFirst() : answers[0]
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
