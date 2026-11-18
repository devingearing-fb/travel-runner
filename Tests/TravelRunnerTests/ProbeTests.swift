import Foundation
import XCTest
@testable import TravelRunner

/// The rules of the probes that keep running (L5): the liveness series of
/// `HealthMonitor`, its texts, and the awake-time wait for a probe.
final class ProbeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: - Liveness series

    func testThreeFailedChecksInARowMarkAServiceUnhealthy() {
        var monitor = HealthMonitor()
        XCTAssertEqual(monitor.record("web", .http(status: 500), at: start), .failing(count: 1))
        XCTAssertEqual(monitor.record("web", .http(status: 500), at: start.addingTimeInterval(20)), .failing(count: 2))
        XCTAssertEqual(monitor.record("web", .refused, at: start.addingTimeInterval(40)), .unhealthy(since: start))
        // It stays unhealthy, since the first failure of the series.
        XCTAssertEqual(monitor.record("web", .timedOut, at: start.addingTimeInterval(60)), .unhealthy(since: start))
    }

    /// Negative control: a check that passes in between starts a new series.
    func testAPassedCheckEndsTheSeries() {
        var monitor = HealthMonitor()
        _ = monitor.record("web", .http(status: 500), at: start)
        _ = monitor.record("web", .http(status: 500), at: start)
        XCTAssertEqual(monitor.record("web", .ok, at: start), .answering(recovered: false))
        XCTAssertEqual(monitor.record("web", .http(status: 500), at: start), .failing(count: 1))
    }

    func testAnUnhealthyServiceThatAnswersAgainHasRecovered() {
        var monitor = HealthMonitor()
        for _ in 0..<3 { _ = monitor.record("web", .refused, at: start) }
        XCTAssertEqual(monitor.record("web", .redirect(to: "/login"), at: start), .answering(recovered: true))
        XCTAssertEqual(monitor.record("web", .ok, at: start), .answering(recovered: false))
    }

    func testTheSeriesOfEachServiceIsItsOwn() {
        var monitor = HealthMonitor()
        _ = monitor.record("a", .refused, at: start)
        _ = monitor.record("a", .refused, at: start)
        XCTAssertEqual(monitor.record("b", .refused, at: start), .failing(count: 1))
        monitor.forget("a")
        XCTAssertEqual(monitor.record("a", .refused, at: start), .failing(count: 1))
    }

    /// Only a server that answers 404 on every route is restarted by itself.
    func testThreeZombieAnswersInARowAskForARestart() {
        var monitor = HealthMonitor()
        XCTAssertEqual(monitor.record("web", .http(status: 404), at: start), .failing(count: 1))
        XCTAssertEqual(monitor.record("web", .http(status: 404), at: start), .failing(count: 2))
        XCTAssertEqual(monitor.record("web", .http(status: 404), at: start), .zombie)
        // The restart starts a new series.
        XCTAssertEqual(monitor.record("web", .http(status: 404), at: start), .failing(count: 1))
    }

    /// Negative controls: a 5xx, a 404 with a 5xx at / and no answer are no zombie,
    /// and another failure in between breaks the zombie series.
    func testOtherFailuresAreNoZombie() {
        XCTAssertTrue(HealthMonitor.isZombie(.http(status: 404)))
        for outcome: ProbeOutcome in [.http(status: 500), .notFoundThenRoot(.http(status: 500)), .refused, .timedOut] {
            XCTAssertFalse(HealthMonitor.isZombie(outcome), outcome.summary)
        }
        var monitor = HealthMonitor()
        _ = monitor.record("web", .http(status: 404), at: start)
        _ = monitor.record("web", .http(status: 404), at: start)
        XCTAssertEqual(monitor.record("web", .http(status: 500), at: start), .unhealthy(since: start))
        XCTAssertEqual(monitor.record("web", .http(status: 404), at: start), .unhealthy(since: start))
    }

    // MARK: - Texts

    func testTheUnhealthyHeadlineSaysWhatItAnswersAndSince() {
        let since = ISO8601DateFormatter().date(from: "2026-11-18T02:02:00Z")!
        let time = { (outcome: ProbeOutcome, path: String?) in
            HealthMonitor.unhealthyHeadline(name: "Booking Portal", outcome: outcome, path: path, port: 3002, since: since, timeZone: self.utc)
        }
        XCTAssertEqual(time(.http(status: 500), "/api/health"), "Booking Portal answers 500 on /api/health since 02:02.")
        XCTAssertEqual(time(.http(status: 503), nil), "Booking Portal answers 503 on :3002 since 02:02.")
        XCTAssertEqual(time(.refused, "/api/health"), "Booking Portal does not answer on :3002 since 02:02.")
        XCTAssertEqual(
            time(.notFoundThenRoot(.http(status: 500)), "/api/health"),
            "Booking Portal fails its health check since 02:02 (HTTP 404, and HTTP 500 at /)."
        )
    }

    func testTheSlowStartHeadline() {
        XCTAssertEqual(
            HealthMonitor.slowStartHeadline(name: "Booking Portal", elapsed: .seconds(250), lastProbe: .refused, port: 3002),
            "Booking Portal still starting (4m10s) — last check: no answer on :3002"
        )
        XCTAssertEqual(
            HealthMonitor.slowStartHeadline(name: "Booking Portal", elapsed: .seconds(42), lastProbe: .http(status: 500), port: 3002),
            "Booking Portal still starting (42s) — last check: HTTP 500"
        )
        XCTAssertEqual(HealthMonitor.lastCheckText(nil, port: nil), "no answer")
        XCTAssertEqual(HealthMonitor.lastCheckText(.noMatchYet, port: nil), "ready line not seen yet")
    }

    func testElapsedText() {
        XCTAssertEqual(HealthMonitor.elapsedText(.seconds(0)), "0s")
        XCTAssertEqual(HealthMonitor.elapsedText(.seconds(59)), "59s")
        XCTAssertEqual(HealthMonitor.elapsedText(.seconds(60)), "1m00s")
        XCTAssertEqual(HealthMonitor.elapsedText(.seconds(250)), "4m10s")
        XCTAssertEqual(HealthMonitor.elapsedText(.seconds(3720)), "1h02m")
    }

    func testTheHardCapText() {
        XCTAssertEqual(
            HealthMonitor.hardCapText(name: "Booking Portal", limit: HealthMonitor.startHardCap),
            "Booking Portal did not answer in 15 min and was stopped."
        )
        XCTAssertEqual(
            "\(EnvironmentSupervisor.ServiceError.startTimedOut(name: "web", limit: .seconds(6)))",
            "web did not answer in 6 s and was stopped."
        )
    }

    func testTheWakeSummary() {
        XCTAssertEqual(
            HealthMonitor.wakeSummary(checked: 5, restarted: ["Stripe CLI"]),
            "[travel-runner] Wake check: 5 checked, 1 restarted (Stripe CLI)"
        )
        XCTAssertEqual(HealthMonitor.wakeSummary(checked: 3, restarted: []), "[travel-runner] Wake check: 3 checked, 0 restarted")
    }

    func testKeepWaitingIsAButton() {
        XCTAssertEqual(RecoveryAction.keepWaiting.title(runtime: "OrbStack"), "Keep waiting")
    }

    // MARK: - The wait for a probe

    private final class CountingProbe: Probe, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let readyAt: Int?
        init(readyAt: Int?) { self.readyAt = readyAt }
        var count: Int { lock.withLock { calls } }
        func outcome() async -> ProbeOutcome {
            let n = lock.withLock { calls += 1; return calls }
            if let readyAt, n >= readyAt { return .ok }
            return .refused
        }
    }

    /// The deadline is the clock's own time, so a fake clock ends the wait without
    /// real time, and it returns the last outcome.
    func testTheWaitForAProbeEndsOnTheClockAndGivesTheLastOutcome() async throws {
        let time = FakeClock()
        let probe = CountingProbe(readyAt: nil)
        let outcome = try await waitForProbe(probe, timeout: .seconds(15), interval: .seconds(3), clock: time.clock)
        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(probe.count, 5)
        XCTAssertEqual(time.sleeps, Array(repeating: .seconds(3), count: 5))
    }

    func testTheWaitForAProbeEndsWhenItPasses() async throws {
        let time = FakeClock()
        let probe = CountingProbe(readyAt: 2)
        let outcome = try await waitForProbe(probe, timeout: .seconds(15), interval: .seconds(3), clock: time.clock)
        XCTAssertEqual(outcome, .ok)
        XCTAssertEqual(probe.count, 2)
    }
}
