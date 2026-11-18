import Foundation
import XCTest
@testable import TravelRunner

/// S1: the Stripe CLI runs on the test key of the booking portal, and falls back to
/// the login without one. The keys here are made up; no test runs the Stripe CLI.
@MainActor
final class StripeSupportTests: XCTestCase {
    private let testKey = "sk_test_madeUpForTheTests123"
    private var monorepo: URL!
    private var booking: URL { monorepo.appendingPathComponent("apps/booking-portal") }

    override func setUp() async throws {
        monorepo = FileManager.default.temporaryDirectory.appendingPathComponent("StripeSupportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: booking, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: monorepo)
    }

    private func write(_ file: String, _ content: String) throws {
        try content.write(to: booking.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    // MARK: - Mode

    func testATestKeyInTheSharedEnvIsUsedAsProcessEnv() throws {
        try write(".env", "OTHER=1\nSTRIPE_SECRET_KEY=\(testKey)\n")

        let resolution = StripeLauncher.resolve(bookingPortal: booking.path)

        XCTAssertEqual(resolution.mode, .testKey(source: "apps/booking-portal/.env"))
        XCTAssertEqual(resolution.environment, ["STRIPE_API_KEY": testKey])
        XCTAssertEqual(resolution.mode.rowText, "Test key from apps/booking-portal/.env")
    }

    /// Next.js reads .env.local over .env. The listener must use the key the portal uses.
    func testAKeyInEnvLocalWinsOverTheSharedEnv() throws {
        let localKey = "sk_test_localOverride456"
        try write(".env", "STRIPE_SECRET_KEY=\(testKey)\n")
        try write(".env.local", "STRIPE_SECRET_KEY=\"\(localKey)\"\n")

        let resolution = StripeLauncher.resolve(bookingPortal: booking.path)

        XCTAssertEqual(resolution.mode, .testKey(source: "apps/booking-portal/.env.local"))
        XCTAssertEqual(resolution.environment, ["STRIPE_API_KEY": localKey])
    }

    func testAnEmptyValueInEnvLocalDoesNotHideTheSharedKey() throws {
        try write(".env", "STRIPE_SECRET_KEY=\(testKey)\n")
        try write(".env.local", "STRIPE_SECRET_KEY=\n")

        XCTAssertEqual(StripeLauncher.resolve(bookingPortal: booking.path).mode, .testKey(source: "apps/booking-portal/.env"))
    }

    /// The monolith's `.env.example` has `STRIPE_SECRET_KEY=  # shared`. dotenv drops
    /// the comment; the runner must read the same key as the portal.
    func testAnInlineCommentIsNotPartOfTheKey() throws {
        for line in ["STRIPE_SECRET_KEY=\(testKey)  # shared", "STRIPE_SECRET_KEY=\"\(testKey)\" # shared"] {
            try write(".env", line + "\n")

            let resolution = StripeLauncher.resolve(bookingPortal: booking.path)

            XCTAssertEqual(resolution.mode, .testKey(source: "apps/booking-portal/.env"), line)
            XCTAssertEqual(resolution.environment, ["STRIPE_API_KEY": testKey], line)
        }
    }

    /// A `.env.local` copied from `.env.example` has no key, only a comment.
    func testACommentOnlyValueInEnvLocalDoesNotHideTheSharedKey() throws {
        try write(".env", "STRIPE_SECRET_KEY=\(testKey)\n")
        try write(".env.local", "STRIPE_SECRET_KEY=  # shared\n")

        let resolution = StripeLauncher.resolve(bookingPortal: booking.path)

        XCTAssertEqual(resolution.mode, .testKey(source: "apps/booking-portal/.env"))
        XCTAssertEqual(resolution.environment, ["STRIPE_API_KEY": testKey])
    }

    /// dotenv takes the last line of a key.
    func testTheLastAssignmentOfTheKeyWins() throws {
        let later = "sk_test_laterLine789"
        try write(".env", "STRIPE_SECRET_KEY=\(testKey)\nSTRIPE_SECRET_KEY=\(later)\n")

        XCTAssertEqual(StripeLauncher.resolve(bookingPortal: booking.path).environment, ["STRIPE_API_KEY": later])
    }

    func testWithoutAKeyStripeUsesTheLogin() {
        let resolution = StripeLauncher.resolve(bookingPortal: booking.path)

        XCTAssertEqual(resolution.mode, .login(reason: StripeLauncher.noKeyReason))
        XCTAssertTrue(resolution.environment.isEmpty)
        XCTAssertEqual(resolution.mode.rowText, "Your stripe login")
        XCTAssertEqual(StripeLauncher.resolve(bookingPortal: nil).mode, .login(reason: StripeLauncher.noKeyReason))
    }

    /// Never a live key: the listener would forward real events.
    func testALiveKeyIsNeverUsed() throws {
        try write(".env", "STRIPE_SECRET_KEY=sk_live_madeUpLiveKey789\n")

        let resolution = StripeLauncher.resolve(bookingPortal: booking.path)

        XCTAssertTrue(resolution.environment.isEmpty, "a live key must not reach the process")
        guard case .login(let reason) = resolution.mode else { return XCTFail("\(resolution.mode)") }
        XCTAssertTrue(reason.contains("a live key"), reason)
        XCTAssertFalse(reason.contains("sk_live_madeUp"), "the reason never shows the key")
    }

    func testOnlyASecretTestKeyCounts() {
        for key in ["pk_test_publishable", "rk_test_restricted", "whsec_abc", "sk_test"] {
            let resolution = StripeLauncher.resolve(values: [(file: "apps/booking-portal/.env", value: key)])
            XCTAssertFalse(resolution.mode.isTestKey, key)
            XCTAssertTrue(resolution.environment.isEmpty, key)
        }
        // Control: the same call with a test key gives test-key mode.
        XCTAssertTrue(StripeLauncher.resolve(values: [(file: "apps/booking-portal/.env", value: testKey)]).mode.isTestKey)
    }

    /// A log line, a ticket or a toast that prints the value shows no key.
    func testTheTextOfAResolutionNeverShowsTheKey() {
        let resolution = StripeLauncher.resolve(values: [(file: "apps/booking-portal/.env", value: testKey)])
        for text in ["\(resolution)", String(reflecting: resolution), resolution.mode.logLine, resolution.mode.rowText] {
            XCTAssertFalse(text.contains(testKey), text)
        }
    }

    // MARK: - Command and definition

    func testTheCommandSkipsTheUpdateCheckAndForwardsToIPv4() throws {
        let command = StripeLauncher.command
        XCTAssertEqual(Array(command.prefix(2)), ["stripe", "listen"])
        XCTAssertTrue(command.contains("--skip-update"))
        let target = try XCTUnwrap(command.firstIndex(of: "--forward-to")).advanced(by: 1)
        XCTAssertEqual(command[target], "http://127.0.0.1:3002/api/webhooks/stripe")
        XCTAssertFalse(command.joined(separator: " ").contains("localhost"))

        let services = ServiceCatalog.services(paths: RepoPaths(monorepo: monorepo.path), flavor: .standard)
        XCTAssertEqual(services.first { $0.id == "stripe" }?.cmd, command, "the catalog uses the launcher's command")
    }

    func testTheKeyGoesToTheProcessEnvAndNeverToTheCommand() throws {
        let stripe = try XCTUnwrap(
            ServiceCatalog.services(paths: RepoPaths(monorepo: monorepo.path), flavor: .standard).first { $0.id == "stripe" }
        )
        let keyed = StripeLauncher.definition(
            stripe, resolution: StripeLauncher.resolve(values: [(file: "apps/booking-portal/.env", value: testKey)])
        )

        XCTAssertEqual(keyed.env?["STRIPE_API_KEY"], testKey)
        XCTAssertEqual(keyed.cmd, stripe.cmd)
        XCTAssertFalse(keyed.cmd.joined(separator: " ").contains(testKey))
        XCTAssertNil(stripe.env, "the catalog's definition keeps no key")

        // Control: login mode adds nothing.
        let login = StripeLauncher.definition(stripe, resolution: StripeLauncher.resolve(values: []))
        XCTAssertNil(login.env)
    }

    // MARK: - Cleanup

    /// A listener that the runner before S1 left has the old command; the cleanup kills it too.
    func testTheCleanupAlsoKillsTheListenerOfTheOldCommand() {
        XCTAssertEqual(StripeLauncher.stalePatterns(for: StripeLauncher.command), [
            PortOwner.commandPattern(for: StripeLauncher.command),
            "stripe listen --forward-to http://localhost:3002/api/webhooks/stripe",
        ])
        // Control: a command of a test or a config gets only its own pattern.
        let other = ["stripe", "listen", "--forward-to", "http://127.0.0.1:9/hook"]
        XCTAssertEqual(StripeLauncher.stalePatterns(for: other), [PortOwner.commandPattern(for: other)])
    }

    // MARK: - Causes

    func testA401InTestKeyModeSaysTheKeyWasRejected() {
        let mode = StripeMode.testKey(source: "apps/booking-portal/.env")
        XCTAssertEqual(
            StripeLauncher.exitCause(known: CrashCause.stripeSessionExpired, mode: mode),
            "Stripe rejected STRIPE_SECRET_KEY from apps/booking-portal/.env — import a current .env."
        )
        XCTAssertEqual(StripeLauncher.exitCause(known: CrashCause.noNetwork, mode: mode), CrashCause.noNetwork)
        XCTAssertFalse(StripeLauncher.unavailableCause(mode).contains("stripe login"))
        XCTAssertFalse(StripeLauncher.unknownExitHint(mode).contains("stripe login"))
        // Control: in login mode a 401 is an expired session.
        let login = StripeMode.login(reason: StripeLauncher.noKeyReason)
        XCTAssertEqual(StripeLauncher.exitCause(known: CrashCause.stripeSessionExpired, mode: login), CrashCause.stripeSessionExpired)
        XCTAssertTrue(StripeLauncher.unavailableCause(login).contains("stripe login"))
    }

    // MARK: - Setup checks

    private func makeChecker(_ runner: FakeCommandRunner, clock: RunnerClock = FakeClock().clock) -> EnvironmentChecker {
        let checker = EnvironmentChecker(
            monorepoPath: monorepo.path, loginPath: "/nonexistent/login", streamServicesPath: "/nonexistent/stream",
            flavor: .standard, shell: runner, tools: ToolEnvironment(home: "/nonexistent/home"),
            clock: clock
        )
        checker.buildChecks()
        return checker
    }

    private func status(_ id: String, in checker: EnvironmentChecker) -> CheckStatus? {
        checker.checks.first { $0.id == id }?.status
    }

    /// With a test key the row asks Stripe with that key, as `stripe listen` gets it,
    /// not with the login. The key is in the environment, never in the command.
    func testTheAuthRowAsksStripeWithTheTestKeyNotTheLogin() async throws {
        try write(".env", "STRIPE_SECRET_KEY=\(testKey)\n")
        let runner = FakeCommandRunner()
        let checker = makeChecker(runner)

        await checker.runAllChecks()

        XCTAssertEqual(status("stripe-auth", in: checker), .passing("Stripe accepts the test key from apps/booking-portal/.env"))
        let asks = runner.calls.filter { $0.command.contains("balance") }
        XCTAssertEqual(asks.map(\.command), [StripeLauncher.keyCheckCommand])
        XCTAssertEqual(asks.first?.environment, [StripeLauncher.apiKeyVariable: testKey])
        XCTAssertFalse(runner.calls.contains { $0.command.contains(testKey) })

        // Without the CLI the key is not asked, and the row says so.
        let noCLI = FakeCommandRunner { _ in FakeCommandRunner.failed() }
        let other = makeChecker(noCLI)
        await other.runAllChecks()
        XCTAssertFalse(noCLI.commands.contains { $0.contains("balance") })
        guard case .warning(let text)? = status("stripe-auth", in: other) else { return XCTFail() }
        XCTAssertTrue(text.hasPrefix("The test key from apps/booking-portal/.env is not checked"), text)
    }

    func testTheAuthRowWithALiveKeyAsksForTheLoginAndSaysWhy() async throws {
        try write(".env", "STRIPE_SECRET_KEY=sk_live_madeUpLiveKey789\n")
        let checker = makeChecker(FakeCommandRunner { _ in FakeCommandRunner.failed() })

        await checker.runAllChecks()

        guard case .warning(let text) = status("stripe-auth", in: checker) else {
            return XCTFail("\(String(describing: status("stripe-auth", in: checker)))")
        }
        XCTAssertTrue(text.contains("stripe login") && text.contains("a live key"), text)
    }

    func testTheInstallFixRunsHomebrew() async {
        let runner = FakeCommandRunner()
        let checker = makeChecker(runner)
        XCTAssertEqual(checker.checks.first { $0.id == "stripe-cli" }?.fixLabel, "brew install stripe/stripe-cli/stripe")

        await checker.fix("stripe-cli")

        XCTAssertTrue(runner.commands.contains("brew install stripe/stripe-cli/stripe"), "\(runner.commands)")
        XCTAssertEqual(status("stripe-cli", in: checker), .passing("Found"))
    }

    /// The fix opened Terminal and returned false: it never worked. It now opens a
    /// script in Terminal, which needs no Automation permission, and waits for the CLI.
    func testTheLoginFixRunsStripeLoginInTerminalAndWaitsForIt() async throws {
        let runner = FakeCommandRunner()
        let checker = makeChecker(runner)

        await checker.fix("stripe-auth")

        let commands = runner.commands
        XCTAssertFalse(commands.contains { $0.contains("osascript") }, "\(commands)")
        let installed = commands.firstIndex(of: StripeLauncher.installedCommand)
        let open = commands.firstIndex(of: EnvironmentChecker.terminalCommand("stripe login"))
        XCTAssertNotNil(open, "\(commands)")
        if let installed, let open { XCTAssertLessThan(installed, open) }
        let poll = commands.lastIndex(of: StripeLauncher.authCheckCommand)
        XCTAssertNotNil(poll)
        if let open, let poll { XCTAssertLessThan(open, poll) }
        XCTAssertEqual(status("stripe-auth", in: checker), .passing("Authenticated (your stripe login)"))
    }

    func testTheLoginFixWithoutTheCLISaysToInstallIt() async {
        let runner = FakeCommandRunner { _ in FakeCommandRunner.failed() }
        let checker = makeChecker(runner)

        await checker.fix("stripe-auth")

        XCTAssertEqual(status("stripe-auth", in: checker), .failing(
            "The Stripe CLI is not installed — install it with: brew install stripe/stripe-cli/stripe, then log in"
        ))
        XCTAssertFalse(runner.commands.contains { $0.contains("open -a Terminal") }, "Terminal is not opened")
    }

    func testALoginFixThatCannotOpenTerminalSaysSo() async {
        let checker = makeChecker(FakeCommandRunner { call in
            if call.command == StripeLauncher.installedCommand { return FakeCommandRunner.ok() }
            return call.command.contains("open -a Terminal")
                ? FakeCommandRunner.failed(stderr: "Unable to find application named 'Terminal'\n")
                : FakeCommandRunner.failed()
        })

        await checker.fix("stripe-auth")

        XCTAssertEqual(status("stripe-auth", in: checker), .failing(
            "Fix failed (exit 1): Unable to find application named 'Terminal'"
        ))
        XCTAssertEqual(checker.activeFix?.state, .failed("Fix failed (exit 1): Unable to find application named 'Terminal'"))
    }

    // MARK: - Preflight

    private func preflightStatus(_ runner: FakeCommandRunner) async -> PreflightResult {
        let portal = ServiceDefinition(
            id: "travel-portal", name: nil, cmd: ["pnpm", "dev"], cwd: booking.path, probe: nil, type: nil,
            restart: nil, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        let preflight = PreflightRunner(shell: runner)
        let check = try! XCTUnwrap(preflight.allChecks(for: [portal]).first { $0.id == "stripe-auth" })
        return await preflight.run(check: check)
    }

    func testPreflightChecksTheTestKeyThroughTheEnvironment() async throws {
        try write(".env", "STRIPE_SECRET_KEY=\(testKey)\n")
        let runner = FakeCommandRunner()

        let result = await preflightStatus(runner)

        guard case .passed(let detail) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(detail, "Test key from apps/booking-portal/.env")
        let auth = try XCTUnwrap(runner.calls.first { $0.command == StripeLauncher.authCheckCommand })
        XCTAssertEqual(auth.environment, ["STRIPE_API_KEY": testKey])
        XCTAssertFalse(runner.calls.contains { $0.command.contains(testKey) })
    }

    func testPreflightWithARejectedTestKeyDoesNotAskForALogin() async throws {
        try write(".env", "STRIPE_SECRET_KEY=\(testKey)\n")
        let runner = FakeCommandRunner { call in
            call.command == StripeLauncher.authCheckCommand ? FakeCommandRunner.failed() : FakeCommandRunner.ok()
        }

        let result = await preflightStatus(runner)

        guard case .warning(let message) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(message.contains("STRIPE_SECRET_KEY from apps/booking-portal/.env"), message)
        XCTAssertFalse(message.contains("stripe login"), message)
    }

    func testPreflightWithoutAKeyChecksTheLogin() async {
        let runner = FakeCommandRunner()

        let result = await preflightStatus(runner)

        guard case .passed(let detail) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(detail, "Authenticated")
        XCTAssertEqual(runner.calls.first { $0.command == StripeLauncher.authCheckCommand }?.environment, [:])
    }
}
