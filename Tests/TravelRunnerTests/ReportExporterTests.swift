import Foundation
import XCTest
@testable import TravelRunner

final class ReportExporterTests: XCTestCase {
    private var root: URL!
    private let utc = TimeZone(identifier: "UTC")!
    /// 2026-11-16 09:14:03 UTC
    private let date = Date(timeIntervalSince1970: 1_794_820_443)
    private let stripeKey = "sk_" + "test_" + "51AbCdEfGhIjKlMn"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ReportExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// An exporter into the test folder. Its zip keeps a copy of the folder (in
    /// `ZipCalls.contents`), so the test can read what would be zipped.
    private func exporter(zip: (@Sendable (URL, URL) async -> CommandResult)? = nil) -> (ReportExporter, ZipCalls) {
        let calls = ZipCalls()
        let downloads = root.appendingPathComponent("Downloads")
        let date = self.date
        let exporter = ReportExporter(
            destination: downloads,
            temporaryDirectory: root.appendingPathComponent("tmp"),
            timeZone: utc,
            now: { date },
            zip: zip ?? { folder, archive in
                let copy = archive.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("zipped").appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
                calls.append(folder: folder, archive: archive, contents: copy)
                do {
                    try FileManager.default.createDirectory(
                        at: copy.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: folder, to: copy)
                    try Data("PK".utf8).write(to: archive)
                    return FakeCommandRunner.ok()
                } catch {
                    return FakeCommandRunner.failed(stderr: "\(error)")
                }
            }
        )
        return (exporter, calls)
    }

    private func input(
        focus: ReportExporter.Focus = .general,
        focusText: String? = nil,
        lastError: String? = "DB setup failed at Seed"
    ) -> ReportExporter.Input {
        var snapshot = DiagnosticsSnapshotTests.sample(lastError: lastError)
        snapshot.services.append(DiagnosticsSnapshot.Service(
            id: "travel-portal", phase: "FAILED", inProfile: true, pid: nil, exitCode: 1,
            restartCount: 3, circuitBroken: true, uptimeSeconds: nil
        ))
        return ReportExporter.Input(snapshot: snapshot, redactor: .patterns, focus: focus, focusText: focusText)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Names

    func testTheZipNameHasTheMinuteAndTheVersion() {
        XCTAssertEqual(
            ReportExporter.baseName(version: "0.13.5", date: date, timeZone: utc),
            "TravelRunner-report-20261116-0914-v0.13.5"
        )
        XCTAssertEqual(
            ReportExporter.baseName(version: nil, date: date, timeZone: utc),
            "TravelRunner-report-20261116-0914-vdev"
        )
        // A dev version from `git describe` stays one file name.
        XCTAssertEqual(
            ReportExporter.baseName(version: "0.13.5-2-ga1b2c3d/dirty", date: date, timeZone: utc),
            "TravelRunner-report-20261116-0914-v0.13.5-2-ga1b2c3d_dirty"
        )
    }

    func testASecondReportInTheSameMinuteGetsANumber() {
        let folder = URL(fileURLWithPath: "/Downloads")
        let taken: Set<String> = ["/Downloads/base.zip", "/Downloads/base-2.zip"]
        XCTAssertEqual(ReportExporter.freeName("base", in: folder) { taken.contains($0) }, "base-3")
        XCTAssertEqual(ReportExporter.freeName("other", in: folder) { taken.contains($0) }, "other")
    }

    // MARK: - Summary

    func testTheSummaryHasThreeLinesForSlack() {
        let summary = ReportExporter.summary(input(), zipName: "TravelRunner-report-20261116-0914-v0.13.5.zip")
        let lines = summary.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3, summary)
        XCTAssertEqual(
            lines[0],
            "Travel Runner v0.13.5 (a1b2c3d) on macOS 15.1 (Build 24B83), arm64: TravelRunner-report-20261116-0914-v0.13.5.zip"
        )
        XCTAssertEqual(lines[1], "Health DEGRADED · profile both · DB local · failed: travel-portal, DB step seed")
        XCTAssertEqual(lines[2], "Problem: DB setup failed at Seed")
    }

