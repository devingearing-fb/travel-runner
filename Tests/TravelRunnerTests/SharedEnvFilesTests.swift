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
        XCTAssertEqual(prompt.message, "It sets 25 of the 26 shared keys. Missing: LITEAPI_API_KEY. It replaces the current apps/booking-portal/.env.")
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
}
