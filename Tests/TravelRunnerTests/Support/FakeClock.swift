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

    /// Moves the time without a wait. The waits of `held` that end by then return.
    func advance(by duration: Duration) {
        lock.lock()
        elapsed += duration
        let due = held.filter { $0.value.deadline <= elapsed }
        for id in due.keys { held[id] = nil }
        lock.unlock()
        for waiter in due.values { waiter.resume.resume() }
    }

    private var held: [UUID: (deadline: Duration, resume: CheckedContinuation<Void, Error>)] = [:]

    /// The waits of `held` that have not ended.
    var heldWaits: Int {
        lock.lock()
        defer { lock.unlock() }
        return held.count
    }

    private func holdUntil(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    resume.resume(throwing: CancellationError())
                    return
                }
                recorded.append(duration)
                held[id] = (elapsed + duration, resume)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = held.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume.resume(throwing: CancellationError())
        }
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

    /// The clock for a test that moves the time by hand: a wait returns only
    /// when `advance(by:)` reaches its end, or throws when its task is cancelled.
    var manual: RunnerClock {
        RunnerClock(date: { self.now }, uptime: { self.uptime }, wait: { try await self.holdUntil($0) })
    }

    /// The clock for a test with a real process: the time stamps come from the
    /// test, the waits and the deadlines stay real.
    var stampsOnly: RunnerClock {
        RunnerClock(date: { self.now }, uptime: RunnerClock.live.uptime, wait: RunnerClock.live.wait)
    }
}
