import Foundation
import XCTest
@testable import TravelRunner

/// The log files on disk, in a temporary folder with a clock of the test.
final class LogFileSinkTests: XCTestCase {
    private var directory: URL!
    private let clock = TestClock()

    /// 2026-11-16 16:14:03.412 UTC.
    private static let start = Date(timeIntervalSince1970: 1_794_845_643.412)
    private static let denver = TimeZone(identifier: "America/Denver")!

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = LogFileSinkTests.start
        var now: Date {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func advance(days: Double) {
            lock.lock()
            defer { lock.unlock() }
            value = value.addingTimeInterval(days * 86_400)
        }
    }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogFileSinkTests-\(UUID().uuidString)")
            .appendingPathComponent("Travel Runner")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    // MARK: - Helpers

    private func makeSink(maxBytes: Int = 5 * 1024 * 1024, keptFiles: Int = 3) -> LogFileSink {
        let clock = self.clock
        return LogFileSink(
            directory: directory, version: "0.14.0", maxBytes: maxBytes, keptFiles: keptFiles,
            timeZone: Self.denver, now: { clock.now }
        )
    }

    private func entry(_ text: String, _ stream: LogEntry.Stream = .stdout) -> LogEntry {
        LogEntry(timestamp: clock.now, stream: stream, text: text)
    }

    private func text(_ name: String) -> String? {
        try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }

