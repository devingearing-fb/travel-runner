import XCTest
@testable import TravelRunner

/// The texts of a crash notification, the toasts that stay, and Recent activity.
@MainActor
final class ActionFeedbackTests: XCTestCase {
    private func alert(cause: String?, next: CrashAlert.Next) -> CrashAlert {
        CrashAlert(serviceID: "travel-portal", name: "Booking Portal", exitCode: 1, cause: cause, next: next)
    }

    func testTheCrashNotificationSaysTheCauseAndWhatComesNext() {
        XCTAssertEqual(alert(cause: nil, next: .none).title, "Booking Portal crashed")
        XCTAssertEqual(
            alert(cause: "Port 3002 is already in use", next: .restarting(attempt: 1)).body,
            "Port 3002 is already in use. Restarting (attempt 1)."
        )
        XCTAssertEqual(alert(cause: nil, next: .restarting(attempt: 2)).body, "Exited with code 1. Restarting (attempt 2).")
        XCTAssertEqual(
            alert(cause: "Docker Desktop is not running.", next: .autoRestartStopped).body,
            "Docker Desktop is not running. Auto-restart stopped."
        )
        XCTAssertEqual(alert(cause: "zsh: command not found: pnpm", next: .none).body, "zsh: command not found: pnpm.")
    }

    func testWhatComesAfterACrash() {
        XCTAssertEqual(
            CrashAlert.Next.after(circuitBroken: true, restarts: true, phase: .failed, restartCount: 2),
            .autoRestartStopped
        )
        XCTAssertEqual(
            CrashAlert.Next.after(circuitBroken: false, restarts: true, phase: .failed, restartCount: 1),
            .restarting(attempt: 2)
        )
        // A skipped service (an exhausted Stripe) and a service that does not restart.
        XCTAssertEqual(CrashAlert.Next.after(circuitBroken: false, restarts: true, phase: .skipped, restartCount: 0), .none)
        XCTAssertEqual(CrashAlert.Next.after(circuitBroken: false, restarts: false, phase: .failed, restartCount: 0), .none)
    }

    func testAnErrorToastStaysUntilItIsClosed() {
        XCTAssertNil(ToastCenter.duration(for: .error))
        XCTAssertEqual(ToastCenter.duration(for: .success), .seconds(4))
        XCTAssertEqual(ToastCenter.duration(for: .info), .seconds(4))
    }

    func testAFullToastStackDropsAShortLivedToastBeforeAnError() {
        let center = ToastCenter()
        center.show("Booking Portal restart failed", style: .error, serviceID: "travel-portal")
        center.show("Login restarted", style: .success)
        center.show("Partner Portal restart failed", style: .error)
        center.show("A start is already in progress.", style: .info)
        XCTAssertEqual(
            center.toasts.map(\.message),
            ["Booking Portal restart failed", "Partner Portal restart failed", "A start is already in progress."]
        )
    }

    func testAClickOnAnErrorToastOpensItAndClosesIt() throws {
        let center = ToastCenter()
        var opened: [String?] = []
        center.onOpen = { opened.append($0.serviceID) }
        center.show("Booking Portal restart failed", style: .error, serviceID: "travel-portal")
        let toast = try XCTUnwrap(center.toasts.first)
        XCTAssertTrue(toast.opensTriage)

        center.open(toast)

        XCTAssertEqual(opened, ["travel-portal"])
        XCTAssertTrue(center.toasts.isEmpty)
    }

    func testRecentActivityKeepsTheNewestFirstUpToItsLimit() {
        var activity = RecentActivity()
        for index in 0..<(RecentActivity.limit + 5) {
            activity.add(ActionFeedback(message: "\(index)", style: .info, at: Date()))
        }
        XCTAssertEqual(activity.entries.count, RecentActivity.limit)
        XCTAssertEqual(activity.entries.first?.message, "\(RecentActivity.limit + 4)")
        XCTAssertEqual(activity.entries.last?.message, "5")
    }
}
