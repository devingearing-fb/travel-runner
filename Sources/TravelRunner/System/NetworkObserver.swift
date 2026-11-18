import Foundation
import Network

/// Tells the supervisor that the network of the Mac changed. A move between
/// networks sends several path updates in a few seconds, so it reports once,
/// after the path was quiet for the debounce time.
@MainActor
final class NetworkObserver {
    static let defaultDebounce: Duration = .seconds(5)

    private let debounce: Duration
    private let clock: RunnerClock
    private let onChange: @MainActor () -> Void
    private var monitor: NWPathMonitor?
    private var pending: Task<Void, Never>?
    private var sawFirstPath = false

    init(debounce: Duration = NetworkObserver.defaultDebounce, clock: RunnerClock = .live, onChange: @escaping @MainActor () -> Void) {
        self.debounce = debounce
        self.clock = clock
        self.onChange = onChange
    }

    func startObserving() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.pathUpdated() }
        }
        monitor.start(queue: DispatchQueue(label: "travel-runner.network-observer"))
        self.monitor = monitor
    }

    func stopObserving() {
        monitor?.cancel()
        monitor = nil
        pending?.cancel()
        pending = nil
        sawFirstPath = false
    }

    /// The monitor sends the current path when it starts. That is no change.
    func pathUpdated() {
        guard sawFirstPath else {
            sawFirstPath = true
            return
        }
        pathChanged()
    }

    /// Starts the debounce again. `onChange` runs when no change came for the debounce time.
    func pathChanged() {
        pending?.cancel()
        let clock = clock
        let debounce = debounce
        pending = Task { [weak self] in
            do { try await clock.sleep(for: debounce) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.pending = nil
            self.onChange()
        }
    }
}
