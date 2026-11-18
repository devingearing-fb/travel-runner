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
        XCTAssertEqual(StripeOffReason.notAuthenticated(mode).actions, [.importSharedEnv])
        XCTAssertFalse(StripeOffReason.notAuthenticated(mode).headline.contains("stripe login"))
        XCTAssertFalse(StripeLauncher.unknownExitHint(mode).contains("stripe login"))
        // Control: in login mode a 401 is an expired session.
        let login = StripeMode.login(reason: StripeLauncher.noKeyReason)
        XCTAssertEqual(StripeLauncher.exitCause(known: CrashCause.stripeSessionExpired, mode: login), CrashCause.stripeSessionExpired)
        XCTAssertEqual(StripeOffReason.notAuthenticated(login), .loginExpired)
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
        let checker = makeChecker(FakeCommandRunner { _ in FakeCommandRunner.failed(stderr: "Request failed, status=401") })

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

    // MARK: - S3: the state machine

    func testTheExitClassifierReadsTheMarkersOfTheLog() {
        let rows: [(lines: [String], expected: StripeExitClassifier.Kind)] = [
            (["Authorization failed, status=401, body={...}"], .auth),
            (["Request failed, status=401"], .auth),
            (["error: api_key_expired"], .auth),
            (["dial tcp: lookup api.stripe.com: no such host"], .network),
            (["Get \"https://api.stripe.com\": dial tcp 1.2.3.4:443: connect: network is unreachable"], .network),
            (["lookup api.stripe.com: no such host"], .network),
            (["Post \"https://api.stripe.com/v1/balance\": net/http: TLS handshake timeout"], .network),
            (["dial: i/o timeout"], .network),
            (["read tcp 10.0.0.2:51234->34.1.2.3:443: read: connection reset by peer"], .network),
            (["panic: runtime error: invalid memory address", "goroutine 1 [running]:"], .cliCrash),
            (["Ready! Your webhook signing secret is whsec_x", "some other line"], .unknown),
            ([], .unknown),
        ]
        for row in rows {
            XCTAssertEqual(StripeExitClassifier.classify(logTail: row.lines), row.expected, "\(row.lines)")
        }
        // A 401 wins over the DNS error that the CLI prints after it.
        XCTAssertEqual(StripeExitClassifier.classify(logTail: ["status=401", "dial tcp: no such host"]), .auth)
        // A marker that left the window does not count.
        let old = ["status=401"] + Array(repeating: "line", count: StripeExitClassifier.window)
        XCTAssertEqual(StripeExitClassifier.classify(logTail: old), .unknown)
    }

    func testTheAuthCheckTellsARejectedKeyFromNoNetwork() {
        let mode = StripeMode.testKey(source: "apps/booking-portal/.env")
        func classify(_ result: CommandResult) -> StripeAvailability {
            StripeAvailability.classify(authCheck: result, mode: mode)
        }
        XCTAssertEqual(classify(FakeCommandRunner.ok("{}")), .ok(mode))
        XCTAssertEqual(classify(FakeCommandRunner.timedOut), .offline)
        XCTAssertEqual(classify(FakeCommandRunner.failed(stderr: "Request failed, status=401, body=...")), .notAuthenticated)
        XCTAssertEqual(classify(FakeCommandRunner.failed(stderr: "dial tcp: lookup api.stripe.com: no such host")), .offline)
        XCTAssertEqual(classify(CommandResult(exitCode: 1, stdout: "Invalid API Key provided: sk_test_****abcd", stderr: "")), .notAuthenticated)
        // Only an auth line blames the key. A failure that says nothing, a 5xx or a
        // crash of the CLI could not be checked.
        XCTAssertEqual(classify(FakeCommandRunner.failed()), .unverified)
        XCTAssertEqual(classify(FakeCommandRunner.failed(stderr: "Request failed, status=503, body=upstream error")), .unverified)
        XCTAssertEqual(classify(FakeCommandRunner.failed(stderr: "panic: runtime error: index out of range")), .unverified)
        XCTAssertEqual(classify(FakeCommandRunner.failed(stderr: "net/http: TLS handshake timeout")), .offline)
        XCTAssertEqual(StripeOffReason.unavailable(.unverified, mode: mode), .unverified)
        XCTAssertFalse(StripeOffReason.unverified.headline.contains("STRIPE_SECRET_KEY"))
        XCTAssertTrue(StripeOffReason.unverified.retries)
    }

    func testTheCLIProbeSaysWhyStripeCannotRun() async {
        let key = StripeLauncher.resolve(values: [(file: "apps/booking-portal/.env", value: testKey)])

        let missing = FakeCommandRunner { $0.command == StripeLauncher.installedCommand ? FakeCommandRunner.failed() : FakeCommandRunner.ok() }
        let notInstalled = await StripeCLI(shell: missing).availability(key)
        XCTAssertEqual(notInstalled, .notInstalled)
        XCTAssertEqual(missing.commands, [StripeLauncher.installedCommand], "no auth check without the CLI")

        // A hung PATH lookup is not the network.
        let hung = FakeCommandRunner { $0.command == StripeLauncher.installedCommand ? FakeCommandRunner.timedOut : FakeCommandRunner.ok() }
        let unchecked = await StripeCLI(shell: hung).availability(key)
        XCTAssertEqual(unchecked, .unverified)
        XCTAssertEqual(hung.commands, [StripeLauncher.installedCommand])

        let offline = FakeCommandRunner { call in
            call.command == StripeLauncher.authCheckCommand
                ? FakeCommandRunner.failed(stderr: "dial tcp: lookup api.stripe.com: no such host") : FakeCommandRunner.ok()
        }
        let noNetwork = await StripeCLI(shell: offline, timeout: .seconds(7)).availability(key)
        XCTAssertEqual(noNetwork, .offline)
        XCTAssertEqual(offline.calls.last?.environment, ["STRIPE_API_KEY": testKey], "the key is in the env of the check")
        XCTAssertTrue(offline.calls.allSatisfy { $0.timeout == .seconds(7) }, "each command has a timeout")
        XCTAssertFalse(offline.calls.contains { $0.command.contains(testKey) })

        let fine = FakeCommandRunner()
        let ok = await StripeCLI(shell: fine).availability(key)
        XCTAssertEqual(ok, .ok(key.mode))
        XCTAssertFalse(fine.commands.contains(StripeLauncher.versionCommand), "no version check without a minimum")
    }

    func testAnOldCLIIsOutdatedWhenAMinimumIsSet() async {
        let key = StripeLauncher.resolve(values: [])
        let shell = FakeCommandRunner { call in
            call.command == StripeLauncher.versionCommand ? FakeCommandRunner.ok("stripe version 1.13.2\n") : FakeCommandRunner.ok()
        }
        let old = await StripeCLI(shell: shell, minimumVersion: StripeVersion([1, 19])).availability(key)
        XCTAssertEqual(old, .outdated(version: "1.13.2"))
        XCTAssertFalse(shell.commands.contains(StripeLauncher.authCheckCommand))
        // Control: a new enough CLI goes on to the auth check.
        let new = await StripeCLI(shell: FakeCommandRunner { call in
            call.command == StripeLauncher.versionCommand ? FakeCommandRunner.ok("stripe version 1.21.8\n") : FakeCommandRunner.ok()
        }, minimumVersion: StripeVersion([1, 19])).availability(key)
        XCTAssertEqual(new, .ok(key.mode))
        XCTAssertEqual(StripeOffReason.outdated(version: "1.13.2").actions, [.updateStripe])
    }

    func testStripeVersionsCompareByNumber() {
        XCTAssertEqual(StripeVersion(parsing: "stripe version 1.21.8")?.description, "1.21.8")
        XCTAssertEqual(StripeVersion(parsing: "stripe version v1.9")?.parts, [1, 9])
        XCTAssertNil(StripeVersion(parsing: "stripe version master"))
        XCTAssertLessThan(StripeVersion([1, 9, 9]), StripeVersion([1, 19]))
        XCTAssertLessThan(StripeVersion([1, 19]), StripeVersion([1, 19, 1]))
        XCTAssertFalse(StripeVersion([1, 19, 0]) < StripeVersion([1, 19]))
    }

    func testTheNetworkRetryWaits5sThenTwiceAsLongUpTo60s() {
        let policy = StripeRetryPolicy()
        XCTAssertEqual((0..<7).map { policy.networkDelay(attempt: $0) }, [
            .seconds(5), .seconds(10), .seconds(20), .seconds(40), .seconds(60), .seconds(60), .seconds(60),
        ])
        XCTAssertEqual(policy.networkDelay(attempt: 1000), .seconds(60))
        XCTAssertEqual(policy.crashRestarts, 2)
    }

    func testTheProbeAnswerIsKeptFor60s() {
        let key = StripeLauncher.resolve(values: [(file: "apps/booking-portal/.env", value: testKey)])
        let other = StripeLauncher.resolve(values: [])
        let start = Date(timeIntervalSince1970: 1_000_000)
        var cache = StripeAvailabilityCache()
        XCTAssertNil(cache.value(for: key, now: start))

        cache.store(.offline, for: key, at: start)

        XCTAssertEqual(cache.value(for: key, now: start.addingTimeInterval(59)), .offline)
        XCTAssertNil(cache.value(for: key, now: start.addingTimeInterval(60)), "too old")
        XCTAssertNil(cache.value(for: other, now: start.addingTimeInterval(1)), "another key")
        cache.invalidate()
        XCTAssertNil(cache.value(for: key, now: start.addingTimeInterval(1)))
    }

    /// The row texts of the plan, one per cause.
    func testTheRowSaysWhyStripeIsOff() {
        let rows: [(reason: StripeOffReason, text: String, actions: [RecoveryAction], retries: Bool)] = [
            (.notInstalled, "Stripe CLI not installed — webhooks are off. Run: brew install stripe/stripe-cli/stripe", [.installStripe], false),
            (.loginExpired, "Stripe CLI login expired — webhooks are off.", [.stripeLogin], false),
            (.keyRejected(source: "apps/booking-portal/.env"),
             "Stripe rejected STRIPE_SECRET_KEY from apps/booking-portal/.env — import a current .env.", [.importSharedEnv], false),
            (.offline, "No network — Stripe reconnects when the network is back.", [], true),
            (.afterWake, "Reconnecting Stripe after wake…", [], true),
            (.unverified, "Stripe could not be checked — the runner tries again.", [], true),
            (.didNotConnect(seconds: 25), "Stripe did not connect within 25s — webhooks are off.", [.startService], false),
            (.crashedTwice, "Stripe CLI crashed twice (see log) — webhooks are off.", [.startService, .openLog], false),
        ]
        for row in rows {
            XCTAssertEqual(row.reason.headline, row.text)
            XCTAssertEqual(row.reason.actions, row.actions, row.text)
            XCTAssertEqual(row.reason.kind, row.retries ? .retrying : .optionalOff, row.text)
        }
        let mode = StripeMode.login(reason: StripeLauncher.noKeyReason)
        XCTAssertNil(StripeOffReason.unavailable(.ok(mode), mode: mode))
        XCTAssertEqual(StripeOffReason.unavailable(.offline, mode: mode), .offline)
        XCTAssertEqual(StripeOffReason.unavailable(.notInstalled, mode: mode), .notInstalled)
    }

    func testStripeGetsAShortConnectTimeout() throws {
        let stripe = try XCTUnwrap(
            ServiceCatalog.services(paths: RepoPaths(monorepo: monorepo.path), flavor: .standard).first { $0.id == "stripe" }
        )
        XCTAssertEqual(stripe.probe?.timeout, 25)
    }
}