    private func setModified(_ name: String, daysAgo: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: clock.now.addingTimeInterval(-daysAgo * 86_400)],
            ofItemAtPath: directory.appendingPathComponent(name).path
        )
    }

    // MARK: - Lines

    func testEachLineHasTheTimeWithMillisecondsAndZoneAndTheStream() {
        let sink = makeSink()

        sink.write(id: "travel-portal", entries: [entry("ready on 3000"), entry("boom", .stderr)])

        XCTAssertEqual(text("travel-portal.log"), """
        2026-11-16T09:14:03.412-0700 [out] ready on 3000
        2026-11-16T09:14:03.412-0700 [err] boom

        """)
    }

    func testTheTimeIsTheTimeOfTheEntryNotOfTheWrite() {
        let sink = makeSink()
        let early = entry("first")
        clock.advance(days: 1)

        sink.write(id: "api", entries: [early])

        XCTAssertEqual(text("api.log"), "2026-11-16T09:14:03.412-0700 [out] first\n")
    }

    func testATextWithLineBreaksGetsThePrefixOnEachLine() {
        let sink = makeSink()

        sink.write(id: "api", entries: [entry("Error: x\n    at y")])

        XCTAssertEqual(text("api.log"), """
        2026-11-16T09:14:03.412-0700 [out] Error: x
        2026-11-16T09:14:03.412-0700 [out]     at y

        """)
    }

    func testEachIdHasItsOwnFileAndWritesAppend() {
        let sink = makeSink()

        sink.write(id: "api", entries: [entry("one")])
        sink.write(id: "stripe", entries: [entry("other")])
        sink.write(id: "api", entries: [entry("two")])

        XCTAssertEqual(names(), ["api.log", "stripe.log"])
        XCTAssertEqual(text("api.log")?.split(separator: "\n").map { $0.hasSuffix("one") || $0.hasSuffix("two") }, [true, true])
    }

    func testANewSinkAppendsToTheFileOfTheLastLaunch() {
        makeSink().write(id: "api", entries: [entry("before the quit")])

        makeSink().write(id: "api", entries: [entry("after the launch")])

        let lines = text("api.log")?.split(separator: "\n") ?? []
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.first?.hasSuffix("before the quit") == true)
    }

    func testAnIdCannotLeaveTheFolder() {
        let sink = makeSink()

        sink.write(id: "../../evil/name", entries: [entry("x")])

        XCTAssertEqual(names(), ["_.._evil_name.log"])
        XCTAssertEqual(LogFileSink.fileName(for: ".."), "_")
        XCTAssertEqual(LogFileSink.fileName(for: "db-setup-seed_1"), "db-setup-seed_1")
    }

    // MARK: - Mode

    func testTheFileIsForTheOwnerOnlyAndTheFolderToo() throws {
        let sink = makeSink()

        sink.write(id: "api", entries: [entry("x")])

        XCTAssertEqual(try mode(sink.fileURL(for: "api")), 0o600)
        XCTAssertEqual(try mode(directory), 0o700)
    }

    func testAnOlderFileWithAWiderModeGetsTheOwnerOnlyMode() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("api.log")
        FileManager.default.createFile(atPath: url.path, contents: Data("old\n".utf8), attributes: [.posixPermissions: 0o644])
        XCTAssertEqual(try mode(url), 0o644)

        makeSink().write(id: "api", entries: [entry("x")])

        XCTAssertEqual(try mode(url), 0o600)
    }

    // MARK: - The raw text and the runner log

    func testAServiceLogKeepsTheRawTextAndTheRunnerLogMasksIt() {
        let sink = makeSink()
        let secret = "sk_test_51AbCdEfGhIjKlMnOp"

        sink.write(id: "stripe", entries: [entry("key \(secret) expired")])
        sink.write(id: LogFileSink.runnerLogID, entries: [entry("key \(secret) expired")])

        XCTAssertTrue(text("stripe.log")?.contains(secret) == true)
        XCTAssertEqual(text("runner.log"), "2026-11-16T09:14:03.412-0700 [out] key ‹redacted:stripe-key› expired\n")
    }

    func testTheRunnerLogMasksTheExactValuesOfTheEnvFiles() {
        let sink = makeSink()
        sink.setRunnerRedactor(Redactor(knownValues: ["plain-looking-value-1234"]))

        sink.write(id: LogFileSink.runnerLogID, entries: [entry("uses plain-looking-value-1234 now")])
        sink.write(id: "api", entries: [entry("uses plain-looking-value-1234 now")])

        XCTAssertEqual(text("runner.log"), "2026-11-16T09:14:03.412-0700 [out] uses ‹redacted:env-value› now\n")
        XCTAssertTrue(text("api.log")?.contains("plain-looking-value-1234") == true)
    }

    // MARK: - The separator

    func testAStartWritesTheSeparator() {
        let sink = makeSink()

        sink.writeStart(id: "api", name: "API Gateway", pid: 4242)

        XCTAssertEqual(
            text("api.log"),
            "2026-11-16T09:14:03.412-0700 [out] [travel-runner] ── started API Gateway pid 4242 (runner v0.14.0) ──\n"
        )
    }

    func testAStartBringsBackAFileThatSomeoneDeleted() throws {
        let sink = makeSink()
        sink.write(id: "api", entries: [entry("one")])
        try FileManager.default.removeItem(at: sink.fileURL(for: "api"))

        sink.writeStart(id: "api", name: "api", pid: 1)
        sink.write(id: "api", entries: [entry("two")])

        XCTAssertEqual(text("api.log")?.split(separator: "\n").count, 2)
    }

    func testAWriteMakesTheFolderAgainWhenItIsGone() throws {
        let sink = makeSink()
        try FileManager.default.removeItem(at: directory)

        sink.write(id: "api", entries: [entry("x")])

        XCTAssertEqual(names(), ["api.log"])
    }

    // MARK: - Rotation

    /// One line of 100 bytes: the prefix has 35 bytes and the line break 1.
    private func hundredBytes(_ mark: Character) -> LogEntry {
        entry(String(repeating: mark, count: 64))
    }

    func testAFullFileRotatesAndTheLineStaysWhole() throws {
        let sink = makeSink(maxBytes: 250)

        for mark in ["a", "b", "c"] as [Character] { sink.write(id: "api", entries: [hundredBytes(mark)]) }

        XCTAssertEqual(names(), ["api.1.log", "api.log"])
        XCTAssertEqual(text("api.1.log")?.split(separator: "\n").count, 2)
        XCTAssertTrue(text("api.log")?.hasSuffix(String(repeating: "c", count: 64) + "\n") == true)
        XCTAssertEqual(text("api.log")?.split(separator: "\n").count, 1)
        XCTAssertEqual(try mode(directory.appendingPathComponent("api.1.log")), 0o600)
    }

    func testNegativeControlAFileUnderTheLimitDoesNotRotate() {
        let sink = makeSink(maxBytes: 250)

        for mark in ["a", "b"] as [Character] { sink.write(id: "api", entries: [hundredBytes(mark)]) }

        XCTAssertEqual(names(), ["api.log"])
    }

    func testRotationKeepsThreeOldFilesAndDropsTheOldest() {
        let sink = makeSink(maxBytes: 150)

        // Each write after the first rotates: six writes are five rotations.
        for mark in ["a", "b", "c", "d", "e", "f"] as [Character] { sink.write(id: "api", entries: [hundredBytes(mark)]) }

        XCTAssertEqual(names(), ["api.1.log", "api.2.log", "api.3.log", "api.log"])
        XCTAssertTrue(text("api.log")?.contains("ffff") == true)
        XCTAssertTrue(text("api.1.log")?.contains("eeee") == true)
        XCTAssertTrue(text("api.3.log")?.contains("cccc") == true)
    }

    func testTheSizeOfTheLastLaunchCountsForTheRotation() {
        makeSink(maxBytes: 150).write(id: "api", entries: [hundredBytes("a")])

        makeSink(maxBytes: 150).write(id: "api", entries: [hundredBytes("b")])

        XCTAssertEqual(names(), ["api.1.log", "api.log"])
    }

    func testOneWriteLargerThanTheLimitStillGoesToTheFile() {
        let sink = makeSink(maxBytes: 50)

        sink.write(id: "api", entries: [hundredBytes("a")])

        XCTAssertEqual(names(), ["api.log"])
        XCTAssertEqual(text("api.log")?.utf8.count, 100)
    }

    // MARK: - Age

    func testALaunchDeletesTheFilesOlderThanFourteenDaysAndKeepsTheRest() throws {
        let first = makeSink()
        for id in ["old", "old.1", "fresh"] { first.write(id: id, entries: [entry("x")]) }
        try Data("keep".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        try setModified("old.log", daysAgo: 15)
        try setModified("old.1.log", daysAgo: 30)
        try setModified("fresh.log", daysAgo: 13)
        try setModified("notes.txt", daysAgo: 100)

        _ = makeSink()

        XCTAssertEqual(names(), ["fresh.log", "notes.txt"])
    }

    func testARunningAppDeletesOldFilesTooAndWritesToANewFile() throws {
        let sink = makeSink()
        sink.write(id: "quiet", entries: [entry("long ago")])
        sink.write(id: "busy", entries: [entry("long ago")])
        try setModified("quiet.log", daysAgo: 0)
        try setModified("busy.log", daysAgo: 0)

        clock.advance(days: 15)
        sink.write(id: "busy", entries: [entry("today")])

        XCTAssertEqual(names(), ["busy.log"])
        XCTAssertEqual(text("busy.log"), "2026-12-01T09:14:03.412-0700 [out] today\n")
    }

    // MARK: - The store

    func testTheStoreWritesEachEntryAndClearKeepsTheFile() async {
        let sink = makeSink()
        let store = LogStore(sink: sink)

        await store.append(serviceID: "api", entry: entry("one"))
        await store.appendBatch(serviceID: "api", entries: [entry("two"), entry("three", .stderr)])
        await store.markStart(serviceID: "api", name: "api", pid: 7)
        await store.clear(serviceID: "api")
        await store.clearAll()

        let entries = await store.entries(for: "api")
        XCTAssertTrue(entries.isEmpty)
        let lines = text("api.log")?.split(separator: "\n").map(String.init) ?? []
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[2].hasSuffix("[err] three"))
        XCTAssertTrue(lines[3].hasSuffix("[travel-runner] ── started api pid 7 (runner v0.14.0) ──"))
        XCTAssertEqual(store.fileURL(for: "api"), sink.fileURL(for: "api"))
    }

    func testShowLogFileGoesToTheFileAndToTheFolderWhenTheFileIsNotThere() async {
        let sink = makeSink()
        let store = LogStore(sink: sink)
        let file = sink.fileURL(for: "holds-viewer")

        // No line yet, so no file: the folder opens.
        XCTAssertEqual(store.revealTarget(for: "holds-viewer"), .folder(file.deletingLastPathComponent()))

        await store.append(serviceID: "holds-viewer", entry: entry("one"))
        XCTAssertEqual(store.revealTarget(for: "holds-viewer"), .file(file))

        XCTAssertNil(LogStore().revealTarget(for: "holds-viewer"))
    }

    func testTheSeparatorIsNotInTheView() async {
        let store = LogStore(sink: makeSink())

        await store.markStart(serviceID: "api", name: "api", pid: 7)

        let entries = await store.entries(for: "api")
        XCTAssertTrue(entries.isEmpty)
    }

    func testNegativeControlAStoreWithNoSinkWritesNoFile() async {
        let store = LogStore()

        await store.append(serviceID: "api", entry: entry("one"))
        await store.markStart(serviceID: "api", name: "api", pid: 7)

        XCTAssertNil(store.fileURL(for: "api"))
        XCTAssertEqual(names(), [])
    }

    /// The lines of an earlier run, oldest first, without the lines of this run.
    func testTheTailOfAnEarlierRunHasOnlyItsLines() {
        let earlier = makeSink()
        earlier.write(id: "runner", entries: [entry("one"), entry("two", .stderr), entry("three")])
        clock.advance(days: 1.0 / 86_400)
        let sink = makeSink()
        sink.write(id: "runner", entries: [entry("this run")])

        XCTAssertEqual(sink.earlierRunTail(id: "runner", maxLines: 10).map(\.text), ["one", "two", "three"])
        XCTAssertEqual(sink.earlierRunTail(id: "runner", maxLines: 2).map(\.text), ["two", "three"])
        XCTAssertEqual(sink.earlierRunTail(id: "runner", maxLines: 2).map(\.stream), [.stderr, .stdout])
        XCTAssertEqual(sink.earlierRunTail(id: "runner", maxLines: 1).first?.timestamp, Self.start)
        XCTAssertEqual(sink.earlierRunTail(id: "other", maxLines: 10).count, 0)
    }

    func testTheDefaultFolderHasTheNameOfTheApp() {
        XCTAssertTrue(LogFileSink.defaultDirectory(flavor: .standard).path.hasSuffix("/Library/Logs/Travel Runner"))
        XCTAssertTrue(LogFileSink.defaultDirectory(flavor: .hackathon).path.hasSuffix("/Library/Logs/Travel Runner Hackathon"))
    }
}
