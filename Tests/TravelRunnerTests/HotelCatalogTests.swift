import Foundation
import XCTest
@testable import TravelRunner

/// D3: the runner side of "preflight before anything is destroyed". The scripts check
/// the hotel source; the runner shows the result, offers the way out, checks the
/// backend baseline remote and looks at the hotel catalog after Start.
@MainActor
final class HotelCatalogTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("HotelCatalogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, to relative: String, in root: URL? = nil) throws {
        let url = (root ?? dir).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - The banner of a stopped reset

    func testAHotelExitCodeOfAStepBeforeTheResetGivesTheBanner() {
        let line = "Hotels cannot be downloaded yet: Dev Supabase rejected the signing key (HTTP 401). Nothing was reset."
        // check-prerequisites prints the whole line, after the line of a missing tool.
        XCTAssertEqual(
            HotelCatalog.sourceFailure(
                stepID: "check-prerequisites", exitCode: 11, message: "Missing: Docker is not running. \(line)", resetRan: false
            )?.text,
            line
        )
        // fetch-hotels gives the reason only.
        XCTAssertEqual(
            HotelCatalog.sourceFailure(
                stepID: "fetch-hotels", exitCode: 12, message: "Cannot reach dev Supabase (x.supabase.co) — check network or VPN",
                resetRan: false
            ),
            HotelCatalog.SourceNotice(
                text: "Hotels cannot be downloaded yet: Cannot reach dev Supabase (x.supabase.co) — check network or VPN. Nothing was reset.",
                beforeReset: true
            )
        )
        // Negative controls: a tool failure (exit 1), a later step, and a run whose reset passed.
        XCTAssertNil(HotelCatalog.sourceFailure(stepID: "check-prerequisites", exitCode: 1, message: line, resetRan: false))
        XCTAssertNil(HotelCatalog.sourceFailure(stepID: "verify-data", exitCode: 11, message: line, resetRan: false))
        XCTAssertNil(HotelCatalog.sourceFailure(stepID: "fetch-hotels", exitCode: 13, message: line, resetRan: true))
        XCTAssertNil(HotelCatalog.sourceFailure(stepID: "fetch-hotels", exitCode: nil, message: line, resetRan: false))
    }

    /// load-hotels downloads the dump when none is cached, so it exits 10 to 13 too.
    /// The banner offers the import, and does not say that nothing was reset.
    func testALoadThatCannotGetTheHotelsOffersOnlyTheImport() {
        let reason = "No dev credentials: apps/booking-portal/.env is missing AMATEUR_SUPABASE_URL"
        for resetRan in [false, true] {
            XCTAssertEqual(
                HotelCatalog.sourceFailure(stepID: "load-hotels", exitCode: 10, message: reason, resetRan: resetRan),
                HotelCatalog.SourceNotice(text: "Hotels cannot be downloaded yet: \(reason).", beforeReset: false)
            )
        }
        // Negative control: a load that fails for another reason (exit 1) is no hotel banner.
        XCTAssertNil(HotelCatalog.sourceFailure(stepID: "load-hotels", exitCode: 1, message: reason, resetRan: true))
    }

    /// The confirmation of "Reset without hotels…" is the reset text, with the line
    /// about another checkout's data when there is one.
    func testTheResetWithoutHotelsConfirmationNamesAnotherCheckout() {
        let other = DbResetPolicy.otherCheckoutLine(
            DbResetPolicy.BuiltFrom(checkoutPath: "/elsewhere/mono", branch: "dev"),
            current: DbResetPolicy.Checkout(path: "/here/mono"), project: "fb-travel"
        )
        let text = HotelCatalog.withoutHotelsConfirmation(otherCheckout: other)
        XCTAssertTrue(text.hasPrefix(DbResetPolicy.resetConfirmationBody), text)
        XCTAssertTrue(text.contains("This database was last built from /elsewhere/mono (dev)."), text)
        // Negative control: this checkout built it, so there is no such line.
        XCTAssertNil(DbResetPolicy.otherCheckoutLine(
            DbResetPolicy.BuiltFrom(checkoutPath: "/here/mono"), current: DbResetPolicy.Checkout(path: "/here/mono"), project: "fb-travel"
        ))
    }

    // MARK: - The catalog after Start

    func testAnEmptyCatalogGivesTheBannerUnlessTheHotelsWereLeftOut() {
        XCTAssertEqual(
            HotelCatalog.emptyNotice(count: 12, hotelsSkipped: false)?.text,
            "Hotel catalog is empty (12 hotels) — hotel search will return nothing."
        )
        XCTAssertEqual(HotelCatalog.emptyNotice(count: 0, hotelsSkipped: nil)?.count, 0)
        XCTAssertEqual(HotelCatalog.emptyNotice(count: 99_999, hotelsSkipped: nil)?.text,
                       "Hotel catalog is empty (99,999 hotels) — hotel search will return nothing.")
        // Negative controls: a full catalog, a reset without hotels, an unread count.
        XCTAssertNil(HotelCatalog.emptyNotice(count: 209_823, hotelsSkipped: false))
        XCTAssertNil(HotelCatalog.emptyNotice(count: 0, hotelsSkipped: true))
        XCTAssertNil(HotelCatalog.emptyNotice(count: nil, hotelsSkipped: false))
    }

    func testTheCountAndTheSeedStateAreReadFromTheQuery() {
        XCTAssertEqual(HotelCatalog.count(DbQueryResult(exitCode: 0, stdout: "notice\n12", stderr: "")), 12)
        XCTAssertNil(HotelCatalog.count(DbQueryResult(exitCode: 1, stdout: "", stderr: "relation does not exist")))
        func skipped(_ json: String) -> Bool? { DbResetPolicy.BuiltFrom.parse(json)?.hotelsSkipped }
        XCTAssertEqual(skipped(#"{"scenario_id":"standard","hotels_skipped":true}"#), true)
        XCTAssertEqual(skipped(#"{"hotels_skipped":false}"#), false)
        // An older table, and a null: not known.
        XCTAssertNil(skipped(#"{"scenario_id":"standard"}"#))
        XCTAssertNil(skipped(#"{"hotels_skipped":null}"#))
    }

    // MARK: - The Environment Check rows

    func testTheDevKeysCountOnlyWhenOneFileHasAllThree() throws {
        try write("AMATEUR_SUPABASE_URL=https://x\nAMATEUR_SUPABASE_ANON_KEY=a\n", to: "apps/booking-portal/.env")
        XCTAssertFalse(HotelCatalog.devKeysPresent(monorepo: dir.path))
        try write("AMATEUR_SUPABASE_URL=https://x\nAMATEUR_SUPABASE_ANON_KEY=a\nAMATEUR_SUPABASE_SIGNING_KEY=\"s\"\n",
                  to: "apps/partner-portal/.env")
        XCTAssertTrue(HotelCatalog.devKeysPresent(monorepo: dir.path))
        // A blank value is no key.
        try write("AMATEUR_SUPABASE_URL=https://x\nAMATEUR_SUPABASE_ANON_KEY=a\nAMATEUR_SUPABASE_SIGNING_KEY=\n",
                  to: "apps/partner-portal/.env")
        XCTAssertFalse(HotelCatalog.devKeysPresent(monorepo: dir.path))
    }

    func testTheSourceRowPassesOnACacheOrOnTheKeys() {
        let detail = "Cached — 209,823 rows, 2026-08-11"
        XCTAssertEqual(
            HotelCatalog.cachedDetail(verifyOutput: "  log\n##db:health:pass:\(detail)\n", succeeded: true), detail
        )
        XCTAssertNil(HotelCatalog.cachedDetail(verifyOutput: "##db:health:fail:No cached hotel dump", succeeded: false))
        XCTAssertEqual(HotelCatalog.sourceStatus(cached: detail, keysPresent: false), .passing(detail))
        XCTAssertEqual(HotelCatalog.sourceStatus(cached: nil, keysPresent: true), .passing(HotelCatalog.keysOnlyText))
        XCTAssertEqual(HotelCatalog.sourceStatus(cached: nil, keysPresent: false), .failing(HotelCatalog.noSourceText))
    }

    func testTheBookingEnvFailsOnlyWhileNoDumpIsCachedAndTheKeysAreMissing() {
        let missing = CheckStatus.warning("Missing — import the shared file. Local mode runs without it; remote mode needs it")
        XCTAssertEqual(
            EnvironmentChecker.bookingEnvStatus(missing, required: true, hotelKeysPresent: false),
            .failing("Missing — import the shared file. Local mode runs without it; remote mode needs it. Without it the first reset cannot download the hotels")
        )
        // Controls: a cached dump, or the keys in place, keep the warning.
        XCTAssertEqual(EnvironmentChecker.bookingEnvStatus(missing, required: false, hotelKeysPresent: false), missing)
        XCTAssertEqual(EnvironmentChecker.bookingEnvStatus(missing, required: true, hotelKeysPresent: true), missing)
        XCTAssertEqual(EnvironmentChecker.impact(of: "booking-env"), "the first reset cannot download the hotels")
    }

    /// A checkout with the hotel scripts. The fake shell answers the env check and the
    /// dump check; `cached` is the pass line of a valid dump, or nil.
    private func checker(cached: String?, bookingEnvExists: Bool) throws -> (EnvironmentChecker, FakeCommandRunner) {
        try write("// fetch-hotels\n", to: "scripts/db/fetch-hotels.mjs")
        let dump = dir.appendingPathComponent("app/hotels/travel_organizations.sql")
        if cached != nil { try write("INSERT INTO fb_travel.travel_organizations (id) VALUES (1);\n", to: "app/hotels/travel_organizations.sql") }
        let report = #"{"apps":[{"app":"booking","exists":\#(bookingEnvExists),"shared":12,"missing":[],"blank":[],"shadowed":[],"ok":\#(bookingEnvExists)}]}"#
        let runner = FakeCommandRunner { call in
            if call.command.contains("fetch-hotels.mjs") {
                guard let cached else { return CommandResult(exitCode: 1, stdout: "##db:health:fail:No cached hotel dump\n", stderr: "") }
                return FakeCommandRunner.ok("##db:health:pass:\(cached)\n")
            }
            if call.command.contains("env-check.mjs") { return FakeCommandRunner.ok(report) }
            return FakeCommandRunner.ok()
        }
        let checker = EnvironmentChecker(
            monorepoPath: dir.path, loginPath: "/nonexistent/login", streamServicesPath: "/nonexistent/stream",
            flavor: .standard, shell: runner, tools: ToolEnvironment(home: "/nonexistent/home")
        )
        checker.hotelDumpPath = dump.path
        checker.buildChecks()
        return (checker, runner)
    }

    private func row(_ id: String, _ checker: EnvironmentChecker) throws -> HealthCheck {
        try XCTUnwrap(checker.checks.first { $0.id == id })
    }

    func testWithoutADumpOrTheSharedEnvTheBookingEnvBlocksTheWizard() async throws {
        let (checker, _) = try checker(cached: nil, bookingEnvExists: false)

        await checker.runAllChecks()

        XCTAssertEqual(try row("hotel-data", checker).status, .failing(HotelCatalog.noSourceText))
        let booking = try row("booking-env", checker)
        XCTAssertTrue(booking.isRequired)
        XCTAssertTrue(checker.blockers.contains { $0.id == "booking-env" }, "\(booking.status)")
    }

    /// Control: a valid cached dump passes the row, and the shared env is not needed.
    func testACachedDumpPassesTheRowAndTheBookingEnvStaysOptional() async throws {
        let detail = "Cached — 209,823 rows, 2026-08-11"
        let (checker, runner) = try checker(cached: detail, bookingEnvExists: false)

        await checker.runAllChecks()

        XCTAssertEqual(try row("hotel-data", checker).status, .passing(detail))
        let booking = try row("booking-env", checker)
        XCTAssertFalse(booking.isRequired)
        XCTAssertFalse(checker.blockers.contains { $0.id == "booking-env" })
        // The dump is read once for both rows, with the dump path the app uses.
        let reads = runner.commands.filter { $0.contains("fetch-hotels.mjs") }
        XCTAssertEqual(reads.count, 1, "\(reads)")
        XCTAssertTrue(reads[0].hasPrefix("TRAVEL_HOTEL_DUMP=\(ShellQuote.quote(checker.hotelDumpPath)) "), reads[0])
        XCTAssertTrue(reads[0].hasSuffix(" --verify"), reads[0])
    }

    // MARK: - Backend baseline

    func testTheBaselineIsPickedAsTheScriptPicksIt() throws {
        let root = dir.appendingPathComponent("fb-travel-monolith")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(
            BackendBaseline.source(root: root.path, environment: [:]),
            .managedClone(root.appendingPathComponent(".backend-baseline").path, cloned: false)
        )
        try write("", to: ".backend-baseline/.git/HEAD", in: root)
        XCTAssertEqual(
            BackendBaseline.source(root: root.path, environment: [:]),
            .managedClone(root.appendingPathComponent(".backend-baseline").path, cloned: true)
        )
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("fb-amateur-backend/supabase/migrations"), withIntermediateDirectories: true
        )
        XCTAssertEqual(
            BackendBaseline.source(root: root.path, environment: [:]),
            .sibling(dir.appendingPathComponent("fb-amateur-backend").path)
        )
        XCTAssertEqual(
            BackendBaseline.source(root: root.path, environment: ["FB_AMATEUR_BACKEND_DIR": "/own/backend"]),
            .environment("/own/backend")
        )
        XCTAssertFalse(BackendBaseline.Source.sibling("/x").needsRemote)
        XCTAssertTrue(BackendBaseline.Source.managedClone("/x", cloned: true).needsRemote)
    }

    func testTheAccessCheckReadsTheRemoteOfTheScriptWithNoPrompt() {
        let script = "ROOT_DIR=x\nBACKEND_REPO=\"https://example.invalid/org/fb-amateur-backend.git\"\nTYPES_OUT=y\n"
        let url = BackendBaseline.repositoryURL(script: script)
        XCTAssertEqual(url, "https://example.invalid/org/fb-amateur-backend.git")
        XCTAssertNil(BackendBaseline.repositoryURL(script: "ROOT_DIR=x\n"))
        XCTAssertEqual(
            BackendBaseline.accessCommand(url: "https://example.invalid/a b.git"),
            "GIT_TERMINAL_PROMPT=0 git ls-remote --quiet 'https://example.invalid/a b.git' HEAD"
        )
        XCTAssertEqual(BackendBaseline.accessTimeout, .seconds(15))
    }

    func testTheSiblingRowNamesItsBranchAndHowFarBehindItIs() {
        let behind = BackendBaseline.siblingState("dev\n3\n")
        XCTAssertEqual(behind, BackendBaseline.SiblingState(branch: "dev", behind: 3))
        XCTAssertEqual(BackendBaseline.siblingStatus(behind), .warning("Sibling is 3 commits behind — use managed clone"))
        XCTAssertEqual(BackendBaseline.siblingStatus(BackendBaseline.siblingState("dev\n0\n")), .passing("Sibling checkout (dev)"))
        // No upstream: the count is not known, and the row passes.
        XCTAssertEqual(BackendBaseline.siblingStatus(BackendBaseline.siblingState("feature\n-\n")), .passing("Sibling checkout (feature)"))
    }

    func testWithoutAccessAFirstCloneFailsAndAClonedBaselineWarns() {
        XCTAssertEqual(EnvironmentChecker.backendAccessStatus(succeeded: false, cloned: false), .failing(BackendBaseline.noAccessText))
        XCTAssertEqual(EnvironmentChecker.backendAccessStatus(succeeded: false, cloned: true), .warning(BackendBaseline.noAccessText))
        XCTAssertEqual(
            BackendBaseline.noAccessText,
            "No access to fb-amateur-backend over HTTPS. Run `gh auth setup-git`, or choose an existing checkout."
        )
        if case .passing = EnvironmentChecker.backendAccessStatus(succeeded: true, cloned: false) {} else {
            XCTFail("a remote that answers passes")
        }
    }

    /// Findings "backend baseline clone not prechecked": the clone ran from a GUI with no
    /// terminal, and git waited for a password or failed after the start began.
    func testThePreflightAsksTheRemoteBeforeAFirstClone() async throws {
        let root = dir.appendingPathComponent("fb-travel-monolith")
        try write("BACKEND_REPO=\"https://example.invalid/fb-amateur-backend.git\"\n", to: "scripts/local-db.sh", in: root)
        let supabase = ServiceDefinition(
            id: "supabase", name: "Supabase", cmd: ["pnpm", "db:start"], cwd: root.path, probe: nil,
            type: .daemon, restart: .never, dependsOn: [], env: nil, phase: "ground", reuseIfRunning: nil
        )
        let shell = FakeCommandRunner { call in
            call.command.contains("ls-remote") ? FakeCommandRunner.failed(128, stderr: "terminal prompts disabled") : FakeCommandRunner.ok()
        }
        let runner = PreflightRunner(shell: shell)

        let check = try XCTUnwrap(runner.allChecks(for: [supabase]).first { $0.id == "backend-baseline" })
        XCTAssertFalse(runner.readOnlyChecks(for: [supabase]).contains { $0.id == "backend-baseline" })
        let result = await runner.run(check: check)

        guard case .failed(let message, _) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(message, BackendBaseline.noAccessText)
        XCTAssertEqual(
            shell.calls.map(\.command),
            [BackendBaseline.environmentCommand, BackendBaseline.accessCommand(url: "https://example.invalid/fb-amateur-backend.git")]
        )
        XCTAssertEqual(shell.calls.last?.timeout, .seconds(15))

        // A clone in place starts without the remote: the check only warns.
        try write("", to: ".backend-baseline/.git/HEAD", in: root)
        guard case .warning = await runner.run(check: check) else { return XCTFail("a cloned baseline warns") }

        // Negative control: a sibling checkout needs no remote, and nothing is asked.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("fb-amateur-backend/supabase/migrations"), withIntermediateDirectories: true
        )
        let asks = shell.commands.filter { $0.contains("ls-remote") }.count
        let sibling = await runner.run(check: check)
        XCTAssertTrue(sibling.isPassed, "\(sibling)")
        XCTAssertEqual(shell.commands.filter { $0.contains("ls-remote") }.count, asks)
    }

    private func supabase(root: URL) -> ServiceDefinition {
        ServiceDefinition(
            id: "supabase", name: "Supabase", cmd: ["pnpm", "db:start"], cwd: root.path, probe: nil,
            type: .daemon, restart: .never, dependsOn: [], env: nil, phase: "ground", reuseIfRunning: nil
        )
    }

    /// The script runs in a login shell, which can set FB_AMATEUR_BACKEND_DIR that the
    /// runner (opened from Finder) does not have. Then nothing clones, and the remote is
    /// not asked.
    func testThePreflightTakesTheBackendDirOfTheLoginShell() async throws {
        let root = dir.appendingPathComponent("fb-travel-monolith")
        try write("BACKEND_REPO=\"https://example.invalid/fb-amateur-backend.git\"\n", to: "scripts/local-db.sh", in: root)
        var backendDir = "/own/fb-amateur-backend"
        let shell = FakeCommandRunner { call in
            if call.command == BackendBaseline.environmentCommand {
                return FakeCommandRunner.ok("profile says hello\nFB_AMATEUR_BACKEND_DIR=\(backendDir)\n")
            }
            return call.command.contains("ls-remote") ? FakeCommandRunner.failed(128, stderr: "terminal prompts disabled") : FakeCommandRunner.ok()
        }
        let runner = PreflightRunner(shell: shell)
        let check = try XCTUnwrap(runner.allChecks(for: [supabase(root: root)]).first { $0.id == "backend-baseline" })

        let result = await runner.run(check: check)

        XCTAssertTrue(result.isPassed, "\(result)")
        XCTAssertFalse(shell.commands.contains { $0.contains("ls-remote") }, "\(shell.commands)")

        // Negative control: a login shell without the variable falls back to the clone, and asks.
        backendDir = ""
        let clone = await runner.run(check: check)
        XCTAssertTrue(clone.isFailed, "\(clone)")
        XCTAssertTrue(shell.commands.contains { $0.contains("ls-remote") })
    }

    /// With the Supabase workspace in place, `db:start` builds nothing and clones
    /// nothing: no access only warns.
    func testThePreflightLetsAStartWithAWorkspaceRunWithoutTheRemote() async throws {
        let root = dir.appendingPathComponent("fb-travel-monolith")
        try write("BACKEND_REPO=\"https://example.invalid/fb-amateur-backend.git\"\n", to: "scripts/local-db.sh", in: root)
        let shell = FakeCommandRunner { call in
            call.command.contains("ls-remote") ? FakeCommandRunner.failed(128, stderr: "terminal prompts disabled") : FakeCommandRunner.ok()
        }
        let runner = PreflightRunner(shell: shell)
        let check = try XCTUnwrap(runner.allChecks(for: [supabase(root: root)]).first { $0.id == "backend-baseline" })
        let first = await runner.run(check: check)
        XCTAssertTrue(first.isFailed, "control: no workspace and no clone fails")

        try write("[api]\n", to: ".supabase-workspace/supabase/config.toml", in: root)
        let result = await runner.run(check: check)

        guard case .warning(let message) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(message, BackendBaseline.noAccessText)
    }

    func testTheLoginShellValueIsReadAfterTheMarker() {
        XCTAssertEqual(BackendBaseline.environmentValue("noise\nFB_AMATEUR_BACKEND_DIR=/a b/c\n"), "/a b/c")
        XCTAssertNil(BackendBaseline.environmentValue("FB_AMATEUR_BACKEND_DIR=\n"))
        XCTAssertNil(BackendBaseline.environmentValue("FB_AMATEUR_BACKEND_DIR is not a line of the marker"))
        XCTAssertEqual(BackendBaseline.environmentCommand, #"printf 'FB_AMATEUR_BACKEND_DIR=%s\n' "${FB_AMATEUR_BACKEND_DIR:-}""#)
    }

    func testAFolderWithoutTheDbScriptHasNoBaselineCheck() {
        let service = ServiceDefinition(
            id: "supabase", name: "Supabase", cmd: ["sleep", "1"], cwd: dir.path, probe: nil,
            type: .daemon, restart: .never, dependsOn: [], env: nil, phase: "ground", reuseIfRunning: nil
        )
        XCTAssertFalse(PreflightRunner(shell: FakeCommandRunner()).allChecks(for: [service]).contains { $0.id == "backend-baseline" })
    }

    func testSupabaseStartsWithNoGitPrompt() throws {
        let paths = RepoPaths(monorepo: "/x/mono", universalLogin: "/x/login", streamServices: "/x/stream", loadTest: nil)
        let supabase = try XCTUnwrap(ServiceCatalog.services(paths: paths, flavor: .standard).first { $0.id == "supabase" })
        XCTAssertEqual(supabase.env?["GIT_TERMINAL_PROMPT"], "0")
    }
}
