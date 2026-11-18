import Foundation
import XCTest
@testable import TravelRunner

final class HealthSummaryTests: XCTestCase {
    private func service(
        _ id: String, _ phase: ServicePhase, kind: ServiceCondition.Kind? = nil, headline: String? = nil,
        dependsOn: [String] = [], circuitBroken: Bool = false
    ) -> HealthSummary.Service {
        HealthSummary.Service(
            id: id, name: names[id] ?? id, phase: phase, conditionKind: kind, headline: headline,
            dependsOn: dependsOn, isCircuitBroken: circuitBroken
        )
    }

    private let names = [
        "supabase": "Supabase", "booking-portal": "Booking Portal", "partner-portal": "Partner Portal",
        "stripe": "Stripe", "agent": "Agent", "login": "Login",
    ]

    private func compute(
        _ services: [HealthSummary.Service], startInFlight: Bool = false, refusal: String? = nil,
        dbSetupFailure: String? = nil
    ) -> HealthSummary {
        HealthSummary.compute(HealthSummary.Input(
            services: services, startInFlight: startInFlight, refusal: refusal, dbSetupFailure: dbSetupFailure
        ))
    }

    // MARK: - Rule 1: stopped

    func testAllStoppedOrPendingIsStopped() {
        let summary = compute([service("supabase", .stopped), service("booking-portal", .pending)])
        XCTAssertEqual(summary.status, .stopped)
        XCTAssertNil(summary.reason)
        XCTAssertEqual(summary.label, "Stopped")
    }

    func testAStartThatHasNotMovedAServiceYetIsStartingNotStopped() {
        let summary = compute([service("supabase", .pending), service("booking-portal", .pending)], startInFlight: true)
        XCTAssertEqual(summary.status, .starting)
        XCTAssertEqual(summary.label, "Starting...")
    }

    func testNoServicesIsStopped() {
        XCTAssertEqual(compute([]).status, .stopped)
    }

    // MARK: - Refused start

    func testARefusedStartIsNotStartedWithItsReason() {
        let summary = compute(
            [service("supabase", .pending), service("booking-portal", .pending)],
            refusal: "Not started — 2 checks failed"
        )
        XCTAssertTrue(summary.notStarted)
        XCTAssertEqual(summary.label, "Not started")
        XCTAssertEqual(summary.reason, "Not started — 2 checks failed")
        // The wire keeps the four strings: a refused start stays DEGRADED there.
        XCTAssertEqual(summary.status.rawValue, "DEGRADED")
    }

    // MARK: - Rule 2: degraded

    func testAFailedServiceDegradesWithItsNameAndHeadline() {
        let summary = compute([
            service("supabase", .running),
            service("booking-portal", .failed, kind: .failed,
                    headline: "Port 3002 is already in use by another process.", dependsOn: ["supabase"]),
        ])
        XCTAssertEqual(summary.status, .degraded)
        XCTAssertEqual(summary.reason, "Booking Portal failed: Port 3002 is already in use by another process")
        XCTAssertEqual(summary.rootCauseID, "booking-portal")
        XCTAssertEqual(summary.label, "1 Failing")
    }

    func testTheRootCauseIsTheFailureWhoseDependenciesDidNotFail() {
        let summary = compute([
            service("booking-portal", .failed, headline: "Booking Portal exited with code 1.", dependsOn: ["supabase"]),
            service("supabase", .failed, headline: "OrbStack is not running."),
        ])
        XCTAssertEqual(summary.rootCauseID, "supabase")
        XCTAssertEqual(summary.reason, "Supabase failed: OrbStack is not running (+1 more)")
        XCTAssertEqual(summary.label, "2 Failing")
    }

    func testAFailureWinsOverAStartInFlight() {
        let summary = compute(
            [service("supabase", .failed, headline: "OrbStack is not running."), service("booking-portal", .pending)],
            startInFlight: true
        )
        XCTAssertEqual(summary.status, .degraded)
    }

    func testAFailedServiceWithNoConditionStillHasAReason() {
        XCTAssertEqual(compute([service("login", .failed)]).reason, "Login failed: it stopped")
    }

    func testAFailedDatabaseSetupDegradesWithTheStep() {
        let summary = compute(
            [service("supabase", .running), service("booking-portal", .pending)],
            dbSetupFailure: "Database setup failed at Load hotels"
        )
        XCTAssertEqual(summary.status, .degraded)
        XCTAssertEqual(summary.reason, "Database setup failed at Load hotels")
        XCTAssertEqual(summary.label, "Degraded")
        XCTAssertNil(summary.rootCauseID)
    }

    // MARK: - Rule 3: starting

    func testAServiceThatStartsOrStopsKeepsTheStackStarting() {
        for phase in [ServicePhase.starting, .stopping] {
            let summary = compute([service("supabase", .running), service("booking-portal", phase)])
            XCTAssertEqual(summary.status, .starting, phase.rawValue)
            XCTAssertNil(summary.reason)
        }
    }

    // MARK: - Rule 4: healthy, with a note

    func testAllRunningIsAllOK() {
        let summary = compute([service("supabase", .running), service("booking-portal", .running)])
        XCTAssertEqual(summary.status, .healthy)
        XCTAssertNil(summary.reason)
        XCTAssertEqual(summary.label, "All OK")
    }

    func testSkippedServicesAreNamedWithTheirReason() {
        let summary = compute([
            service("supabase", .running),
            service("stripe", .skipped, kind: .optionalOff, headline: "Stripe CLI login expired — webhooks are off."),
            service("agent", .skipped, kind: .optionalOff, headline: "Agent repo not found."),
        ])
        XCTAssertEqual(summary.status, .healthy)
        XCTAssertEqual(
            summary.reason,
            "2 skipped: Stripe (Stripe CLI login expired — webhooks are off), Agent (Agent repo not found)"
        )
        XCTAssertEqual(summary.label, "OK · 2 services off")
    }

    func testAnOfflineStripeIsNotDegradedButTheHeaderSaysSo() {
        let summary = compute([
            service("supabase", .running),
            service("stripe", .skipped, kind: .optionalOff,
                    headline: "No network — Stripe reconnects when the network is back."),
        ])
        XCTAssertEqual(summary.status, .healthy)
        XCTAssertEqual(summary.label, "OK · Stripe webhooks off")
    }

    func testAServiceOutsideTheProfileIsNotANote() {
        let summary = compute([
            service("supabase", .running),
            service("partner-portal", .skipped, kind: .notInProfile, headline: "Not in the Booking profile."),
        ])
        XCTAssertEqual(summary.label, "All OK")
        XCTAssertNil(summary.reason)
    }

    /// Before, a stopped daemon next to running ones left the stack STARTING forever.
    func testAStoppedServiceNextToRunningOnesIsHealthyWithANote() {
        let summary = compute([service("supabase", .running), service("agent", .stopped)])
        XCTAssertEqual(summary.status, .healthy)
        XCTAssertEqual(summary.reason, "1 stopped: Agent")
        XCTAssertEqual(summary.label, "OK · Agent off")
    }

    func testSkippedAndStoppedNotesAreJoined() {
        let summary = compute([
            service("supabase", .running),
            service("stripe", .skipped, kind: .optionalOff, headline: "Stripe CLI not installed."),
            service("agent", .stopped),
        ])
        XCTAssertEqual(summary.reason, "1 skipped: Stripe (Stripe CLI not installed); 1 stopped: Agent")
    }

    func testAStartInFlightWithAllServicesUpIsStillStarting() {
        let summary = compute([service("supabase", .running)], startInFlight: true)
        XCTAssertEqual(summary.status, .starting)
    }
}
