import Foundation
import XCTest
@testable import TravelRunner

final class SharedEnvFilesTests: XCTestCase {
    private func report(exists: Bool = true, shared: Int = 26, missing: [String] = [], blank: [String] = [], shadowed: [String] = []) -> SharedEnvFiles.AppReport {
        SharedEnvFiles.AppReport(
            app: "booking", exists: exists, shared: shared, missing: missing, blank: blank, shadowed: shadowed,
            ok: exists && missing.isEmpty && blank.isEmpty && shadowed.isEmpty
        )
    }

    func testDecodeSkipsShellNoiseAndPicksTheApp() {
        let output = """
        some login banner
        {"version":1,"ok":false,"apps":[
          {"app":"partner","dir":"apps/partner-portal","envFile":"/x","exists":false,"shared":25,"missing":["A"],"blank":[],"shadowed":[],"ok":false},
          {"app":"booking","dir":"apps/booking-portal","envFile":"/y","exists":true,"shared":26,"missing":[],"blank":[],"shadowed":[],"ok":true}
        ]}
        """
        XCTAssertEqual(SharedEnvFiles.decode(output, app: .booking), report())
        XCTAssertEqual(SharedEnvFiles.decode(output, app: .partner)?.exists, false)
        XCTAssertNil(SharedEnvFiles.decode("node: not found", app: .booking))
    }

    func testCommandQuotesPaths() {
        XCTAssertEqual(
            SharedEnvFiles.command(monorepo: "/a b/mono", app: .partner, file: "/tmp/it's.env"),
            ShellQuote.join(["node", "/a b/mono/scripts/env-check.mjs", "--json", "--app", "partner", "--file", "/tmp/it's.env"])
        )
    }

    func testStatus() {
        guard case .passing("All 26 shared keys") = SharedEnvFiles.status(report()) else { return XCTFail() }
        guard case .warning(let missingFile) = SharedEnvFiles.status(report(exists: false)) else { return XCTFail() }
        XCTAssertTrue(missingFile.hasPrefix("Missing"))
        guard case .warning(let stale) = SharedEnvFiles.status(report(missing: ["A", "B", "C", "D"])) else { return XCTFail() }
        XCTAssertEqual(stale, "Out of date: 4 of 26 shared keys missing (A, B, C +1 more) — import a fresh copy")
        guard case .warning(let hidden) = SharedEnvFiles.status(report(shadowed: ["STRIPE_SECRET_KEY"])) else { return XCTFail() }
        XCTAssertTrue(hidden.contains("STRIPE_SECRET_KEY"))
        guard case .warning(let noScript) = SharedEnvFiles.status(nil) else { return XCTFail() }
        XCTAssertTrue(noScript.contains(SharedEnvFiles.script))
    }

    func testImportPromptRefusesAFileWithNoSharedKeys() {
        let prompt = SharedEnvFiles.importPrompt(report(missing: Array(repeating: "K", count: 26)), app: .booking, replacing: false)
        XCTAssertFalse(prompt.acceptable)
        XCTAssertTrue(prompt.message.contains("other app's file"))
    }

    func testImportPromptSummarizesAPartialFile() {
        let prompt = SharedEnvFiles.importPrompt(report(missing: ["LITEAPI_API_KEY"]), app: .booking, replacing: true)
        XCTAssertTrue(prompt.acceptable)
        XCTAssertEqual(
            prompt.message,
            "It sets 25 of the 26 shared keys. Missing: LITEAPI_API_KEY. It replaces the current apps/booking-portal/.env, after a copy to .env.bak-<date>."
        )
    }

