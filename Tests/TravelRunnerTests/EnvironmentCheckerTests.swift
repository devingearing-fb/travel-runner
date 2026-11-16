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

        for fixSucceeded in [true, false] {
            XCTAssertEqual(
                EnvironmentChecker.pnpmStatusAfterFix(recheck: recheck, fixSucceeded: fixSucceeded, firstOnPath: "/opt/homebrew/bin/pnpm"),
                named
            )
        }
        XCTAssertEqual(EnvironmentChecker.pnpmStatusAfterFix(recheck: recheck, fixSucceeded: true, firstOnPath: ""), recheck)
    }

    func testAfterTheFixTheOtherResultsStay() {
        let passing = CheckStatus.passing("v10.34.5 (pinned by the monorepo)")

        XCTAssertEqual(EnvironmentChecker.pnpmStatusAfterFix(recheck: passing, fixSucceeded: true, firstOnPath: "/usr/local/bin/pnpm"), passing)
        // A fix that failed and a pnpm that now passes: the row passes.
        XCTAssertEqual(EnvironmentChecker.pnpmStatusAfterFix(recheck: passing, fixSucceeded: false, firstOnPath: "/usr/local/bin/pnpm"), passing)
        XCTAssertEqual(
            EnvironmentChecker.pnpmStatusAfterFix(recheck: .failing("Not installed"), fixSucceeded: false, firstOnPath: ""),
            .failing("Fix failed — try manually")
        )
        XCTAssertEqual(
            EnvironmentChecker.pnpmStatusAfterFix(recheck: .failing("Not installed"), fixSucceeded: true, firstOnPath: ""),
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
    private func makeChecker(_ runner: FakeCommandRunner) -> EnvironmentChecker {
        let checker = EnvironmentChecker(
            monorepoPath: "/nonexistent/mono", loginPath: "/nonexistent/login", streamServicesPath: "/nonexistent/stream",
            flavor: .standard, shell: runner, tools: ToolEnvironment(home: "/nonexistent/home")
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

    /// A check command that hangs is killed after 15 s. Its row must say that,
    /// not "not installed": the fix for a missing tool does not help a tool that hangs.
    func testACheckCommandThatTimesOutSaysSoOnItsRow() async {
        let runner = FakeCommandRunner { _ in FakeCommandRunner.timedOut }
        let checker = makeChecker(runner)

        await checker.runAllChecks()

        XCTAssertEqual(status("docker", in: checker), .failing("docker ps did not answer in 15 s"))
        XCTAssertEqual(status("node", in: checker), .failing("node --version did not answer in 15 s"))
        XCTAssertEqual(status("pnpm", in: checker), .failing("pnpm --version did not answer in 15 s"))
        XCTAssertEqual(status("registry-auth", in: checker), .failing("grep ~/.npmrc did not answer in 15 s"))
        // An optional check warns, so it does not block the wizard.
        XCTAssertEqual(status("stripe-cli", in: checker), .warning("which stripe did not answer in 15 s"))
        XCTAssertEqual(status("stripe-auth", in: checker), .warning("stripe balance retrieve did not answer in 15 s"))
        XCTAssertEqual(status("booking-env", in: checker), .warning("The check of the .env file did not answer in 15 s"))
        XCTAssertTrue(runner.calls.allSatisfy { $0.timeout == .seconds(15) }, "each check command has a timeout")
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

        XCTAssertEqual(status("agent-node", in: checker), .warning("node --version did not answer in 15 s"))
    }
}
