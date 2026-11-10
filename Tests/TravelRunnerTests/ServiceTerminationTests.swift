import Foundation
import XCTest
@testable import TravelRunner

final class ServiceTerminationTests: XCTestCase {
    private func termination(status: Int32, bySignal: Bool = false, stopped: Bool = false) -> ProcessRunner.Termination {
        ProcessRunner.Termination(pid: 4242, status: status, bySignal: bySignal, stoppedByRunner: stopped)
    }

    // MARK: - classify

    func testAStopByTheRunnerWinsOverEveryStatus() {
        for status in [Int32(0), 1, 9, 15, 143] {
            XCTAssertEqual(ServiceTermination.classify(termination(status: status, stopped: true)), .stoppedByRunner)
            XCTAssertEqual(ServiceTermination.classify(termination(status: status, bySignal: true, stopped: true)), .stoppedByRunner)
        }
    }

    func testExitZeroIsClean() {
        XCTAssertEqual(ServiceTermination.classify(termination(status: 0)), .cleanExit)
    }

    /// The tickets "exited with code 143", "code 15" and "code 9" had this cause.
    func testAStopSignalFromOutsideIsNotACrash() {
        XCTAssertEqual(ServiceTermination.classify(termination(status: 143)), .killedExternally(signal: SIGTERM))
        XCTAssertEqual(ServiceTermination.classify(termination(status: 137)), .killedExternally(signal: SIGKILL))
        XCTAssertEqual(ServiceTermination.classify(termination(status: 130)), .killedExternally(signal: SIGINT))
        XCTAssertEqual(ServiceTermination.classify(termination(status: 15, bySignal: true)), .killedExternally(signal: SIGTERM))
        XCTAssertEqual(ServiceTermination.classify(termination(status: 9, bySignal: true)), .killedExternally(signal: SIGKILL))
    }

    func testAFaultSignalIsACrash() {
        XCTAssertEqual(ServiceTermination.classify(termination(status: 11, bySignal: true)), .crashed(code: 11, bySignal: true))
        XCTAssertEqual(ServiceTermination.classify(termination(status: 134)), .crashed(code: 134, bySignal: false), "128 + SIGABRT")
    }

    func testAnOrdinaryFailureIsACrash() {
        XCTAssertEqual(ServiceTermination.classify(termination(status: 1)), .crashed(code: 1, bySignal: false))
        // Exit 15 without a signal is a normal exit code, not SIGTERM.
        XCTAssertEqual(ServiceTermination.classify(termination(status: 15)), .crashed(code: 15, bySignal: false))
    }

    func testACommandTheShellCannotRunIsNotRetried() {
        XCTAssertEqual(ServiceTermination.classify(termination(status: 127)), .commandNotRunnable(code: 127))
        XCTAssertEqual(ServiceTermination.classify(termination(status: 126)), .commandNotRunnable(code: 126))
    }

    func testDescribe() {
        XCTAssertEqual(ServiceTermination.describe(termination(status: 1)), "exited with code 1")
        XCTAssertEqual(ServiceTermination.describe(termination(status: 11, bySignal: true)), "ended by signal 11")
    }

    // MARK: - AutoRestart

    func testBackoffGrowsWithTheRestartCount() {
        XCTAssertEqual(AutoRestart.decide(recentFailureCount: 1, restartCount: 0), .restart(after: 2))
        XCTAssertEqual(AutoRestart.decide(recentFailureCount: 2, restartCount: 1), .restart(after: 4))
        XCTAssertEqual(AutoRestart.decide(recentFailureCount: 1, restartCount: 4), .restart(after: 32))
    }

    func testThreeFailuresInTheWindowAreACrashLoop() {
        XCTAssertEqual(AutoRestart.decide(recentFailureCount: 3, restartCount: 2), .crashLoop)
        XCTAssertEqual(AutoRestart.decide(recentFailureCount: 3, restartCount: 0), .crashLoop)
    }

    func testSlowFailuresStopAfterTheMaximum() {
        XCTAssertEqual(AutoRestart.decide(recentFailureCount: 1, restartCount: AutoRestart.maxRestarts), .exhausted)
    }

    /// The loop of 41 Sequin restarts: each automatic restart cleared the history, so
    /// the count never reached three. With the history kept, the third failure stops it.
    func testACrashLoopStopsAtTheThirdFailure() {
        var failures: [Date] = []
        var restartCount = 0
        var restarts = 0
        var now = Date(timeIntervalSince1970: 1_000_000)

        for _ in 0..<50 {
            failures = AutoRestart.recentFailures(failures + [now], now: now)
            guard case .restart(let delay) = AutoRestart.decide(recentFailureCount: failures.count, restartCount: restartCount) else { break }
            restartCount += 1
            restarts += 1
            now = now.addingTimeInterval(delay + 1)
        }

        XCTAssertEqual(restarts, 2)
    }