    /// The output that the monolith script gave for a file with two keys, one of them
    /// a shared booking key. Recorded in the snapshot; the next test runs the script.
    func testTheRecordedOutputOfTheMonolithScript() throws {
        let output = try String(
            contentsOf: MonolithCheckout.snapshot.appendingPathComponent("recorded/env-check-booking.json"), encoding: .utf8
        )
        let parsed = try XCTUnwrap(SharedEnvFiles.decode(output, app: .booking))
        XCTAssertTrue(parsed.exists)
        XCTAssertFalse(parsed.ok)
        XCTAssertEqual(parsed.shared - parsed.missing.count, 1, "only LITEAPI_API_KEY is a shared booking key")
        XCTAssertNil(SharedEnvFiles.decode(output, app: .partner))
        let prompt = SharedEnvFiles.importPrompt(parsed, app: .booking, replacing: false)
        XCTAssertTrue(prompt.acceptable)
        XCTAssertTrue(prompt.message.hasPrefix("It sets 1 of the \(parsed.shared) shared keys."), prompt.message)
    }

    /// The real monolith script. It runs node in a login shell, so only with TR_INTEGRATION=1.
    func testAgainstTheMonolithScript() throws {
        try MonolithCheckout.requireIntegration()
        let monorepo = try MonolithCheckout.root().path
        let candidate = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).env")
        try "LITEAPI_API_KEY=x\nSTATSIG_SERVER_KEY=y\n".write(to: candidate, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: candidate) }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", SharedEnvFiles.command(monorepo: monorepo, app: .booking, file: candidate.path)]
        process.standardOutput = pipe
        try process.run()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        let parsed = try XCTUnwrap(SharedEnvFiles.decode(output, app: .booking))
        XCTAssertTrue(parsed.exists)
        XCTAssertFalse(parsed.ok)
        XCTAssertEqual(parsed.shared - parsed.missing.count, 1, "only LITEAPI_API_KEY is a shared booking key")
    }

    // MARK: - P3: import, Doppler pull, key validation, permissions

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SharedEnvFilesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ text: String, to relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func mode(_ path: String) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    private let now = Date(timeIntervalSince1970: 1_794_825_000) // 2026-11-16 09:50 UTC

    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    func testAnImportOverAFileKeepsABackupFirstBothMode0600() throws {
        let dir = try tempDir()
        let target = dir.appendingPathComponent(".env").path

        // Control: a first import has nothing to keep.
        XCTAssertNil(try SharedEnvFiles.install(Data("A=1\n".utf8), at: target, now: now))
        XCTAssertEqual(try mode(target), 0o600)

        let backup = try XCTUnwrap(try SharedEnvFiles.install(Data("A=2\n".utf8), at: target, now: now))
        XCTAssertEqual(backup, ".env.bak-\(stamp(now))")
        let backupPath = dir.appendingPathComponent(backup).path
        XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8), "A=1\n")
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "A=2\n")
        XCTAssertEqual(try mode(backupPath), 0o600)
        XCTAssertEqual(try mode(target), 0o600)

        // A second import in the same second keeps the first copy.
        let second = try XCTUnwrap(try SharedEnvFiles.install(Data("A=3\n".utf8), at: target, now: now))
        XCTAssertNotEqual(second, backup)
        XCTAssertEqual(try String(contentsOfFile: backupPath, encoding: .utf8), "A=1\n")
    }

    func testAFailedRunOfTheScriptSaysTheRealCause() {
        let timeout = Duration.seconds(20)
        XCTAssertEqual(
            SharedEnvFiles.runFailure(FakeCommandRunner.failed(1), scriptExists: false, timeout: timeout),
            "scripts/env-check.mjs is missing in this checkout — pull dev"
        )
        XCTAssertEqual(
            SharedEnvFiles.runFailure(FakeCommandRunner.failed(127, stderr: "zsh:1: command not found: node"), scriptExists: true, timeout: timeout),
            "node could not be run (exit 127)"
        )
        XCTAssertEqual(
            SharedEnvFiles.runFailure(FakeCommandRunner.timedOut, scriptExists: true, timeout: timeout),
            "scripts/env-check.mjs did not answer in 20 s"
        )
        XCTAssertEqual(
            SharedEnvFiles.runFailure(
                FakeCommandRunner.failed(1, stderr: "node:internal\nSyntaxError: Unexpected token\n"), scriptExists: true, timeout: timeout
            ),
            "scripts/env-check.mjs failed (exit 1): SyntaxError: Unexpected token"
        )
        XCTAssertEqual(
            SharedEnvFiles.runFailure(FakeCommandRunner.ok("hello\n"), scriptExists: true, timeout: timeout),
            "scripts/env-check.mjs gave no report — pull dev"
        )
        // The row shows the cause; without one it keeps the old text.
        XCTAssertEqual(SharedEnvFiles.status(nil, failure: "node could not be run (exit 127)"), .warning("node could not be run (exit 127)"))
        XCTAssertEqual(SharedEnvFiles.status(nil), .warning("Could not run scripts/env-check.mjs — pull the latest monorepo dev"))
    }

    func testThePullMovesTheFileAsideAndPutsItBackWhenNothingWasWritten() throws {
        let dir = try tempDir()
        let target = dir.appendingPathComponent(".env").path
        XCTAssertNil(try SharedEnvFiles.moveAside(target, now: now), "no file, nothing to move")

        try "TEAMMATE=1\n".write(toFile: target, atomically: true, encoding: .utf8)
        let moved = try XCTUnwrap(try SharedEnvFiles.moveAside(target, now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target), "doppler-env.sh refuses a file it did not write")
        XCTAssertEqual((moved as NSString).lastPathComponent, ".env.bak-\(stamp(now))")
        XCTAssertEqual(try mode(moved), 0o600)

        XCTAssertTrue(SharedEnvFiles.restore(moved, to: target))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "TEAMMATE=1\n")

        // A file that doppler-env.sh wrote stays: the script replaces it, so no copy piles up.
        let pulled = "\(SharedEnvFiles.dopplerMarker)\nDOPPLER=1\n"
        try pulled.write(toFile: target, atomically: true, encoding: .utf8)
        XCTAssertNil(try SharedEnvFiles.moveAside(target, now: now))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), pulled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: moved), "no .env.bak copy of a Doppler file")
        // Control: the marker on a later line does not count.
        try "TEAMMATE=1\n\(SharedEnvFiles.dopplerMarker)\n".write(toFile: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: try XCTUnwrap(try SharedEnvFiles.moveAside(target, now: now)))
        try "TEAMMATE=1\n".write(toFile: target, atomically: true, encoding: .utf8)

        // Control: a pull that wrote a file keeps it, and the copy stays.
        let again = try XCTUnwrap(try SharedEnvFiles.moveAside(target, now: now))
        try "DOPPLER=1\n".write(toFile: target, atomically: true, encoding: .utf8)
        XCTAssertFalse(SharedEnvFiles.restore(again, to: target))
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "DOPPLER=1\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: again))
    }

    func testThePullCommandRunsEnvPullForOneApp() {
        XCTAssertEqual(SharedEnvFiles.pullCommand(monorepo: "/a b/mono", app: .partner), "cd '/a b/mono' && pnpm env:pull partner")
        XCTAssertEqual(SharedEnvFiles.pullUnavailable(monorepo: "/nonexistent/mono"), "scripts/doppler-env.sh is missing in this checkout — pull dev")
    }

    func testAnotherWorktreesEnvIsOfferedNotThisOne() throws {
        let porcelain = """
        worktree /code/mono
        HEAD abc
        branch refs/heads/dev

        worktree /code/mono-feature
        HEAD def
        branch refs/heads/feature

        worktree /code/mono-empty
        HEAD 123
        detached
        """
        let worktrees = SharedEnvFiles.worktrees(porcelain: porcelain)
        XCTAssertEqual(worktrees, ["/code/mono", "/code/mono-feature", "/code/mono-empty"])
        let present: Set = ["/code/mono/apps/booking-portal/.env", "/code/mono-feature/apps/booking-portal/.env"]
        XCTAssertEqual(
            SharedEnvFiles.copySources(worktrees: worktrees, current: "/code/mono-feature", app: .booking, exists: present.contains),
            ["/code/mono/apps/booking-portal/.env"]
        )
        XCTAssertEqual(
            SharedEnvFiles.copySources(worktrees: worktrees, current: "/code/mono-empty", app: .booking, exists: present.contains),
            ["/code/mono/apps/booking-portal/.env", "/code/mono-feature/apps/booking-portal/.env"]
        )
        XCTAssertEqual(SharedEnvFiles.copySources(worktrees: worktrees, current: "/code/mono", app: .partner, exists: present.contains), [])
        XCTAssertEqual(
            SharedEnvFiles.worktreeCommand(monorepo: "/a b"), ShellQuote.join(["git", "-C", "/a b", "worktree", "list", "--porcelain"])
        )
    }

    func testAFolderThatMacOSBlocksSaysWhereToGrantAccess() throws {
        let paths = ["/Users/a/Documents/mono", "/Users/a/Documents/login"]
        let blocked = EnvironmentChecker.folderAccessStatus(paths: paths) { $0.hasSuffix("login") ? EPERM : nil }
        XCTAssertEqual(blocked, .failing("macOS blocks access to /Users/a/Documents/login (EPERM) — Grant access in System Settings"))
        guard case .failing(let unreadable) = EnvironmentChecker.folderAccessStatus(paths: paths, errorOf: { _ in EACCES }) else {
            return XCTFail()
        }
        XCTAssertTrue(unreadable.hasPrefix("Cannot open /Users/a/Documents/mono: "), unreadable)
        XCTAssertEqual(EnvironmentChecker.folderAccessStatus(paths: paths) { _ in nil }, .passing("The checkout can be read"))

        // The live probe: a folder that opens, and a missing one, are no failure.
        let dir = try tempDir()
        XCTAssertNil(EnvironmentChecker.openError(dir.path))
        XCTAssertNil(EnvironmentChecker.openError(dir.appendingPathComponent("missing").path))

        XCTAssertTrue(EnvironmentChecker.isPermissionDenial(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertTrue(EnvironmentChecker.isPermissionDenial(NSError(
            domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))]
        )))
        XCTAssertFalse(EnvironmentChecker.isPermissionDenial(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
    }

    @MainActor
    func testTheFolderAccessRowIsRequiredAndItsFixOpensSystemSettings() throws {
        let checker = EnvironmentChecker(
            monorepoPath: "/nonexistent/mono", loginPath: "/nonexistent/login", streamServicesPath: "",
            flavor: .standard, shell: FakeCommandRunner(), tools: ToolEnvironment(home: "/nonexistent/home")
        )
        checker.buildChecks()
        let row = try XCTUnwrap(checker.checks.first { $0.id == "folder-access" })
        XCTAssertTrue(row.isRequired)
        XCTAssertEqual(row.fixLabel, "Grant access in System Settings")
        XCTAssertNotNil(CheckRegistry.impact(of: "folder-access"))
        guard case .guidance(let text, nil, let url, let linkTitle) = checker.fixAction(for: "folder-access") else { return XCTFail() }
        XCTAssertTrue(text.contains("Files and Folders"), text)
        XCTAssertEqual(url, EnvironmentChecker.filesAndFoldersURL)
        XCTAssertEqual(linkTitle, "Open Files and Folders settings")
        XCTAssertFalse(row.checkDescription.contains("opens System Settings"), "the fix shows a sheet; it does not open the settings")
        // The shared .env rows have Pull from Doppler beside Import….
        XCTAssertEqual(checker.checks.first { $0.id == "booking-env" }?.altFixLabel, "Pull from Doppler")
        XCTAssertEqual(checker.checks.first { $0.id == "partner-env" }?.altFixLabel, "Pull from Doppler")
        XCTAssertEqual(
            checker.altFixAction(for: "booking-env"),
            .command(SharedEnvFiles.pullCommand(monorepo: "/nonexistent/mono", app: .booking), timeout: EnvironmentChecker.fixTimeout)
        )
        XCTAssertNil(checker.altFixAction(for: "hotel-data"))
    }

    // MARK: Hotel keys, tested

    func testTheHotelKeyTestSaysWhatDevAnswered() {
        XCTAssertEqual(HotelCatalog.preflightStatus(FakeCommandRunner.ok("##db:health:pass:No cached dump; dev Supabase can serve one\n")),
                       .passing(HotelCatalog.keysAcceptedText))
        let rejected = CommandResult(
            exitCode: 11,
            stdout: "##db:health:fail:Dev Supabase rejected the signing key (HTTP 401) — your shared .env is out of date\n", stderr: ""
        )
        XCTAssertEqual(HotelCatalog.preflightStatus(rejected),
                       .failing("Dev Supabase rejected the signing key (HTTP 401) — your shared .env is out of date"))
        let offline = CommandResult(exitCode: 12, stdout: "##db:health:fail:Dev Supabase did not answer\n", stderr: "")
        XCTAssertEqual(HotelCatalog.preflightStatus(offline), .warning("Dev Supabase did not answer — the keys are not checked"))
        XCTAssertEqual(HotelCatalog.preflightStatus(FakeCommandRunner.failed(1)), .failing("fetch-hotels.mjs --preflight failed (exit 1)"))
        XCTAssertEqual(HotelCatalog.preflightStatus(FakeCommandRunner.timedOut),
                       .warning("The test of the hotel keys did not answer in 30 s — the keys are not checked"))
    }

    /// A pass that did not ask dev (a dump in the checkout, a published dump) says what it found.
    func testAPreflightPassThatDidNotTestTheKeysShowsTheScriptsDetail() {
        let inCheckout = "Cached — 209,823 rows, 2026-08-11"
        XCTAssertEqual(HotelCatalog.preflightStatus(FakeCommandRunner.ok("##db:health:pass:\(inCheckout)\n")), .passing(inCheckout))
        let published = "No cached dump; dumps.example.com can serve one"
        XCTAssertEqual(HotelCatalog.preflightStatus(FakeCommandRunner.ok("##db:health:pass:\(published)\n")), .passing(published))
        XCTAssertEqual(HotelCatalog.preflightStatus(FakeCommandRunner.ok()), .passing("fetch-hotels.mjs --preflight passed"))
    }

    /// Only exit 10 (no credentials) and 11 (401/403) are about the keys.
    func testOnlyAMissingOrRefusedKeyCountsAsAKeyRejection() {
        XCTAssertTrue(HotelCatalog.keysRejected(FakeCommandRunner.failed(10)))
        XCTAssertTrue(HotelCatalog.keysRejected(FakeCommandRunner.failed(11)))
        for code: Int32 in [0, 1, 12, 13, 127, 130] {
            XCTAssertFalse(HotelCatalog.keysRejected(CommandResult(exitCode: code, stdout: "", stderr: "")), "exit \(code)")
        }
        XCTAssertFalse(HotelCatalog.keysRejected(FakeCommandRunner.timedOut))
    }

    /// A checkout whose shared booking .env has the three hotel keys and no dump is cached.
    @MainActor
    private func hotelChecker(script: String, preflight: CommandResult) throws -> (EnvironmentChecker, FakeCommandRunner) {
        let root = try tempDir()
        try write(script, to: "scripts/db/fetch-hotels.mjs", in: root)
        try write("AMATEUR_SUPABASE_URL=u\nAMATEUR_SUPABASE_ANON_KEY=a\nAMATEUR_SUPABASE_SIGNING_KEY=s\n", to: "apps/booking-portal/.env", in: root)
        let report = #"{"apps":[{"app":"booking","exists":true,"shared":3,"missing":[],"blank":[],"shadowed":[],"ok":true}]}"#
        let runner = FakeCommandRunner { call in
            if call.command.hasSuffix(" --preflight") { return preflight }
            if call.command.hasSuffix(" --verify") { return CommandResult(exitCode: 1, stdout: "##db:health:fail:No dump\n", stderr: "") }
            if call.command.contains("env-check.mjs") { return FakeCommandRunner.ok(report) }
            return FakeCommandRunner.ok()
        }
        let checker = EnvironmentChecker(
            monorepoPath: root.path, loginPath: "/nonexistent/login", streamServicesPath: "/nonexistent/stream",
            flavor: .standard, shell: runner, tools: ToolEnvironment(home: "/nonexistent/home")
        )
        checker.hotelDumpPath = root.appendingPathComponent("hotels/travel_organizations.sql").path
        checker.buildChecks()
        return (checker, runner)
    }

    @MainActor
    func testKeysThatDevRefusesFailTheHotelRowAndTheBookingEnv() async throws {
        let refused = "Dev Supabase rejected the signing key (HTTP 401) — your shared .env is out of date"
        let (checker, runner) = try hotelChecker(
            script: "// --preflight\n", preflight: CommandResult(exitCode: 11, stdout: "##db:health:fail:\(refused)\n", stderr: "")
        )

        await checker.runAllChecks()

        XCTAssertEqual(checker.checks.first { $0.id == "hotel-data" }?.status, .failing(refused))
        XCTAssertEqual(checker.checks.first { $0.id == "booking-env" }?.status, .failing(refused))
        XCTAssertTrue(checker.blockers.contains { $0.id == "booking-env" })
        let preflights = runner.calls.filter { $0.command.hasSuffix(" --preflight") }
        XCTAssertEqual(preflights.count, 1, "asked once for both rows")
        XCTAssertEqual(preflights.first?.timeout, HotelCatalog.preflightTimeout)
        XCTAssertTrue(preflights.first?.command.hasPrefix("TRAVEL_HOTEL_DUMP=\(ShellQuote.quote(checker.hotelDumpPath)) ") == true)
    }

    /// Control: keys that dev accepts pass both rows.
    @MainActor
    func testKeysThatDevAcceptsPassTheHotelRow() async throws {
        let (checker, _) = try hotelChecker(
            script: "// --preflight\n", preflight: FakeCommandRunner.ok("##db:health:pass:No cached dump; dev Supabase can serve one\n")
        )

        await checker.runAllChecks()

        XCTAssertEqual(checker.checks.first { $0.id == "hotel-data" }?.status, .passing(HotelCatalog.keysAcceptedText))
        XCTAssertEqual(checker.checks.first { $0.id == "booking-env" }?.status, .passing("All 3 shared keys"))
    }

    /// Negative control: a preflight that fails for a reason other than the keys fails the
    /// hotel row only. The booking .env row keeps the env-check result and blocks nothing.
    @MainActor
    func testAPreflightFailureThatIsNotAboutTheKeysLeavesTheBookingEnvAlone() async throws {
        let noPython = "python3 was not found on PATH. Install Python 3, then run the step again."
        for preflight in [
            CommandResult(exitCode: 1, stdout: "##db:health:fail:\(noPython)\n", stderr: ""),
            CommandResult(exitCode: 13, stdout: "##db:health:fail:Dev Supabase has no hotel rows to download\n", stderr: ""),
            CommandResult(exitCode: 127, stdout: "", stderr: "node: command not found"),
        ] {
            let (checker, _) = try hotelChecker(script: "// --preflight\n", preflight: preflight)

            await checker.runAllChecks()

            guard case .failing = checker.checks.first(where: { $0.id == "hotel-data" })?.status else {
                return XCTFail("exit \(preflight.exitCode): the hotel row fails")
            }
            XCTAssertEqual(checker.checks.first { $0.id == "booking-env" }?.status, .passing("All 3 shared keys"), "exit \(preflight.exitCode)")
            XCTAssertFalse(checker.blockers.contains { $0.id == "booking-env" }, "exit \(preflight.exitCode)")
        }
    }

    /// An older fetch-hotels.mjs has no --preflight and would download: it is not run.
    @MainActor
    func testAnOlderScriptIsNotAskedToTestTheKeys() async throws {
        let (checker, runner) = try hotelChecker(script: "// fetch\n", preflight: FakeCommandRunner.failed(11))

        await checker.runAllChecks()

        XCTAssertFalse(runner.commands.contains { $0.hasSuffix(" --preflight") })
        XCTAssertEqual(checker.checks.first { $0.id == "hotel-data" }?.status, .passing(HotelCatalog.keysOnlyText))
    }

    // MARK: Stripe key, tested

    func testTheStripeTestKeyRowSaysWhatStripeAnswered() {
        let source = "apps/booking-portal/.env"
        XCTAssertEqual(StripeLauncher.testKeyStatus(source: source, result: FakeCommandRunner.ok(#"{"object": "balance", "available": [{"amount": 401}]}"#)),
                       .passing("Stripe accepts the test key from apps/booking-portal/.env"))
        let invalid = CommandResult(exitCode: 1, stdout: #"{"error": {"message": "Invalid API Key provided: sk_test_****abcd"}}"#, stderr: "")
        XCTAssertEqual(StripeLauncher.testKeyStatus(source: source, result: invalid), .warning(StripeLauncher.keyRejected(source: source)))
        let expired = CommandResult(exitCode: 0, stdout: #"{"error": {"code": "api_key_expired"}}"#, stderr: "")
        XCTAssertEqual(StripeLauncher.testKeyStatus(source: source, result: expired), .warning(StripeLauncher.keyRejected(source: source)))
        // As CLI 1.40 prints a refused request, to stderr.
        let realInvalid = CommandResult(exitCode: 1, stdout: "", stderr: """
            Request failed, status=401, body={
              "error": {
                "message": "Invalid API Key provided: sk_test_********************0000",
                "type": "invalid_request_error"
              }
            }
            """)
        XCTAssertEqual(StripeLauncher.testKeyStatus(source: source, result: realInvalid), .warning(StripeLauncher.keyRejected(source: source)))
        // Another error: the row shows Stripe's message and does not blame the network.
        let limited = CommandResult(exitCode: 1, stdout: "", stderr: """
            Request failed, status=429, body={"error": {"message": "Too many requests hit the API too quickly.\\nRetry later.", "type": "rate_limit_error"}}
            """)
        XCTAssertEqual(StripeLauncher.testKeyStatus(source: source, result: limited),
                       .warning("Stripe answered the test key from apps/booking-portal/.env: Too many requests hit the API too quickly. — re-check later"))
        guard case .warning(let offline) = StripeLauncher.testKeyStatus(source: source, result: FakeCommandRunner.failed(1)) else { return XCTFail() }
        XCTAssertTrue(offline.hasPrefix("Could not check the test key"), offline)
        XCTAssertTrue(offline.contains("network"), offline)
        guard case .warning(let noCLI) = StripeLauncher.testKeyStatus(source: source, result: nil) else { return XCTFail() }
        XCTAssertTrue(noCLI.contains(StripeLauncher.installCommand), noCLI)
    }

    @MainActor
    func testTheStripeRowAsksStripeWithTheTestKey() async throws {
        let root = try tempDir()
        try write("STRIPE_SECRET_KEY=sk_test_fake\n", to: "apps/booking-portal/.env", in: root)
        let invalid = CommandResult(exitCode: 1, stdout: #"{"error": {"message": "Invalid API Key provided"}}"#, stderr: "")
        let runner = FakeCommandRunner { call in
            call.command == StripeLauncher.keyCheckCommand ? invalid : FakeCommandRunner.ok()
        }
        let checker = EnvironmentChecker(
            monorepoPath: root.path, loginPath: "/nonexistent/login", streamServicesPath: "/nonexistent/stream",
            flavor: .standard, shell: runner, tools: ToolEnvironment(home: "/nonexistent/home")
        )
        checker.buildChecks()

        await checker.runAllChecks()

        XCTAssertEqual(
            checker.checks.first { $0.id == "stripe-auth" }?.status,
            .warning(StripeLauncher.keyRejected(source: "apps/booking-portal/.env"))
        )
        let ask = try XCTUnwrap(runner.calls.first { $0.command == StripeLauncher.keyCheckCommand })
        XCTAssertEqual(ask.environment, [StripeLauncher.apiKeyVariable: "sk_test_fake"])
        XCTAssertEqual(ask.timeout, EnvironmentChecker.checkTimeout)
    }

    // MARK: Pull from Doppler

    @MainActor
    private func pullChecker(pull: @escaping @Sendable (String) -> CommandResult) throws -> (EnvironmentChecker, URL) {
        let root = try tempDir()
        try write("#!/usr/bin/env bash\n", to: "scripts/doppler-env.sh", in: root)
        try write("TEAMMATE=1\n", to: "apps/booking-portal/.env", in: root)
        let target = root.appendingPathComponent("apps/booking-portal/.env").path
        let runner = FakeCommandRunner { call in
            call.command.contains("pnpm env:pull") ? pull(target) : FakeCommandRunner.ok()
        }
        let checker = EnvironmentChecker(
            monorepoPath: root.path, loginPath: "/nonexistent/login", streamServicesPath: "/nonexistent/stream",
            flavor: .standard, shell: runner, tools: ToolEnvironment(home: "/nonexistent/home")
        )
        checker.buildChecks()
        return (checker, root)
    }

    private func backups(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("apps/booking-portal").path)
            .filter { $0.hasPrefix(".env.bak-") }
    }

    @MainActor
    func testAFailedPullPutsTheOldFileBack() async throws {
        let (checker, root) = try pullChecker { _ in
            FakeCommandRunner.failed(1, stderr: "the Doppler CLI is required (brew install dopplerhq/cli/doppler)")
        }

        await checker.fix("booking-env", alternate: true)

        let target = root.appendingPathComponent("apps/booking-portal/.env").path
        XCTAssertEqual(try String(contentsOfFile: target, encoding: .utf8), "TEAMMATE=1\n")
        XCTAssertEqual(try backups(in: root), [], "the moved file went back")
        XCTAssertEqual(
            checker.activeFix?.state,
            .failed("Fix failed (exit 1): the Doppler CLI is required (brew install dopplerhq/cli/doppler)")
        )
    }

    @MainActor
    func testAPullKeepsACopyOfTheFileItReplaced() async throws {
        let (checker, root) = try pullChecker { target in
            try? "# Written by scripts/doppler-env.sh\nDOPPLER=1\n".write(toFile: target, atomically: true, encoding: .utf8)
            return FakeCommandRunner.ok("wrote apps/booking-portal/.env")
        }

        await checker.fix("booking-env", alternate: true)

        let target = root.appendingPathComponent("apps/booking-portal/.env").path
        XCTAssertTrue(try String(contentsOfFile: target, encoding: .utf8).contains("DOPPLER=1"))
        let copies = try backups(in: root)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try String(contentsOfFile: root.appendingPathComponent("apps/booking-portal/\(copies[0])").path, encoding: .utf8), "TEAMMATE=1\n")
        XCTAssertEqual(checker.activeFix?.state, .succeeded)
    }

    /// A checkout without the Doppler script moves nothing and runs nothing.
    @MainActor
    func testAPullWithoutTheScriptChangesNothing() async throws {
        let (checker, root) = try pullChecker { _ in FakeCommandRunner.ok() }
        try FileManager.default.removeItem(at: root.appendingPathComponent("scripts/doppler-env.sh"))

        await checker.fix("booking-env", alternate: true)

        XCTAssertEqual(checker.activeFix?.state, .failed("scripts/doppler-env.sh is missing in this checkout — pull dev"))
        XCTAssertEqual(try backups(in: root), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("apps/booking-portal/.env").path))
    }
}
