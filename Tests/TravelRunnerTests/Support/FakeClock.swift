import Foundation
@testable import TravelRunner

/// The time of a test. It moves only when code waits on the clock, so a wait
/// of a minute takes no real time.
///
/// Give `clock` only to code where every awaited thing is a fake. A wait
/// returns at once, so a loop that waits for something real (a process, a
/// port, a probe) runs out before the real thing answers, and a loop without
/// an end spins. A test with a real process takes `stampsOnly`.
final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start: Date
    private var elapsed: Duration = .zero
    private var recorded: [Duration] = []

    init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.start = start
    }

    /// The waits so far, in order.
    var sleeps: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        let (seconds, attoseconds) = elapsed.components
        return start.addingTimeInterval(Double(seconds) + Double(attoseconds) / 1e18)
    }

    var uptime: Duration {
        lock.lock()
        defer { lock.unlock() }
        return elapsed
    }

    /// Moves the time without a wait.
    func advance(by duration: Duration) {
        lock.lock()
        elapsed += duration
        lock.unlock()
    }

    private func slept(_ duration: Duration) {
        lock.lock()
        elapsed += duration
        recorded.append(duration)
        lock.unlock()
    }

    /// The clock to give to the code under test.
    var clock: RunnerClock {
        RunnerClock(
            date: { self.now },
            uptime: { self.uptime },
            wait: { duration in
                try Task.checkCancellation()
                self.slept(duration)
                // Lets the other tasks run, as a real wait does.
                await Task.yield()
            }
        )
    }

    /// The clock for a test with a real process: the time stamps come from the
    /// test, the waits and the deadlines stay real.
    var stampsOnly: RunnerClock {
        RunnerClock(date: { self.now }, uptime: RunnerClock.live.uptime, wait: RunnerClock.live.wait)
    }
}