    func testOldFailuresLeaveTheWindow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let failures = [now.addingTimeInterval(-90), now.addingTimeInterval(-59), now]
        XCTAssertEqual(AutoRestart.recentFailures(failures, now: now).count, 2)
    }

    /// A script that needs two minutes to give up (run-sequin.sh) fails more than 60
    /// seconds apart. It was never ready, so the restart count is not reset, and the
    /// restarts stop at the maximum.
    func testASlowFailureThatWasNeverReadyStopsAtTheMaximum() {
        var restartCount = 0
        var restarts = 0
        for _ in 0..<50 {
            if AutoRestart.startsNewSeries(uptime: nil) { restartCount = 0 }
            guard case .restart = AutoRestart.decide(recentFailureCount: 1, restartCount: restartCount) else { break }
            restartCount += 1
            restarts += 1
        }
        XCTAssertEqual(restarts, AutoRestart.maxRestarts)
    }

    func testAStableRunStartsANewSeries() {
        XCTAssertTrue(AutoRestart.startsNewSeries(uptime: 3600))
        XCTAssertFalse(AutoRestart.startsNewSeries(uptime: 8))
        XCTAssertFalse(AutoRestart.startsNewSeries(uptime: nil))
    }

    // MARK: - CrashCause (lines from the debug issues)

    func testPortInUse() {
        let lines = [
            "> booking-portal@0.2.2 dev",
            "⨯ Failed to start server",
            "Error: listen EADDRINUSE: address already in use :::3002",
            "    at <unknown> (Error: listen EADDRINUSE: address already in use :::3002)",
            "  code: 'EADDRINUSE',",
            " ELIFECYCLE  Command failed with exit code 1.",
        ]
        XCTAssertEqual(CrashCause.likelyCause(in: lines), "Error: listen EADDRINUSE: address already in use :::3002")
    }

    func testAnotherDevServerInTheFolder() {
        let lines = [
            "✓ Ready in 380ms",
            "⨯ Another next dev server is already running.",
            "- Local:        http://localhost:3006",
            "- PID:          57752",
            "- Dir:          /Users/someone/travel-booking-portal",
            "Run kill 57752 to stop it.",
        ]
        XCTAssertEqual(
            CrashCause.likelyCause(in: lines),
            "Another next dev server is already running in this folder (PID 57752)"
        )
    }

    func testContainerRuntimeDown() {
        let lines = [
            "failed to inspect service: Cannot connect to the Docker daemon at unix:///Users/x/.orbstack/run/docker.sock. Is the docker daemon running?",
            "Docker Desktop is a prerequisite for local development.",
        ]
        XCTAssertEqual(
            CrashCause.likelyCause(in: lines),
            "The container runtime is not running (Cannot connect to the Docker daemon)"
        )
        XCTAssertTrue(CrashCause.showsContainerRuntimeDown(lines))
        XCTAssertFalse(CrashCause.showsContainerRuntimeDown(["✓ Ready in 380ms"]))
    }

    func testAScriptThatTheBranchDoesNotHave() {
        let lines = ["zsh:1: no such file or directory: ./scripts/local-cdc/run-sequin.sh"]
        XCTAssertEqual(CrashCause.likelyCause(in: lines), lines[0])
    }

    func testAStrongErrorLineWinsOverALaterWeakOne() {
        let lines = [
            "sequin-1  | ** (RuntimeError) Failed to apply config: Table 'fb_travel.hotel_contract_room_nights' not found",
            "runner-sequin:error: Sequin container exited before readiness",
        ]
        XCTAssertEqual(CrashCause.likelyCause(in: lines), lines[0])
    }

    func testStructuredLogsCountOnlyAtTheErrorLevel() {
        let info = #"{"level":30,"msg":"Auth required — caller may fall back; no error","module":"action"}"#
        let error = #"{"level":50,"msg":"Database connection refused","module":"supabase-connection"}"#
        XCTAssertNil(CrashCause.likelyCause(in: [info]))
        XCTAssertEqual(CrashCause.likelyCause(in: [info, error]), "Database connection refused")
    }

    func testALineThatCanHoldACredentialIsNeverTheCause() {
        XCTAssertNil(CrashCause.likelyCause(in: ["Error: invalid STRIPE_SECRET_KEY sk_test_123"]))
    }

    func testTheRunnersOwnLinesAndStackFramesAreNotACause() {
        XCTAssertNil(CrashCause.likelyCause(in: [
            "[travel-runner] Network mode restart failed",
            "    at Object.error (node:internal/errors:1)",
            " GET /api/health 200 in 81ms",
        ]))
    }
}
