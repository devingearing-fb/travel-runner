import XCTest
@testable import TravelRunner

/// The setup checks: the pnpm pin of the monorepo, and which results block the wizard.
@MainActor
final class EnvironmentCheckerTests: XCTestCase {
    // MARK: - pnpm pin

    func testThePinComesFromPackageManager() {
        let json = #"{ "name": "fb-travel-monolith", "packageManager": "pnpm@10.34.5+sha512.abc123" }"#

        XCTAssertEqual(EnvironmentChecker.pnpmPin(packageJSON: json), "10.34.5")
        XCTAssertEqual(EnvironmentChecker.pnpmPin(packageJSON: #"{ "packageManager": "pnpm@10.34.5" }"#), "10.34.5")
    }

    func testNoPinWithoutAPnpmPackageManager() {
        XCTAssertNil(EnvironmentChecker.pnpmPin(packageJSON: #"{ "name": "x" }"#))
        XCTAssertNil(EnvironmentChecker.pnpmPin(packageJSON: #"{ "packageManager": "yarn@4.1.0" }"#))
        XCTAssertNil(EnvironmentChecker.pnpmPin(packageJSON: #"{ "packageManager": "pnpm@latest" }"#))
        XCTAssertNil(EnvironmentChecker.pnpmPin(packageJSON: "not json"))
    }

    func testThePinIsReadFromTheMonorepo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EnvironmentCheckerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertNil(EnvironmentChecker.pnpmPin(monorepo: directory.path))

        try Data(#"{ "packageManager": "pnpm@10.34.5+sha512.abc" }"#.utf8)
            .write(to: directory.appendingPathComponent("package.json"))
        XCTAssertEqual(EnvironmentChecker.pnpmPin(monorepo: directory.path), "10.34.5")
    }

    func testTheVersionIsTheLastVersionLine() {
        XCTAssertEqual(EnvironmentChecker.toolVersion("10.34.5\n"), "10.34.5")
        XCTAssertEqual(EnvironmentChecker.toolVersion("v22.11.0\n"), "22.11.0")
        XCTAssertEqual(EnvironmentChecker.toolVersion("Update available! 10.1.0 → 12.0.0\n10.34.5\n"), "10.34.5")
        XCTAssertNil(EnvironmentChecker.toolVersion("command not found: pnpm\n"))
    }

    // MARK: - pnpm status

    func testThePinnedVersionPasses() {
        XCTAssertEqual(
            EnvironmentChecker.pnpmStatus(output: "10.34.5\n", ok: true, pin: "10.34.5"),
            .passing("v10.34.5 (pinned by the monorepo)")
        )
    }

    func testAnotherVersionOfThePinnedMajorPasses() {
        XCTAssertEqual(
            EnvironmentChecker.pnpmStatus(output: "10.20.0\n", ok: true, pin: "10.34.5"),
            .passing("v10.20.0 (the monorepo pins 10.34.5)")
        )
    }

    func testAnotherMajorFails() {
        XCTAssertEqual(
            EnvironmentChecker.pnpmStatus(output: "12.1.0\n", ok: true, pin: "10.34.5"),
            .failing("v12.1.0 — the monorepo pins 10.34.5")
        )
    }

    func testTheMajorOfThePinDecidesNotALiteralTen() {
        XCTAssertEqual(
            EnvironmentChecker.pnpmStatus(output: "12.1.0\n", ok: true, pin: "12.1.0"),
            .passing("v12.1.0 (pinned by the monorepo)")
        )
        XCTAssertEqual(
            EnvironmentChecker.pnpmStatus(output: "10.34.5\n", ok: true, pin: "12.1.0"),
            .failing("v10.34.5 — the monorepo pins 12.1.0")
        )
    }

    func testWithoutAPinTheDefaultMajorDecides() {
        XCTAssertEqual(EnvironmentChecker.pnpmStatus(output: "10.2.0\n", ok: true, pin: nil), .passing("v10.2.0"))
        XCTAssertEqual(EnvironmentChecker.pnpmStatus(output: "12.1.0\n", ok: true, pin: nil), .failing("v12.1.0 — need 10.x"))
    }

    func testNoPnpmFails() {
        let output = EnvironmentChecker.pnpmNotFoundMarker + "\n"

        XCTAssertEqual(EnvironmentChecker.pnpmStatus(output: output, ok: false, pin: "10.34.5"), .failing("Not installed"))
    }

    func testAPnpmThatGivesNoVersionIsNotCalledNotInstalled() {
        let withPin = "pnpm could not report its version in the monorepo (it may need to download pnpm 10.34.5) — check the network and re-run"
        let withoutPin = "pnpm could not report its version in the monorepo (it may need to download another version) — check the network and re-run"

        XCTAssertEqual(EnvironmentChecker.pnpmStatus(output: "", ok: false, pin: "10.34.5"), .failing(withPin))
        XCTAssertEqual(EnvironmentChecker.pnpmStatus(output: "no version here\n", ok: true, pin: "10.34.5"), .failing(withPin))
        XCTAssertEqual(EnvironmentChecker.pnpmStatus(output: "", ok: false, pin: nil), .failing(withoutPin))
    }

    func testAPrereleaseIsAVersion() {
        XCTAssertEqual(EnvironmentChecker.toolVersion("11.0.0-rc.1\n"), "11.0.0-rc.1")
        XCTAssertEqual(EnvironmentChecker.pnpmPin(packageJSON: #"{ "packageManager": "pnpm@11.0.0-rc.1+sha512.abc" }"#), "11.0.0-rc.1")
        XCTAssertEqual(
            EnvironmentChecker.pnpmStatus(output: "11.0.0-rc.1\n", ok: true, pin: "11.0.0-rc.1"),
            .passing("v11.0.0-rc.1 (pinned by the monorepo)")
        )
        XCTAssertEqual(
            EnvironmentChecker.pnpmStatus(output: "11.0.0-rc.1\n", ok: true, pin: "10.34.5"),
            .failing("v11.0.0-rc.1 — the monorepo pins 10.34.5")
        )
    }

    func testTheCheckSaysWhenThereIsNoPnpm() {
        let command = EnvironmentChecker.pnpmCheckCommand(monorepo: "/tmp/mono")

        XCTAssertTrue(command.hasPrefix("command -v pnpm >/dev/null 2>&1 || { echo '\(EnvironmentChecker.pnpmNotFoundMarker)'; exit 1; }; cd /tmp/mono "))
    }

    // MARK: - pnpm fix

    func testTheFixInstallsThePinNotTheNewestMajor() {
        let command = EnvironmentChecker.pnpmFixCommand(pin: "10.34.5", monorepo: "/tmp/mono")

        XCTAssertTrue(command.contains("corepack prepare pnpm@10.34.5 --activate"))
        XCTAssertTrue(command.contains("brew install pnpm@10 "))
        XCTAssertTrue(command.contains("npm install -g pnpm@10.34.5"))
        XCTAssertFalse(command.contains("brew install pnpm "))
    }

    func testTheFixWithoutAPinInstallsTheDefaultMajor() {
        let command = EnvironmentChecker.pnpmFixCommand(pin: nil, monorepo: "/tmp/mono")

        XCTAssertTrue(command.contains("corepack prepare pnpm@10 --activate"))
        XCTAssertTrue(command.hasSuffix("npm install -g pnpm@10"))
    }

    func testAStepOfTheFixCountsOnlyWhenPnpmThenHasThePinnedMajor() {
        let command = EnvironmentChecker.pnpmFixCommand(pin: "10.34.5", monorepo: "/tmp/my repo")
        let verify = "(cd '/tmp/my repo' 2>/dev/null; COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm --version 2>/dev/null | grep -q '^10\\.')"

        XCTAssertTrue(command.contains("corepack prepare pnpm@10.34.5 --activate && \(verify)) || "))
        XCTAssertTrue(command.contains("brew link --overwrite --force pnpm@10 && \(verify)) || "))
    }

    func testAfterTheFixAWrongVersionNamesThePnpmThatIsFirstOnThePath() {
        let recheck = CheckStatus.failing("v12.1.0 — the monorepo pins 10.34.5")
        let named = CheckStatus.failing(
            "v12.1.0 — the monorepo pins 10.34.5. Another pnpm is first on the PATH: /opt/homebrew/bin/pnpm — remove it, then re-check"
        )

        for failure in [nil, "Fix failed (exit 1): no"] {
            XCTAssertEqual(
                EnvironmentChecker.pnpmStatusAfterFix(recheck: recheck, failure: failure, firstOnPath: "/opt/homebrew/bin/pnpm"),
                named
            )
        }
        XCTAssertEqual(EnvironmentChecker.pnpmStatusAfterFix(recheck: recheck, failure: nil, firstOnPath: ""), recheck)
    }

    func testAfterTheFixTheOtherResultsStay() {
        let passing = CheckStatus.passing("v10.34.5 (pinned by the monorepo)")

        XCTAssertEqual(EnvironmentChecker.pnpmStatusAfterFix(recheck: passing, failure: nil, firstOnPath: "/usr/local/bin/pnpm"), passing)
        // A fix that failed and a pnpm that now passes: the row passes.
        XCTAssertEqual(EnvironmentChecker.pnpmStatusAfterFix(recheck: passing, failure: "Fix failed (exit 1)", firstOnPath: "/usr/local/bin/pnpm"), passing)
        XCTAssertEqual(
            EnvironmentChecker.pnpmStatusAfterFix(recheck: .failing("Not installed"), failure: "Fix failed (exit 1): EACCES", firstOnPath: ""),
            .failing("Fix failed (exit 1): EACCES")
        )
        XCTAssertEqual(
            EnvironmentChecker.pnpmStatusAfterFix(recheck: .failing("Not installed"), failure: nil, firstOnPath: ""),
            .failing("Not installed")
        )
    }

    func testTheCheckRunsInTheMonorepo() {
        let command = EnvironmentChecker.pnpmCheckCommand(monorepo: "/tmp/my repo")

        XCTAssertTrue(command.contains("; cd '/tmp/my repo' 2>/dev/null; "))
        XCTAssertTrue(command.hasSuffix("pnpm --version"))
    }

    // MARK: - Blockers

    private func check(_ id: String, required: Bool = true, _ status: CheckStatus) -> HealthCheck {
        let check = HealthCheck(id: id, name: id, section: .prerequisites, isRequired: required)
        check.status = status
        return check
    }

    func testAWarningDoesNotBlock() {
        let checks = [
            check("docker", .passing("OrbStack")),
            check("login-env", .warning("Exists but may be incomplete")),
            check("stripe-cli", required: false, .warning("Not installed — webhooks won't work")),
        ]

        XCTAssertTrue(EnvironmentChecker.blockers(in: checks).isEmpty)
    }

    func testAFailingRequiredCheckBlocks() {
        let checks = [
            check("docker", .passing("OrbStack")),
            check("pnpm", .failing("Not installed")),
            check("login-env", .warning("Exists but may be incomplete")),
        ]

        XCTAssertEqual(EnvironmentChecker.blockers(in: checks).map(\.id), ["pnpm"])
    }

    func testAFailingOptionalCheckDoesNotBlock() {
        let checks = [check("stream-modules", required: false, .failing("Fix failed — try manually"))]

        XCTAssertTrue(EnvironmentChecker.blockers(in: checks).isEmpty)
    }

    // MARK: - The buttons of the wizard

    func testAPendingOptionalCheckDoesNotHoldTheWizard() {
        let checks = [
            check("docker", .passing("OrbStack")),
            check("stripe-cli", required: false, .pending),
            check("hotel-data", required: false, .fixing),
        ]

        XCTAssertTrue(EnvironmentChecker.unresolved(in: checks).isEmpty)
    }

    func testAPendingRequiredCheckAsksBeforeItContinues() {
        let checks = [
            check("docker", .pending),
            check("pnpm", .fixing),
            check("node", .failing("v18.0.0 — need 22+")),
            check("login-env", .warning("Exists but may be incomplete")),
            check("stripe-cli", required: false, .failing("Not installed")),
        ]

        XCTAssertEqual(EnvironmentChecker.unresolved(in: checks).map(\.id), ["docker", "pnpm", "node"])
        // Not a blocker: only a result that fails is one.
        XCTAssertEqual(EnvironmentChecker.blockers(in: checks).map(\.id), ["node"])
    }

    func testTheCheckerUsesTheRuleForItsOwnChecks() {
        let checker = EnvironmentChecker(monorepoPath: "/nonexistent/mono", loginPath: "/nonexistent/login", streamServicesPath: "")
        checker.buildChecks()
        XCTAssertFalse(checker.canFinish, "all checks are pending")

        for check in checker.checks where check.isRequired { check.status = .passing("ok") }
        XCTAssertTrue(checker.canFinish, "the optional checks are still pending")
        XCTAssertTrue(checker.checks.contains { !$0.isRequired && $0.status == .pending })
    }

    func testACheckWithoutAResultSaysSo() {
        let docker = check("docker", .pending)
        let unknown = check("new-check", .fixing)

        XCTAssertEqual(
            EnvironmentChecker.impactLines(for: [docker, unknown]),
            ["docker (check not finished) — if it fails, the local database will not start", "new-check (check not finished)"]
        )
    }

    func testEachBlockerSaysWhatWillNotWork() {
        let pnpm = HealthCheck(id: "pnpm", name: "pnpm 10", section: .prerequisites)
        let unknown = HealthCheck(id: "new-check", name: "New check", section: .prerequisites)
        pnpm.status = .failing("Not installed")
        unknown.status = .failing("No")

        XCTAssertEqual(
            EnvironmentChecker.impactLines(for: [pnpm, unknown]),
            ["pnpm 10 — installs and both portals will not run", "New check"]
        )
    }

    func testEveryRequiredCheckHasAnImpact() {
        let checker = EnvironmentChecker(monorepoPath: "/nonexistent/mono", loginPath: "/nonexistent/login", streamServicesPath: "")
        checker.buildChecks()

        for check in checker.checks where check.isRequired {
            XCTAssertNotNil(EnvironmentChecker.impact(of: check.id), "\(check.id) has no impact text")
        }
    }

    // MARK: - Commands of the checks

    /// A checker whose commands go to `runner`. It has its own tool environment,
    /// so no test reads the shell of this Mac.
    private func makeChecker(
        _ runner: FakeCommandRunner, loginPath: String = "/nonexistent/login", clock: RunnerClock = .live
    ) -> EnvironmentChecker {
        let checker = EnvironmentChecker(
            monorepoPath: "/nonexistent/mono", loginPath: loginPath, streamServicesPath: "/nonexistent/stream",
            flavor: .standard, shell: runner, tools: ToolEnvironment(home: "/nonexistent/home"), clock: clock
        )
        checker.buildChecks()
        return checker
    }

    private func status(_ id: String, in checker: EnvironmentChecker) -> CheckStatus? {
        checker.checks.first { $0.id == id }?.status
    }

    /// "Re-check All" reads the shell of the user before the checks, so a tool
    /// that was installed a moment ago counts.
    func testRecheckAllReadsTheShellBeforeTheChecks() async {
        let runner = FakeCommandRunner()
        let checker = makeChecker(runner)

        await checker.recheckAll()

        XCTAssertEqual(runner.commands.first, ToolEnvironment.captureCommand)
        XCTAssertEqual(runner.commands.filter { $0 == ToolEnvironment.captureCommand }.count, 1)
        XCTAssertTrue(runner.commands.contains("node --version"), "the checks ran after the read")

        // Control: the first run of the checks does not read the shell.
        let plain = FakeCommandRunner()
        await makeChecker(plain).runAllChecks()
        XCTAssertFalse(plain.commands.contains(ToolEnvironment.captureCommand))
        XCTAssertTrue(plain.commands.contains("node --version"))
    }

    /// A check command that hangs is killed after 20 s. Its row must say that,
    /// not "not installed": the fix for a missing tool does not help a tool that hangs.
    func testACheckCommandThatTimesOutSaysSoOnItsRow() async {
        let runner = FakeCommandRunner { _ in FakeCommandRunner.timedOut }
        let checker = makeChecker(runner)

        await checker.runAllChecks()

        XCTAssertEqual(status("docker", in: checker), .failing("docker ps did not answer in 20 s"))
        XCTAssertEqual(status("node", in: checker), .failing("node --version did not answer in 20 s"))
        XCTAssertEqual(status("pnpm", in: checker), .failing("pnpm --version did not answer in 20 s"))
        XCTAssertEqual(status("registry-auth", in: checker), .failing("grep ~/.npmrc did not answer in 20 s"))
        // An optional check warns, so it does not block the wizard.
        XCTAssertEqual(status("stripe-cli", in: checker), .warning("which stripe did not answer in 20 s"))
        XCTAssertEqual(status("stripe-auth", in: checker), .warning("stripe balance retrieve did not answer in 20 s"))
        XCTAssertEqual(status("booking-env", in: checker), .warning("The check of the .env file did not answer in 20 s"))
        XCTAssertTrue(runner.calls.allSatisfy { $0.timeout == .seconds(20) }, "each check command has a timeout")
    }

    /// Control: a command that fails without a timeout keeps its own text.
    func testACheckCommandThatFailsKeepsItsOwnText() async {
        let checker = makeChecker(FakeCommandRunner { _ in FakeCommandRunner.failed() })

        await checker.runAllChecks()

        XCTAssertEqual(status("node", in: checker), .failing("Node.js not found"))
        XCTAssertEqual(status("stripe-cli", in: checker), .warning("Not installed — webhooks won't work"))
        XCTAssertEqual(status("stripe-auth", in: checker), .warning("Session invalid or expired — run: stripe login"))
        for check in checker.checks {
            if case .failing(let text) = check.status { XCTAssertFalse(text.contains("did not answer"), "\(check.id): \(text)") }
            if case .warning(let text) = check.status { XCTAssertFalse(text.contains("did not answer"), "\(check.id): \(text)") }
        }
    }

    func testTheAgentNodeCheckSaysWhenNodeDidNotAnswer() async {
        let checker = EnvironmentChecker(
            monorepoPath: "/nonexistent/mono", loginPath: "/nonexistent/login", streamServicesPath: "",
            flavor: .hackathon, shell: FakeCommandRunner { _ in FakeCommandRunner.timedOut },
            tools: ToolEnvironment(home: "/nonexistent/home")
        )
        checker.buildChecks()

        await checker.runAllChecks()

        XCTAssertEqual(status("agent-node", in: checker), .warning("node --version did not answer in 20 s"))
    }

    // MARK: - Fixes

    private nonisolated static let install = "cd /nonexistent/mono && pnpm install --frozen-lockfile"

    /// The output of a fix shows in the sheet, line by line, under its command.
    func testAFixShowsItsOutputInTheSheet() async throws {
        let runner = FakeCommandRunner { call in
            call.command == Self.install ? FakeCommandRunner.ok("Progress: resolved 10\nDone in 3s\n") : FakeCommandRunner.ok()
        }
        let checker = makeChecker(runner)

        await checker.fix("workspace-modules")

        let run = try XCTUnwrap(checker.activeFix)
        XCTAssertEqual(run.lines, ["$ \(Self.install)", "Progress: resolved 10", "Done in 3s"])
        XCTAssertEqual(run.state, .succeeded)
        XCTAssertNotNil(run.endedAt)
        XCTAssertEqual(run.action.copyCommand, Self.install)
        XCTAssertEqual(runner.calls.first { $0.command == Self.install }?.timeout, .seconds(15 * 60), "an install stops after 15 min")
        // The folder has no node_modules, so the check that runs after the fix still fails with its own text.
        XCTAssertEqual(status("workspace-modules", in: checker), .failing("Run pnpm install at the monorepo root"))

        checker.closeFixSheet()
        XCTAssertNil(checker.activeFix)
    }

    func testAFailedFixSaysTheExitCodeAndTheLastErrorLine() async throws {
        let output = (1...50).map { "line \($0)" }.joined(separator: "\n")
        let runner = FakeCommandRunner { call in
            call.command == Self.install
                ? CommandResult(exitCode: 2, stdout: output, stderr: "WARN deprecated\n\u{1b}[31mERR_PNPM_OUTDATED_LOCKFILE stale\u{1b}[39m\n\n")
                : FakeCommandRunner.ok()
        }
        let checker = makeChecker(runner)

        await checker.fix("workspace-modules")

        let text = "Fix failed (exit 2): ERR_PNPM_OUTDATED_LOCKFILE stale"
        XCTAssertEqual(status("workspace-modules", in: checker), .failing(text))
        let run = try XCTUnwrap(checker.activeFix)
        XCTAssertEqual(run.state, .failed(text))
        XCTAssertEqual(run.failureTail.count, 30)
        XCTAssertEqual(run.failureTail.last, "ERR_PNPM_OUTDATED_LOCKFILE stale", "the colour codes are gone")
    }

    func testARejectedRegistryTokenNamesTheAuthRow() async {
        let runner = FakeCommandRunner { call in
            call.command == Self.install
                ? CommandResult(exitCode: 1, stdout: " ERR_PNPM_FETCH_401  GET https://npm.pkg.github.com/@fastbreak-amateur%2Ffb-toolkit: Unauthorized - 401\n", stderr: "")
                : FakeCommandRunner.ok()
        }
        let checker = makeChecker(runner)

        await checker.fix("workspace-modules")

        XCTAssertEqual(
            status("workspace-modules", in: checker),
            .failing("GitHub Packages rejected your token — fix the 'GitHub Packages auth' row, then retry.")
        )
    }

    func testAFixThatTimesOutSaysSo() async {
        let runner = FakeCommandRunner { call in call.command == Self.install ? FakeCommandRunner.timedOut : FakeCommandRunner.ok() }
        let checker = makeChecker(runner)

        await checker.fix("workspace-modules")

        XCTAssertEqual(status("workspace-modules", in: checker), .failing("Fix stopped after 15 min: it did not finish"))
    }

    /// Cancel stops the command. The row then shows what the check finds, not a failure of the fix.
    func testCancelStopsTheFixAndTheCheckRunsAgain() async throws {
        let gate = Gate()
        let runner = FakeCommandRunner { call in
            guard call.command == Self.install else { return FakeCommandRunner.ok() }
            await gate.wait()
            return Task.isCancelled
                ? CommandResult(exitCode: -1, stdout: "", stderr: "Cancelled")
                : FakeCommandRunner.ok()
        }
        let checker = makeChecker(runner)

        let fix = Task { await checker.fix("workspace-modules") }
        while !runner.commands.contains(Self.install) { await Task.yield() }
        let run = try XCTUnwrap(checker.activeFix)
        XCTAssertTrue(run.isRunning)
        XCTAssertEqual(status("workspace-modules", in: checker), .fixing)

        // A second fix does not start while one runs.
        await checker.fix("login-modules")
        XCTAssertFalse(runner.commands.contains { $0.contains("npm install") && !$0.contains("pnpm") })
        // The sheet stays while the fix runs.
        checker.closeFixSheet()
        XCTAssertNotNil(checker.activeFix)

        run.cancel()
        await gate.open()
        await fix.value

        XCTAssertEqual(run.state, .cancelled)
        XCTAssertEqual(status("workspace-modules", in: checker), .failing("Run pnpm install at the monorepo root"))
    }

    /// `stripe login` asks questions, so it runs in Terminal. The runner checks again until it passes.
    func testStripeLoginRunsInTerminalAndTheRowWaitsForTheCheck() async {
        let balanceCalls = Counter()
        let runner = FakeCommandRunner { call in
            guard call.command.hasPrefix("stripe balance retrieve") else { return FakeCommandRunner.ok() }
            // Fails twice, then passes on the third poll.
            return balanceCalls.next() < 2 ? FakeCommandRunner.failed() : FakeCommandRunner.ok()
        }
        let fakeClock = FakeClock()
        let checker = makeChecker(runner, clock: fakeClock.clock)

        await checker.fix("stripe-auth")

        XCTAssertEqual(runner.commands.first, #"osascript -e 'tell application "Terminal" to do script "stripe login"'"#)
        XCTAssertEqual(checker.activeFix?.state, .succeeded)
        XCTAssertEqual(checker.activeFix?.action.copyCommand, "stripe login")
        XCTAssertEqual(status("stripe-auth", in: checker), .passing("Authenticated"))
        XCTAssertEqual(fakeClock.sleeps, [.seconds(3), .seconds(3), .seconds(3)])
    }

    func testStripeLoginStopsWaitingAfterThreeMinutes() async {
        let runner = FakeCommandRunner { call in
            call.command.hasPrefix("stripe balance retrieve") ? FakeCommandRunner.failed() : FakeCommandRunner.ok()
        }
        let fakeClock = FakeClock()
        let checker = makeChecker(runner, clock: fakeClock.clock)

        await checker.fix("stripe-auth")

        XCTAssertEqual(
            status("stripe-auth", in: checker),
            .failing("Not done after 3 min — finish `stripe login` in Terminal, then re-check")
        )
        XCTAssertEqual(fakeClock.uptime, .seconds(180))
    }

    /// The Node fix only says what to do: the runner does not install Node.
    func testTheNodeFixIsGuidance() async throws {
        let runner = FakeCommandRunner()
        let checker = makeChecker(runner)

        await checker.fix("node")

        let run = try XCTUnwrap(checker.activeFix)
        XCTAssertEqual(run.state, .guidance)
        XCTAssertEqual(run.lines, ["Install Node 22: `brew install node@22` or `nvm install 22`"])
        XCTAssertEqual(run.action.copyCommand, "brew install node@22")
        XCTAssertTrue(runner.commands.isEmpty, "nothing ran")
        XCTAssertEqual(status("node", in: checker), .pending, "the row is not touched")
    }

    func testNoFixResetsTheDatabase() {
        let checker = EnvironmentChecker(
            monorepoPath: "/nonexistent/mono", loginPath: "/nonexistent/login", streamServicesPath: "/nonexistent/stream",
            flavor: .hackathon, shell: FakeCommandRunner(), tools: ToolEnvironment(home: "/nonexistent/home")
        )
        checker.buildChecks()

        for check in checker.checks {
            guard let command = checker.fixAction(for: check.id)?.copyCommand else { continue }
            XCTAssertFalse(command.contains("reset"), "\(check.id): \(command)")
            XCTAssertFalse(command.contains("db:setup"), "\(check.id): \(command)")
        }
        // Each row with a fix button has a fix.
        for check in checker.checks where check.fixLabel != nil {
            XCTAssertNotNil(checker.fixAction(for: check.id), check.id)
        }
        XCTAssertEqual(checker.fixAction(for: "login-env"), .inApp)
    }

    // MARK: - Login .env.local

    private func temporaryFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("EnvironmentCheckerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The fix adds only the keys that are missing, keeps the values that are there,
    /// and copies the file first.
    func testTheLoginEnvFixAddsOnlyMissingKeysAfterACopy() throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(".env.local").path
        let original = "NEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321\nexport ALLOW_LOCALHOST_REDIRECTS=false\n# EMAIL_CONFIRMATION_REQUIRED=true\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        let report = try EnvironmentChecker.addMissingLoginEnvKeys(at: path, now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(report.added, ["NEXT_PUBLIC_SITE_URL", "NEXT_PUBLIC_AMATEUR_LOCAL_UNIVERSAL_LOGIN_URL", "EMAIL_CONFIRMATION_REQUIRED"])
        XCTAssertEqual(report.kept, ["ALLOW_LOCALHOST_REDIRECTS"])
        let backup = try XCTUnwrap(report.backup)
        XCTAssertTrue(backup.hasPrefix(".env.local.bak-"), backup)
        XCTAssertEqual(try String(contentsOfFile: directory.appendingPathComponent(backup).path, encoding: .utf8), original)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix(original), "the lines that were there stay")
        XCTAssertTrue(content.contains("NEXT_PUBLIC_SITE_URL=http://localhost:3000"))
        XCTAssertTrue(content.contains("\nEMAIL_CONFIRMATION_REQUIRED=false"))
        XCTAssertFalse(content.contains("ALLOW_LOCALHOST_REDIRECTS=true"), "a value that is there is kept")

        // A second run changes nothing and makes no copy.
        let again = try EnvironmentChecker.addMissingLoginEnvKeys(at: path, now: Date(timeIntervalSince1970: 1_800_000_100))
        XCTAssertNil(again.backup)
        XCTAssertEqual(again.added, [])
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), content)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.filter { $0.hasPrefix(".env.local.bak-") }.count, 1)
    }

    func testTheLoginEnvFixCreatesAMissingFileWithoutACopy() throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(".env.local").path

        let report = try EnvironmentChecker.addMissingLoginEnvKeys(at: path, now: Date())

        XCTAssertNil(report.backup)
        XCTAssertEqual(report.added.count, EnvironmentChecker.loginEnvTemplate.count)
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains("ALLOW_LOCALHOST_REDIRECTS=true"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [".env.local"])
    }

    func testTheLoginEnvFixShowsWhatItChanged() async throws {
        let directory = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try "CUSTOM=1\n".write(to: directory.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        let checker = makeChecker(FakeCommandRunner(), loginPath: directory.path)

        await checker.fix("login-env")

        let run = try XCTUnwrap(checker.activeFix)
        XCTAssertEqual(run.state, .succeeded)
        XCTAssertTrue(run.lines.first?.hasPrefix("Saved a copy: .env.local.bak-") == true, "\(run.lines)")
        XCTAssertEqual(run.lines.last, "Added: NEXT_PUBLIC_SITE_URL, NEXT_PUBLIC_AMATEUR_LOCAL_UNIVERSAL_LOGIN_URL, ALLOW_LOCALHOST_REDIRECTS, EMAIL_CONFIRMATION_REQUIRED")
        XCTAssertEqual(status("login-env", in: checker), .passing("Configured"))
        XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent(".env.local"), encoding: .utf8).hasPrefix("CUSTOM=1\n"))
    }

    // MARK: - Fix texts

    func testTheFailureTextUsesTheOutputWhenTheErrorOutputIsEmpty() {
        let result = CommandResult(exitCode: 127, stdout: "first\nzsh: command not found: pnpm\n", stderr: "\n")

        XCTAssertEqual(
            EnvironmentChecker.fixFailedText(for: "pnpm", result: result, timeout: .seconds(60)),
            "Fix failed (exit 127): zsh: command not found: pnpm"
        )
        XCTAssertEqual(
            EnvironmentChecker.fixFailedText(for: "pnpm", result: CommandResult(exitCode: 1, stdout: "", stderr: ""), timeout: .seconds(60)),
            "Fix failed (exit 1)"
        )
    }

    func testTheElapsedTimeHasMinutesAndSeconds() {
        XCTAssertEqual(FixRun.elapsedText(seconds: 0), "0:00")
        XCTAssertEqual(FixRun.elapsedText(seconds: 42), "0:42")
        XCTAssertEqual(FixRun.elapsedText(seconds: 725), "12:05")
        XCTAssertEqual(EnvironmentChecker.durationText(.seconds(180)), "3 min")
        XCTAssertEqual(EnvironmentChecker.durationText(.seconds(20)), "20 s")
    }
}

/// Counts the calls of a fake command.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// The count before this call.
    func next() -> Int {
        lock.lock()
        defer { count += 1; lock.unlock() }
        return count
    }
}
