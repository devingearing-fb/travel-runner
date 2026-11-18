import Foundation
import XCTest
@testable import TravelRunner

/// The ledger of the processes that the runner started. The processes are fakes:
/// a pid with a start time.
final class LaunchLedgerTests: XCTestCase {
    private var workDir: URL!
    private var path: String { workDir.appendingPathComponent("config/launches.json").path }

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchLedgerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Processes that run now, by pid: their start times.
    private func running(_ starts: [pid_t: Int64]) -> (pid_t) -> ProcessFacts? {
        { pid in starts[pid].map { ProcessFacts(pid: pid, startTime: $0) } }
    }

    func testTheNextLaunchFindsTheProcessesOfTheLastOne() {
        let facts = running([100: 1_000, 200: 2_000])
        let first = LaunchLedger(path: path)
        first.record(serviceID: "travel-portal", pid: 100, cwd: "/work/mono/apps/booking-portal", command: ["pnpm", "dev"], facts: facts)
        first.record(serviceID: "stripe", pid: 200, cwd: nil, command: ["stripe", "listen"], facts: facts)
        // This run started them: they are not left over.
        XCTAssertEqual(first.leftovers(facts: facts), [])
        XCTAssertEqual(first.sessionPIDs, [100, 200])

        let next = LaunchLedger(path: path)

        XCTAssertEqual(next.sessionPIDs, [])
        XCTAssertEqual(next.leftovers(facts: facts), [
            LaunchLedger.Entry(serviceID: "travel-portal", pid: 100, startTime: 1_000, cwd: "/work/mono/apps/booking-portal", command: ["pnpm", "dev"]),
            LaunchLedger.Entry(serviceID: "stripe", pid: 200, startTime: 2_000, cwd: nil, command: ["stripe", "listen"]),
        ])
    }

    /// The system gives the pid of a dead process to a new one. The start time tells them apart.
    func testAReusedPidIsNotTheProcessOfTheLedger() {
        LaunchLedger(path: path).record(serviceID: "web", pid: 100, cwd: nil, command: ["pnpm", "dev"], facts: running([100: 1_000]))
        let ledger = LaunchLedger(path: path)

        let reused = running([100: 5_000])
        XCTAssertEqual(ledger.live(facts: reused), [])
        XCTAssertEqual(ledger.leftovers(facts: reused), [])
        ledger.prune(facts: reused)
        XCTAssertEqual(ledger.entries, [])
        XCTAssertEqual(LaunchLedger(path: path).entries, [], "the file forgets it too")

        // Negative control: the same start time is the same process.
        LaunchLedger(path: path).record(serviceID: "web", pid: 100, cwd: nil, command: ["pnpm", "dev"], facts: running([100: 1_000]))
        XCTAssertEqual(LaunchLedger(path: path).live(facts: running([100: 1_000])).map(\.pid), [100])
    }

    /// The command is the command of the service. A key goes to the process
    /// environment only, so the file never holds it.
    func testTheFileHoldsNoEnvironmentAndOnlyThisUserReadsIt() throws {
        let secret = "sk_test_ledger_\(UUID().uuidString)"
        let stripe = ServiceDefinition(
            id: "stripe", name: "Stripe CLI", cmd: StripeLauncher.command, cwd: nil, probe: nil, type: .daemon,
            restart: .never, dependsOn: [], env: [StripeLauncher.apiKeyVariable: secret], phase: nil, reuseIfRunning: nil
        )
        let ledger = LaunchLedger(path: path)
        ledger.record(serviceID: stripe.id, pid: 300, cwd: stripe.resolvedCwd, command: stripe.cmd, facts: running([300: 3]))

        let text = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(text.contains(secret))
        XCTAssertFalse(text.contains(StripeLauncher.apiKeyVariable))
        XCTAssertTrue(text.contains("\"serviceID\" : \"stripe\""), text)
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testAnEndedProcessLeavesTheLedger() {
        let facts = running([100: 1, 101: 2])
        let ledger = LaunchLedger(path: path)
        ledger.record(serviceID: "a", pid: 100, cwd: nil, command: ["a"], facts: facts)
        ledger.record(serviceID: "b", pid: 101, cwd: nil, command: ["b"], facts: facts)

        ledger.remove(pids: [100])

        XCTAssertEqual(ledger.entries.map(\.pid), [101])
        XCTAssertEqual(ledger.sessionPIDs, [101])
        XCTAssertEqual(LaunchLedger(path: path).entries.map(\.pid), [101])
    }

    /// A process that is gone before the ledger reads its start time is not recorded.
    func testAProcessWithNoStartTimeIsNotRecorded() {
        let ledger = LaunchLedger(path: path)
        ledger.record(serviceID: "a", pid: 100, cwd: nil, command: ["a"], facts: { _ in nil })
        XCTAssertEqual(ledger.entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testABrokenFileIsAnEmptyLedger() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(LaunchLedger(path: path).entries, [])
    }

    func testALedgerWithNoFileStaysInMemory() {
        let ledger = LaunchLedger(path: nil)
        ledger.record(serviceID: "a", pid: 100, cwd: nil, command: ["a"], facts: running([100: 1]))
        XCTAssertEqual(ledger.entries.map(\.pid), [100])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    /// The file of the app is in the config folder of the flavor.
    func testTheFileOfTheAppIsInTheConfigFolder() {
        XCTAssertEqual(LaunchLedger.livePath, (LaunchEnvironment.configDir() as NSString).appendingPathComponent("launches.json"))
    }
}
