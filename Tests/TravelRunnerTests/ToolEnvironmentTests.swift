import Foundation
import XCTest
@testable import TravelRunner

final class ToolEnvironmentTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("tool-environment-\(UUID().uuidString)")
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

        let directories = ToolEnvironment.fallbackDirectories(cwd: nil, home: home.path)

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
        XCTAssertEqual(ToolEnvironment.nodeMajor(forCwd: cwd), 98)
        let directories = ToolEnvironment.fallbackDirectories(cwd: cwd, home: home.path)

        XCTAssertEqual(directories.last, wanted)
        XCTAssertFalse(directories.contains(newer))
    }

    func testNoNvmrcGivesNoMajor() throws {
        XCTAssertNil(ToolEnvironment.nodeMajor(forCwd: nil))
        try "lts/iron\n".write(to: home.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        XCTAssertNil(ToolEnvironment.nodeMajor(forCwd: home.path))
    }

    func testWrapPutsTheShellPathFirstAndTheFallbackLast() {
        XCTAssertEqual(ToolEnvironment.wrap("pnpm dev", before: [], after: []), "pnpm dev")
        XCTAssertEqual(
            ToolEnvironment.wrap("pnpm dev", before: [], after: ["/opt/homebrew/bin", "/Users/a b/Library/pnpm"]),
            "export PATH=\"$PATH\":/opt/homebrew/bin:'/Users/a b/Library/pnpm'; typeset -U path; pnpm dev"
        )
        XCTAssertEqual(
            ToolEnvironment.wrap(
                "pnpm dev", before: ["/Users/a/.nvm/versions/node/v22.1.0/bin"], after: ["/opt/homebrew/bin"],
                variables: ["PNPM_HOME": "/Users/a b/pnpm", "DOCKER_CONTEXT": "colima"]
            ),
            "export PATH=/Users/a/.nvm/versions/node/v22.1.0/bin:\"$PATH\":/opt/homebrew/bin; typeset -U path; "
                + "[ -n \"$DOCKER_CONTEXT\" ] || DOCKER_CONTEXT=colima; export DOCKER_CONTEXT; "
                + "[ -n \"$PNPM_HOME\" ] || PNPM_HOME='/Users/a b/pnpm'; export PNPM_HOME; pnpm dev"
        )
    }

    /// The wrapped command in a real zsh: the order of the PATH, no repeats, and
    /// a variable only when the shell does not have it.
    func testTheWrappedCommandSetsThePathAndTheVariablesInZsh() async {
        let command = ToolEnvironment.wrap(
            "print -r -- \"$PATH\"; print -r -- \"$COREPACK_HOME|$DOCKER_CONTEXT\"; env | grep -c '^COREPACK_HOME='",
            before: ["/tr/first", "/usr/bin"], after: ["/tr/last", "/usr/bin"],
            variables: ["COREPACK_HOME": "/tr/core pack", "DOCKER_CONTEXT": "from-rc-file"]
        )

        let result = await Shell.execute(
            "/bin/zsh", ["-c", "unset COREPACK_HOME; PATH=/usr/bin:/bin; \(command)"],
            environment: ["DOCKER_CONTEXT": "from-the-app"]
        )

        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "/tr/first:/usr/bin:/bin:/tr/last")
        XCTAssertEqual(lines.dropFirst().first, "/tr/core pack|from-the-app")
        XCTAssertEqual(lines.last, "1", "the new variable is exported")
    }

    // MARK: - The shell of the user

    private let captured = """
        __TR_LOGIN_PATH__/usr/local/bin:/usr/bin:/bin
        Welcome to my shell
        PATH=/a/line/of/the/rc/file
        __TR_ENV_START__
        SHELL=/bin/zsh
        HOME=/Users/a
        PATH=/Users/a/.nvm/versions/node/v22.11.0/bin:/Users/a/Library/pnpm/:relative/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin
        PNPM_HOME=/Users/a/Library/pnpm
        DOCKER_HOST=unix:///Users/a/.colima/default/docker.sock
        GITHUB_TOKEN=ghp_notForTheRunner
        VOLTA_HOME=
        __TR_ENV_END__
        PATH=/after/the/end

        """

    func testTheCaptureReadsOnlyBetweenTheMarks() {
        let capture = ToolEnvironment.parseCapture(captured)

        XCTAssertEqual(capture.loginPath, ["/usr/local/bin", "/usr/bin", "/bin"])
        XCTAssertEqual(capture.shellPath, [
            "/Users/a/.nvm/versions/node/v22.11.0/bin", "/Users/a/Library/pnpm", "/usr/local/bin", "/usr/bin", "/bin",
        ], "absolute directories, each one once")
        XCTAssertEqual(capture.shell, "/bin/zsh")
        XCTAssertNil(capture.note)
        // Only the allowed variables, and never a secret of the user's shell.
        XCTAssertEqual(capture.variables, [
            "PNPM_HOME": "/Users/a/Library/pnpm",
            "DOCKER_HOST": "unix:///Users/a/.colima/default/docker.sock",
        ])
    }

    func testOutputWithoutTheMarksGivesNoShellPath() {
        let noEnd = ToolEnvironment.parseCapture("__TR_LOGIN_PATH__/usr/bin\n__TR_ENV_START__\nPATH=/half/printed\n")
        XCTAssertEqual(noEnd.loginPath, ["/usr/bin"])
        XCTAssertEqual(noEnd.shellPath, [])
        XCTAssertEqual(noEnd.note, "Your shell did not print its environment.")

        let nothing = ToolEnvironment.parseCapture("")
        XCTAssertEqual(nothing.shellPath, [])
        XCTAssertNotNil(nothing.note)
    }

    func testResolveAsksTheShellOfTheUserOnce() async {
        let output = captured
        let runner = FakeCommandRunner { _ in FakeCommandRunner.ok(output) }
        let tools = ToolEnvironment(home: home.path)

        await tools.resolve(runner: runner)

        XCTAssertEqual(runner.calls, [FakeCommandRunner.Call(
            command: ToolEnvironment.captureCommand, cwd: nil, environment: ["TERM": "dumb"], timeout: .seconds(5)
        )])
        // The user's own shell, as a login and interactive shell, with the marks around `env`.
        XCTAssertTrue(ToolEnvironment.captureCommand.contains(#""${SHELL:-/bin/zsh}" -l -i -c"#))
        XCTAssertTrue(ToolEnvironment.captureCommand.contains("__TR_ENV_START__"))
        XCTAssertEqual(tools.capture.shellPath.first, "/Users/a/.nvm/versions/node/v22.11.0/bin")

        // The services get the PATH of the interactive shell in front of the login PATH.
        let wrapped = tools.wrap("node server.js", cwd: nil)
        XCTAssertTrue(wrapped.hasPrefix("export PATH=/Users/a/.nvm/versions/node/v22.11.0/bin:/Users/a/Library/pnpm:"), wrapped)
        XCTAssertTrue(wrapped.contains(":/bin:\"$PATH\""), wrapped)
        XCTAssertTrue(wrapped.contains("PNPM_HOME=/Users/a/Library/pnpm; export PNPM_HOME; "), wrapped)
        XCTAssertTrue(wrapped.hasSuffix("; node server.js"))
    }

    /// An rc file with an older default Node (`nvm alias default`) put that Node in
    /// front of the one that fits the `.nvmrc`. Before the shell PATH was read, the
    /// login shell had no Node and the fitting one was found.
    func testANodeOfTheShellPathThatIsTooOldDoesNotHideTheOneThatFits() throws {
        // Majors that no real install has, so the Node versions of this Mac do not count.
        let old = try makeNode("v97.4.0")
        let wanted = try makeNode("v98.2.0")
        let checkout = home.appendingPathComponent("repo")
        try makeDirectory("repo")
        try "98\n".write(to: checkout.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)

        XCTAssertEqual(
            ToolEnvironment.nodeAhead(ofShellPath: ["/usr/bin", old], cwd: checkout.path, home: home.path), wanted
        )
        let tools = ToolEnvironment(home: home.path, capture: .init(shellPath: ["/usr/bin", old]))
        let wrapped = tools.wrap("node server.js", cwd: checkout.path)
        XCTAssertTrue(wrapped.hasPrefix("export PATH=\(wanted):/usr/bin:\(old):\"$PATH\""), wrapped)

        // A link to the old install on the PATH (fnm, Homebrew) is the same install.
        try makeDirectory("links")
        let link = home.appendingPathComponent("links/current").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: old)
        XCTAssertEqual(ToolEnvironment.nodeAhead(ofShellPath: [link], cwd: checkout.path, home: home.path), wanted)

        // Controls: a Node that fits stays first; so does one that no version manager
        // knows; and with no install that fits, nothing moves.
        XCTAssertNil(ToolEnvironment.nodeAhead(ofShellPath: [wanted, old], cwd: checkout.path, home: home.path))
        let unknown = home.appendingPathComponent("shims")
        try makeDirectory("shims")
        try "#!/bin/sh\n".write(to: unknown.appendingPathComponent("node"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: unknown.appendingPathComponent("node").path
        )
        XCTAssertNil(ToolEnvironment.nodeAhead(ofShellPath: [unknown.path, old], cwd: checkout.path, home: home.path))
        try "99\n".write(to: checkout.appendingPathComponent(".nvmrc"), atomically: true, encoding: .utf8)
        XCTAssertNil(ToolEnvironment.nodeAhead(ofShellPath: [old], cwd: checkout.path, home: home.path))
        XCTAssertNil(ToolEnvironment.nodeAhead(ofShellPath: ["/nonexistent"], cwd: checkout.path, home: home.path))
    }

    /// Negative control: before a resolve the command has no directory of the rc file.
    func testWithoutAResolveOnlyTheFallbackDirectoriesAreAdded() throws {
        try makeDirectory("Library/pnpm")
        let wrapped = ToolEnvironment(home: home.path).wrap("node server.js", cwd: nil)

        XCTAssertTrue(wrapped.hasPrefix("export PATH=\"$PATH\":"), wrapped)
        XCTAssertTrue(wrapped.contains("\(home.path)/Library/pnpm"), wrapped)
        XCTAssertFalse(wrapped.contains(".nvm"))
    }

    func testAShellThatTimesOutKeepsTheEarlierCapture() async {
        let output = captured
        let runner = FakeCommandRunner { _ in FakeCommandRunner.ok(output) }
        let tools = ToolEnvironment(home: home.path)
        await tools.resolve(runner: runner)
        let first = tools.capture

        runner.respond { _ in FakeCommandRunner.timedOut }
        await tools.resolve(runner: runner)

        XCTAssertEqual(tools.capture.shellPath, first.shellPath)
        XCTAssertEqual(tools.capture.loginPath, first.loginPath)
        XCTAssertEqual(tools.capture.variables, first.variables)
        XCTAssertEqual(tools.capture.note, "Your shell did not answer in 5 s.")
    }

    func testAShellThatTimesOutOnTheFirstReadLeavesTheFallback() async {
        let tools = ToolEnvironment(home: home.path)
        await tools.resolve(runner: FakeCommandRunner { _ in FakeCommandRunner.timedOut })

        XCTAssertEqual(tools.capture.shellPath, [])
        XCTAssertEqual(tools.capture.note, "Your shell did not answer in 5 s.")
        XCTAssertFalse(tools.wrap("node -v", cwd: nil).contains("__TR"))
    }

    func testRefreshRunsTheLastResolveAgainAndDoesNothingBeforeIt() async {
        let output = captured
        let runner = FakeCommandRunner { _ in FakeCommandRunner.ok(output) }
        let tools = ToolEnvironment(home: home.path)

        tools.refresh()
        await tools.settled()
        XCTAssertEqual(runner.calls.count, 0)
        XCTAssertEqual(tools.capture, ToolEnvironment.Capture())

        await tools.resolve(runner: runner)
        runner.respond { _ in
            FakeCommandRunner.ok("__TR_ENV_START__\nPATH=/new/tool/bin:/usr/bin\n__TR_ENV_END__\n")
        }
        tools.refresh()
        await tools.settled()

        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(tools.capture.shellPath, ["/new/tool/bin", "/usr/bin"])
        XCTAssertEqual(tools.capture.loginPath, ["/usr/local/bin", "/usr/bin", "/bin"], "the earlier login PATH stays")
    }

    /// A service that starts while the shell is read must get the new PATH.
    func testACommandThatStartsDuringAResolveWaitsForIt() async {
        let gate = Gate()
        let seen = Seen()
        let tools = ToolEnvironment(home: home.path)
        let runner = FakeCommandRunner { _ in
            // The command of the resolve itself runs in the plain login shell and does not wait.
            await tools.settled()
            seen.set(tools.wrap("inner", cwd: nil))
            await gate.wait()
            return FakeCommandRunner.ok("__TR_ENV_START__\nPATH=/resolved/bin\n__TR_ENV_END__\n")
        }

        tools.beginResolve(runner: runner)
        let waiter = Task { () -> String in
            await tools.settled()
            return tools.wrap("node", cwd: nil)
        }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(tools.capture.shellPath, [], "the resolve still runs")

        await gate.open()
        let wrapped = await waiter.value

        XCTAssertTrue(wrapped.hasPrefix("export PATH=/resolved/bin:\"$PATH\""), wrapped)
        XCTAssertEqual(seen.value, "inner")
    }

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        func set(_ value: String) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    // MARK: - Tools report

    private static let reportPath =
        "/Users/a/.nvm/versions/node/v22.11.0/bin:/usr/local/bin:/usr/bin:/bin:/Users/a/.orbstack/bin"

    /// The answer of the report command of one tool.
    private static func toolAnswer(_ found: String, _ version: String = "") -> CommandResult {
        FakeCommandRunner.ok("__TR_PATH__\(reportPath)\n__TR_TOOL__\(found)\n\(version)")
    }

    /// The tool that a report command asks for.
    private static func tool(of call: FakeCommandRunner.Call, in tools: [String]) -> String? {
        tools.first { call.command == ToolEnvironment.reportCommand(tool: $0) }
    }

    func testTheReportSaysWhereEachToolComesFrom() async {
        let capture = ToolEnvironment.parseCapture(captured)
        let tools = ToolEnvironment(home: home.path, capture: capture)
        let names = ["node", "pnpm", "docker", "stripe", "git"]
        let runner = FakeCommandRunner { call in
            switch Self.tool(of: call, in: names) {
            case "node": Self.toolAnswer("/Users/a/.nvm/versions/node/v22.11.0/bin/node", "v22.11.0\n")
            case "pnpm": Self.toolAnswer("/Users/a/Library/pnpm/pnpm", "Update available! 10.1.0 → 12.0.0\n10.34.5\n")
            case "docker": Self.toolAnswer("/Users/a/.orbstack/bin/docker", "Docker version 27.0.3, build 7d4bcd8\n")
            case "stripe": Self.toolAnswer("")
            case "git": Self.toolAnswer("/usr/bin/git", "git version 2.50.1 (Apple Git-155)\n")
            default: FakeCommandRunner.failed()
            }
        }

        let report = await tools.report(runner: runner, cwd: "/mono", tools: names)

        XCTAssertEqual(runner.calls.count, 5, "one command for each tool")
        XCTAssertTrue(runner.calls.allSatisfy { $0.cwd == "/mono" && $0.timeout == .seconds(10) })
        XCTAssertEqual(report.map(\.name), names)
        XCTAssertEqual(report.map(\.version), ["22.11.0", "10.34.5", "27.0.3", nil, "2.50.1"])
        XCTAssertEqual(report.map(\.origin), [
            .rcFile("~/.zshrc", manager: "nvm"), .rcFile("~/.zshrc", manager: "pnpm"), .runner, nil, .loginShell,
        ])
        XCTAssertEqual(report.map(\.problem), [nil, nil, nil, nil, nil])
        XCTAssertEqual(
            report[0].text(appName: "Travel Runner"),
            "node comes from ~/.zshrc (nvm). Travel Runner found it and will use v22.11.0 at /Users/a/.nvm/versions/node/v22.11.0/bin/node."
        )
        XCTAssertEqual(
            report[2].text(appName: "Travel Runner"),
            "docker is not on the PATH of your shell. Travel Runner found it and will use v27.0.3 at /Users/a/.orbstack/bin/docker."
        )
        XCTAssertEqual(
            report[3].text(appName: "Travel Runner"),
            "stripe was not found. Travel Runner looked in: /Users/a/.nvm/versions/node/v22.11.0/bin:/usr/local/bin:/usr/bin:/bin:/Users/a/.orbstack/bin."
        )
        XCTAssertFalse(report[3].isFound)
        XCTAssertFalse(report[3].isUnread, "the shell said that stripe is not there")
        XCTAssertEqual(report[4].text(appName: "Travel Runner"), "git v2.50.1 at /usr/bin/git.")
    }

    /// `pnpm --version` can hang (corepack with no network). The tools after it
    /// had no line in the one shared command, and all of them read "was not found".
    func testAToolThatHangsDoesNotHideTheOthers() async {
        let tools = ToolEnvironment(home: home.path, capture: ToolEnvironment.parseCapture(captured))
        let names = ["node", "pnpm", "docker"]
        let runner = FakeCommandRunner { call in
            switch Self.tool(of: call, in: names) {
            case "node": Self.toolAnswer("/usr/local/bin/node", "v22.11.0\n")
            // The path came before the hang; the version did not.
            case "pnpm": CommandResult(
                exitCode: -1, stdout: "__TR_PATH__\(Self.reportPath)\n__TR_TOOL__/Users/a/Library/pnpm/pnpm\n",
                stderr: "", timedOut: true
            )
            case "docker": Self.toolAnswer("/Users/a/.orbstack/bin/docker", "Docker version 27.0.3, build 7d4bcd8\n")
            default: FakeCommandRunner.failed()
            }
        }

        let report = await tools.report(runner: runner, tools: names)

        XCTAssertEqual(report.map(\.isFound), [true, true, true])
        XCTAssertEqual(report.map(\.version), ["22.11.0", nil, "27.0.3"])
        XCTAssertEqual(
            report[1].text(appName: "Travel Runner"),
            "pnpm is at /Users/a/Library/pnpm/pnpm. pnpm --version did not answer in 10 s. Click Look Again."
        )
        XCTAssertNil(report[2].problem)
    }

    /// A report that timed out, or did not run, is not a list of missing tools.
    func testAReportThatTimedOutOrDidNotRunSaysSoAndNamesNoToolAsMissing() async {
        let tools = ToolEnvironment(home: home.path)

        let timedOut = await tools.report(runner: FakeCommandRunner { _ in FakeCommandRunner.timedOut }, tools: ["node", "docker"])
        XCTAssertEqual(timedOut.map(\.isUnread), [true, true])
        XCTAssertEqual(timedOut.map(\.isFound), [false, false])
        XCTAssertEqual(
            timedOut[1].text(appName: "Travel Runner"),
            "Travel Runner could not read docker: the shell did not answer in 10 s. Click Look Again."
        )

        // A cancelled command, or one that did not start: exit -1 and no output.
        let empty = await tools.report(
            runner: FakeCommandRunner { _ in CommandResult(exitCode: -1, stdout: "", stderr: "Cancelled") }, tools: ["node"]
        )
        XCTAssertTrue(empty[0].isUnread)
        XCTAssertEqual(
            empty[0].text(appName: "Travel Runner"),
            "Travel Runner could not read node: the shell command did not run. Click Look Again."
        )
        XCTAssertFalse(empty[0].text().contains("was not found"))

        // Control: only the shell's own "not there" line gives "was not found".
        let missing = await tools.report(runner: FakeCommandRunner { _ in Self.toolAnswer("") }, tools: ["node"])
        XCTAssertFalse(missing[0].isUnread)
        XCTAssertTrue(missing[0].text().contains("node was not found."), missing[0].text())
    }

    /// Before the shell was read the sources are not known, so the text names none.
    func testWithoutACaptureTheReportNamesNoSource() {
        let report = ToolEnvironment.parseReport(
            FakeCommandRunner.ok("__TR_PATH__/usr/bin\n__TR_TOOL__/opt/homebrew/bin/node\nv22.1.0\n"),
            tool: "node", capture: ToolEnvironment.Capture()
        )
        XCTAssertNil(report.origin)
        XCTAssertEqual(report.text(appName: "Travel Runner"), "node v22.1.0 at /opt/homebrew/bin/node.")
    }

    // MARK: - Exit 127

    /// The probe of `lookup` as the shell would answer it. Like the login shell,
    /// it waits for a read of the user's shell that runs.
    private static func lookupRunner(
        _ tools: ToolEnvironment, found: @escaping @Sendable () -> String?
    ) -> FakeCommandRunner {
        FakeCommandRunner { _ in
            await tools.settled()
            if let path = found() { return FakeCommandRunner.ok("\(path)\n") }
            return CommandResult(exitCode: 3, stdout: "/usr/bin:/bin\n", stderr: "")
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// The user added the tool to the rc file after the launch of the app. The
    /// text must say that the tool is found now, not ask about the branch.
    func testAfterExit127AToolThatTheNewReadFindsIsFoundNow() async {
        let tools = ToolEnvironment(home: home.path)
        let userShell = FakeCommandRunner { _ in
            FakeCommandRunner.ok("__TR_ENV_START__\nPATH=/usr/bin\n__TR_ENV_END__\n")
        }
        await tools.resolve(runner: userShell)
        // The shell has the tool only after the next read.
        let readAgain = Flag()
        userShell.respond { _ in
            readAgain.set()
            return FakeCommandRunner.ok("__TR_ENV_START__\nPATH=/new/bin:/usr/bin\n__TR_ENV_END__\n")
        }

        let finding = await tools.diagnoseMissing(
            tool: "pnpm", cwd: nil, runner: Self.lookupRunner(tools) { readAgain.isSet ? "/new/bin/pnpm" : nil }
        )

        XCTAssertEqual(finding, .foundNow(path: "/new/bin/pnpm"))
        XCTAssertEqual(userShell.calls.count, 2, "exit 127 reads the shell again")
        XCTAssertEqual(
            ToolEnvironment.foundNowText(name: "Booking Portal", tool: "pnpm", path: "/new/bin/pnpm", appName: "Travel Runner"),
            "Booking Portal could not find pnpm when it started. Travel Runner read your shell again and found it at /new/bin/pnpm. Restart Booking Portal."
        )
    }

    func testAfterExit127AToolThatIsStillNotThereIsNotFound() async {
        let tools = ToolEnvironment(home: home.path)
        let userShell = FakeCommandRunner { _ in
            FakeCommandRunner.ok("__TR_ENV_START__\nPATH=/usr/bin\n__TR_ENV_END__\n")
        }
        await tools.resolve(runner: userShell)

        let finding = await tools.diagnoseMissing(tool: "pnpm", cwd: nil, runner: Self.lookupRunner(tools) { nil })

        XCTAssertEqual(finding, .notFound(searchedPath: "/usr/bin:/bin"))
        XCTAssertEqual(userShell.calls.count, 2, "exit 127 reads the shell again")
    }

    /// Control: `pnpm dev` ends with 127 when a tool inside the script is missing.
    /// pnpm itself was there, so the text must not say that pnpm was found again.
    func testAfterExit127AToolThatTheLaunchHadGivesNoFinding() async {
        let tools = ToolEnvironment(home: home.path)
        let userShell = FakeCommandRunner { _ in
            FakeCommandRunner.ok("__TR_ENV_START__\nPATH=/usr/bin\n__TR_ENV_END__\n")
        }
        await tools.resolve(runner: userShell)

        let finding = await tools.diagnoseMissing(tool: "pnpm", cwd: nil, runner: Self.lookupRunner(tools) { "/usr/bin/pnpm" })

        XCTAssertNil(finding)
        await tools.settled()
        XCTAssertEqual(userShell.calls.count, 2, "exit 127 still reads the shell again")

        // A shell that cannot run gives no finding.
        let broken = await tools.diagnoseMissing(tool: "pnpm", cwd: nil, runner: FakeCommandRunner { _ in FakeCommandRunner.timedOut })
        XCTAssertNil(broken)
    }

    /// The report command in a real zsh, with a tool that no Mac has.
    func testTheReportCommandFindsAToolAndItsVersion() async throws {
        let tool = "tr-fake-node-\(UUID().uuidString)"
        try makeDirectory("tools")
        let file = home.appendingPathComponent("tools/\(tool)")
        try "#!/bin/sh\necho v98.1.0\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let directory = home.appendingPathComponent("tools").path
        let missing = "tr-no-such-tool-\(UUID().uuidString)"
        let tools = ToolEnvironment(home: home.path, capture: .init(shellPath: [directory], loginPath: ["/usr/bin"]))

        let report = await tools.report(runner: LoginShell(tools: tools), tools: [tool, missing])

        XCTAssertEqual(report[0].path, "\(directory)/\(tool)")
        XCTAssertEqual(report[0].version, "98.1.0")
        XCTAssertEqual(report[0].origin, .rcFile("~/.zshrc", manager: nil))
        XCTAssertNil(report[1].path)
        XCTAssertTrue(report[1].searchedPath.hasPrefix(directory + ":"), report[1].searchedPath)
        XCTAssertTrue(report[1].text().contains("was not found."))
    }

    func testTheRcFileAndTheManagerOfATool() {
        XCTAssertEqual(ToolEnvironment.rcFile(ofShell: "/bin/zsh"), "~/.zshrc")
        XCTAssertEqual(ToolEnvironment.rcFile(ofShell: nil), "~/.zshrc")
        XCTAssertEqual(ToolEnvironment.rcFile(ofShell: "/opt/homebrew/bin/bash"), "~/.bashrc")
        XCTAssertEqual(ToolEnvironment.rcFile(ofShell: "/opt/homebrew/bin/fish"), "~/.config/fish/config.fish")
        XCTAssertEqual(ToolEnvironment.rcFile(ofShell: "/usr/local/bin/nu"), "your shell profile")

        XCTAssertEqual(ToolEnvironment.manager(ofDirectory: "/Users/a/.local/share/fnm/aliases/default/bin"), "fnm")
        XCTAssertEqual(ToolEnvironment.manager(ofDirectory: "/Users/a/.volta/bin"), "Volta")
        XCTAssertEqual(ToolEnvironment.manager(ofDirectory: "/Users/a/.local/share/mise/shims"), "mise")
        XCTAssertEqual(ToolEnvironment.manager(ofDirectory: "/Users/a/.asdf/shims"), "asdf")
        XCTAssertEqual(ToolEnvironment.manager(ofDirectory: "/opt/homebrew/bin"), "Homebrew")
        XCTAssertNil(ToolEnvironment.manager(ofDirectory: "/Users/a/bin"))
    }

    func testToolVersionTakesTheLastVersionLine() {
        XCTAssertEqual(ToolVersion.parse("v22.11.0\n"), "22.11.0")
        XCTAssertEqual(ToolVersion.parse("Update available! 10.1.0 → 12.0.0\n10.34.5\n"), "10.34.5")
        XCTAssertEqual(ToolVersion.parse("9.1\n"), "9.1")
        XCTAssertNil(ToolVersion.parse("command not found: pnpm\n"))
        XCTAssertNil(ToolVersion.parse("Docker version 27.0.3, build 7d4bcd8\n"))
        XCTAssertEqual(ToolVersion.find(in: "Docker version 27.0.3, build 7d4bcd8\n"), "27.0.3")
        XCTAssertEqual(ToolVersion.find(in: "stripe version 1.21.8\n"), "1.21.8")
        XCTAssertNil(ToolVersion.find(in: "no version here"))
    }

    // MARK: - Preflight

    /// The preflight of a start ran `node --version` in a bare login shell, so a Node
    /// from `~/.zshrc` failed the start before any service ran.
    func testAPreflightCommandFindsAToolOfTheShellPath() async throws {
        // A name that no Mac has, so the tools of this machine do not count.
        let tool = "tr-fake-node-\(UUID().uuidString)"
        try makeDirectory("tools")
        let file = home.appendingPathComponent("tools/\(tool)")
        try "#!/bin/sh\necho v98.1.0\n".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let directory = home.appendingPathComponent("tools").path

        // The startup files of the person who runs the tests are not read: a
        // profile that prints a line would change the output.
        try makeDirectory("zdotdir")
        let zdotdir = home.appendingPathComponent("zdotdir").path
        let resolved = ProfileFreeLoginShell(
            tools: ToolEnvironment(home: home.path, capture: .init(shellPath: [directory])), zdotdir: zdotdir
        )
        let found = await PreflightRunner(shell: resolved).shellOutput("\(tool) --version")
        XCTAssertEqual(found.trimmingCharacters(in: .whitespacesAndNewlines), "v98.1.0")

        // Negative control: without the directory the shell does not find it.
        let bare = ProfileFreeLoginShell(tools: ToolEnvironment(home: home.path), zdotdir: zdotdir)
        let missing = await PreflightRunner(shell: bare).shellOutput("\(tool) --version")
        XCTAssertEqual(missing.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    /// A check command that hangs held the start for ever. Now it fails by name.
    func testAPreflightCheckThatTimesOutFailsAndSaysSo() async {
        let runner = FakeCommandRunner { call in
            call.command.hasPrefix("which stripe") ? FakeCommandRunner.ok() : FakeCommandRunner.timedOut
        }
        let preflight = PreflightRunner(shell: runner)

        let node = await preflight.run(check: PreflightCheck(id: "node-version", name: "Node"))
        guard case .failed(let message, _) = node else { return XCTFail("\(node)") }
        XCTAssertEqual(message, "node --version did not answer in 15 s")

        let stripe = await preflight.run(check: PreflightCheck(id: "stripe-auth", name: "Stripe"))
        guard case .warning(let warning) = stripe else { return XCTFail("\(stripe)") }
        XCTAssertEqual(warning, "stripe balance retrieve did not answer in 15 s — Stripe will be skipped")

        XCTAssertTrue(runner.calls.allSatisfy { $0.timeout == .seconds(15) }, "each check command has a timeout")
    }

    /// The wait for a container runtime that does not come up (120 s, a check
    /// every 2 s) runs on the clock of the preflight, so it takes no real time.
    func testTheDockerCheckWaitsOnTheClockOfThePreflight() async {
        let runner = FakeCommandRunner { call in
            call.command.hasPrefix("docker ps") ? FakeCommandRunner.failed() : FakeCommandRunner.ok()
        }
        let time = FakeClock()
        let preflight = PreflightRunner(shell: runner, clock: time.clock)

        let began = Date()
        let docker = await preflight.run(check: PreflightCheck(id: "docker", name: "Docker"))

        guard case .failed(let message, _) = docker else { return XCTFail("\(docker)") }
        XCTAssertTrue(message.hasSuffix("did not answer after 120 s — open it, then press Retry"), message)
        XCTAssertEqual(time.sleeps, Array(repeating: .seconds(2), count: 60))
        XCTAssertEqual(runner.commands.filter { $0.hasPrefix("docker ps") }.count, 61)
        XCTAssertEqual(runner.commands.filter { $0.hasPrefix("open -a") }.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(began), 10)
    }

    /// Negative control: a Node that answers passes, so the timeout branch is not the only path.
    func testAPreflightNodeCheckThatAnswersPasses() async {
        let preflight = PreflightRunner(shell: FakeCommandRunner { _ in FakeCommandRunner.ok("v22.11.0\n") })
        let node = await preflight.run(check: PreflightCheck(id: "node-version", name: "Node"))
        XCTAssertTrue(node.isPassed, "\(node)")
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
        XCTAssertEqual(ToolEnvironment.toolName(of: ["pnpm", "dev"]), "pnpm")
        XCTAssertNil(ToolEnvironment.toolName(of: ["./scripts/dev.sh"]))
        XCTAssertNil(ToolEnvironment.toolName(of: ["/bin/sh", "-c", "true"]))
        XCTAssertNil(ToolEnvironment.toolName(of: []))
    }
}
