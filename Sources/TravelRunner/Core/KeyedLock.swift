import Foundation

/// One holder per key at a time; callers wait in the order they asked.
///
/// The supervisor uses it for the stop and start of one service. Without it, two
/// requests for one service (a restart from the API and one after a crash, or two
/// wake notifications) each start a process, and the second fails on the port.
@MainActor
final class KeyedLock {
    /// A key is present while it is held. The array holds the callers that wait.
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func isLocked(_ key: String) -> Bool {
        waiters[key] != nil
    }

    func withLock<T>(_ key: String, _ body: () async throws -> T) async rethrows -> T {
        await acquire(key)
        defer { release(key) }
        return try await body()
    }

    private func acquire(_ key: String) async {
        guard waiters[key] != nil else {
            waiters[key] = []
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key]?.append(continuation)
        }
    }

    private func release(_ key: String) {
        guard var queue = waiters[key] else { return }
        if queue.isEmpty {
            waiters.removeValue(forKey: key)
        } else {
            // The lock passes to the next caller without a moment where it is free.
            let next = queue.removeFirst()
            waiters[key] = queue
            next.resume()
        }
    }
}