    func testTheLastLineNamesWhatTheReportWasMadeFrom() {
        let service = ReportExporter.summary(
            input(focus: .service(id: "travel-portal"), focusText: "Booking Portal FAILED (exit code 1)"), zipName: "r.zip"
        )
        XCTAssertEqual(service.components(separatedBy: "\n").last, "Problem: travel-portal: Booking Portal FAILED (exit code 1)")

        let step = ReportExporter.summary(input(focus: .dbStep(id: "seed")), zipName: "r.zip")
        // Without its own text, the step has the last error of the stack.
        XCTAssertEqual(step.components(separatedBy: "\n").last, "Problem: DB step seed: DB setup failed at Seed")

        let nothing = ReportExporter.summary(input(lastError: nil), zipName: "r.zip")
        XCTAssertEqual(nothing.components(separatedBy: "\n").last, "Problem: (say what you saw)")
    }

    func testTheSummaryIsRedactedAndStaysOnOneLineEach() {
        let text = "Stripe failed\n  key \(stripeKey)\n" + String(repeating: "x", count: 300)
        let summary = ReportExporter.summary(input(focusText: text), zipName: "r.zip")
        let lines = summary.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertFalse(summary.contains(stripeKey), summary)
        XCTAssertTrue(lines[2].hasPrefix("Problem: Stripe failed key ‹redacted:stripe-key› xxx"), lines[2])
        XCTAssertLessThanOrEqual(lines[2].count, "Problem: ".count + 200)
    }

    // MARK: - Export

