import Foundation

/// The time that the supervisor reads and waits on. `live` is the real time.
/// Tests give a fake, so a wait of a minute takes no real time.
struct RunnerClock: Sendable {
    /// The time of day, for the time stamps that people read.
    var date: @Sendable () -> Date
    /// The time since a fixed start. It never goes back, so deadlines use it.
    var uptime: @Sendable () -> Duration
    /// Waits. It throws when the task is cancelled, like `Task.sleep`.
    var wait: @Sendable (Duration) async throws -> Void

    func sleep(for duration: Duration) async throws {
        try await wait(duration)
    }

    private static let start = ContinuousClock.now

    static let live = RunnerClock(
        date: { Date() },
        uptime: { start.duration(to: .now) },
        wait: { try await Task.sleep(for: $0) }
    )

    private static let awakeStart = SuspendingClock.now

    /// Real time that stops while the Mac sleeps. A step that runs when the lid
    /// closes has used no time of its limit when the Mac wakes.
    static let awake = RunnerClock(
        date: { Date() },
        uptime: { awakeStart.duration(to: .now) },
        wait: { try await SuspendingClock().sleep(for: $0) }
    )
}