    func testTheExportZipsOneFolderIntoDownloadsAndDeletesTheFolder() async throws {
        let (exporter, calls) = exporter()

        let report = try await exporter.export(input())

        let zipURL = root.appendingPathComponent("Downloads/TravelRunner-report-20261116-0914-v0.13.5.zip")
        XCTAssertEqual(report.zipURL, zipURL)
        XCTAssertEqual(calls.archives, [zipURL])
        XCTAssertEqual(calls.folders.map(\.lastPathComponent), ["TravelRunner-report-20261116-0914-v0.13.5"])
        XCTAssertTrue(report.summary.hasPrefix("Travel Runner v0.13.5"))
        let contents = try XCTUnwrap(calls.contents.first)
        XCTAssertEqual(try read(contents.appendingPathComponent("summary.txt")), report.summary + "\n")
        // The folder that was zipped is gone.
        let staging = try XCTUnwrap(calls.folders.first).deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))

        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // The second report of the minute does not replace the first.
        let second = try await exporter.export(input())
        XCTAssertEqual(second.zipURL.lastPathComponent, "TravelRunner-report-20261116-0914-v0.13.5-2.zip")
    }

    func testAFailedZipIsAnErrorAndLeavesNothingInDownloads() async throws {
        let (exporter, _) = exporter(zip: { _, archive in
            FileManager.default.createFile(atPath: archive.path, contents: Data("half".utf8))
            return FakeCommandRunner.failed(1, stderr: "ditto: Couldn't read\nditto: No space left on device")
        })

        do {
            _ = try await exporter.export(input())
            XCTFail("the export should fail")
        } catch let error as ReportExporter.ExportError {
            XCTAssertEqual(error, .zipFailed("ditto: No space left on device"))
            XCTAssertEqual(error.localizedDescription, "the zip could not be made (ditto: No space left on device)")
        }
        let left = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Downloads").path)) ?? []
        XCTAssertEqual(left, [])
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tmp").path)) ?? []
        XCTAssertEqual(staging, [])
    }

    // MARK: - The folder

    func testTheFolderHasTheDiagnosticsTheLogsTheIssuesAndTheEventsAllRedacted() async throws {
        let fm = FileManager.default
        // Log files as the sink writes them, one rotated.
        let logs = root.appendingPathComponent("Logs")
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let manyLines = (1...(ReportExporter.maxLogLines + 5))
            .map { "2026-11-16T09:14:03.412+0000 [out] line \($0)" }.joined(separator: "\n")
        try manyLines.write(to: logs.appendingPathComponent("travel-portal.log"), atomically: true, encoding: .utf8)
        try "2026-11-16T09:14:03.412+0000 [err] STRIPE_SECRET_KEY=\(stripeKey)\n"
            .write(to: logs.appendingPathComponent("stripe.log"), atomically: true, encoding: .utf8)
        try "old\n".write(to: logs.appendingPathComponent("stripe.1.log"), atomically: true, encoding: .utf8)
        try "not a log\n".write(to: logs.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        // One open issue, and the events file.
        let issue = root.appendingPathComponent("issues/open/20261116T091403_service-crash-stripe")
        try fm.createDirectory(at: issue, withIntermediateDirectories: true)
        try "{\"error_message\": \"key \(stripeKey)\"}".write(
            to: issue.appendingPathComponent("issue.json"), atomically: true, encoding: .utf8
        )
        try "09:14:03.412 boom".write(to: issue.appendingPathComponent("logs-stripe.txt"), atomically: true, encoding: .utf8)
        let events = root.appendingPathComponent("issues/events.jsonl")
        try "{\"kind\":\"stripe_skip\",\"message\":\"\(stripeKey)\"}\n".write(to: events, atomically: true, encoding: .utf8)

        var input = input(lastError: "Stripe failed: \(stripeKey)")
        input.logDirectory = logs
        input.memoryLogs = [
            // Has a file: the file wins.
            "stripe": [LogEntry(timestamp: date, stream: .stdout, text: "memory line")],
            // Has no file: the lines in memory go in.
            "db-setup-seed": [LogEntry(timestamp: date, stream: .stderr, text: "Bearer abcdefghijklmnopqrstuvwxyz123456")],
        ]
        input.issueFolders = [("open", issue)]
        input.eventsFile = events

        let folder = root.appendingPathComponent("report")
        try exporter().0.stage(input, summary: "one\ntwo\nthree", into: folder)

        let files = try XCTUnwrap(fm.subpaths(atPath: folder.path)).sorted()
        XCTAssertEqual(files, [
            "README.txt",
            "diagnostics.json",
            "events.jsonl",
            "issues",
            "issues/open",
            "issues/open/20261116T091403_service-crash-stripe",
            "issues/open/20261116T091403_service-crash-stripe/issue.json",
            "issues/open/20261116T091403_service-crash-stripe/logs-stripe.txt",
            "logs",
            "logs/db-setup-seed.log",
            "logs/stripe.log",
            "logs/travel-portal.log",
            "summary.txt",
        ])

        // No file has the secret.
        for file in files {
            var isDirectory: ObjCBool = false
            let path = folder.appendingPathComponent(file).path
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            XCTAssertFalse(try read(URL(fileURLWithPath: path)).contains(stripeKey), file)
        }

        let diagnostics = try JSONDecoder().decode(
            DiagnosticsSnapshot.self, from: Data(contentsOf: folder.appendingPathComponent("diagnostics.json"))
        )
        XCTAssertEqual(diagnostics.lastError, "Stripe failed: ‹redacted:stripe-key›")
        XCTAssertEqual(diagnostics.app.version, "0.13.5")

        // The tail of a long log, with its times.
        let portal = try read(folder.appendingPathComponent("logs/travel-portal.log"))
            .split(separator: "\n")
        XCTAssertEqual(portal.count, ReportExporter.maxLogLines)
        XCTAssertEqual(portal.first, "2026-11-16T09:14:03.412+0000 [out] line 6")
        XCTAssertEqual(
            try read(folder.appendingPathComponent("logs/stripe.log")),
            "2026-11-16T09:14:03.412+0000 [err] STRIPE_SECRET_KEY=‹redacted:stripe-key›\n"
        )
        XCTAssertEqual(
            try read(folder.appendingPathComponent("logs/db-setup-seed.log")),
            "2026-11-16T09:14:03.000+0000 [err] Bearer ‹redacted:bearer›\n"
        )
        XCTAssertEqual(
            try read(folder.appendingPathComponent("issues/open/20261116T091403_service-crash-stripe/logs-stripe.txt")),
            "09:14:03.412 boom"
        )
        XCTAssertEqual(try read(folder.appendingPathComponent("summary.txt")), "one\ntwo\nthree\n")
        XCTAssertTrue(try read(folder.appendingPathComponent("README.txt")).contains("Secret values are replaced"))
    }

    func testAMissingLogFolderIssueOrEventsFileLeavesItOut() throws {
        var input = input()
        input.logDirectory = root.appendingPathComponent("no-logs")
        input.issueFolders = [("open", root.appendingPathComponent("no-issue"))]
        input.eventsFile = root.appendingPathComponent("no-events.jsonl")

        let folder = root.appendingPathComponent("report")
        try exporter().0.stage(input, summary: "s", into: folder)

        let files = try XCTUnwrap(FileManager.default.subpaths(atPath: folder.path)).sorted()
        XCTAssertEqual(files, ["README.txt", "diagnostics.json", "logs", "summary.txt"])
    }

    // MARK: - The supervisor

    @MainActor
    func testTheSupervisorReportHasTheIssueItWasMadeFromAndTheServiceCause() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ReportExporterTests-\(UUID().uuidString)"))
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        supervisor.diagnosticsTools = { _ in [] }
        let issues = root.appendingPathComponent("issues")
        let date = self.date
        let tracker = DebugTracker(baseDir: issues.path, rateLimitSeconds: 0, now: { date })
        supervisor.debugTracker = tracker
        let (exporter, calls) = exporter()
        supervisor.makeReportExporter = { exporter }

        let state = ServiceState(definition: ServiceDefinition(
            id: "travel-portal", name: "Booking Portal", cmd: ["true"], cwd: nil, probe: nil, type: .daemon,
            restart: .never, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        ))
        state.phase = .failed
        state.exitCode = 1
        supervisor.serviceStates = ["travel-portal": state]
        await supervisor.logStore.append(
            serviceID: "travel-portal",
            entry: LogEntry(timestamp: date, stream: .stderr, text: "Error: listen EADDRINUSE: address already in use :::3002")
        )

        let captured = await tracker.captureIssue(
            trigger: "service_crash", serviceId: "travel-portal", errorMessage: "exited with code 1"
        )
        let id = try XCTUnwrap(captured)
        let closed = await tracker.closeIssue(id: id, resolution: "port freed")
        XCTAssertTrue(closed)

        let report = try await supervisor.exportReport(focus: .service(id: "travel-portal"))
        XCTAssertEqual(
            report.summary.components(separatedBy: "\n").last,
            "Problem: travel-portal: Booking Portal FAILED (exit code 1) — Error: listen EADDRINUSE: address already in use :::3002"
        )
        XCTAssertFalse(supervisor.reportExportRunning)
        // The logs in memory went in.
        let contents = try XCTUnwrap(calls.contents.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: contents.appendingPathComponent("logs/travel-portal.log").path))

        // From the Issues detail, the closed issue goes in under its status.
        let fromIssue = try await supervisor.exportReport(focus: .issue(id: id, status: "closed"))
        XCTAssertTrue(fromIssue.summary.hasSuffix("Problem: issue \(id): service_crash [travel-portal]: exited with code 1"), fromIssue.summary)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: try XCTUnwrap(calls.contents.last).appendingPathComponent("issues/closed/\(id)/issue.json").path
        ))
    }
}

/// The calls of the fake zip.
private final class ZipCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [(folder: URL, archive: URL, contents: URL)] = []

    func append(folder: URL, archive: URL, contents: URL) {
        lock.withLock { calls.append((folder, archive, contents)) }
    }

    var folders: [URL] { lock.withLock { calls.map(\.folder) } }
    var archives: [URL] { lock.withLock { calls.map(\.archive) } }
    /// The copy of each folder that was zipped.
    var contents: [URL] { lock.withLock { calls.map(\.contents) } }
}
