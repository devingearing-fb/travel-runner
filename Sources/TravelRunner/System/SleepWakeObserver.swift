import AppKit

@MainActor
final class SleepWakeObserver {
    private var observation: (any NSObjectProtocol)?
    private let onWake: @MainActor () -> Void
    private var lastWakeAt: Date?

    init(onWake: @escaping @MainActor () -> Void) {
        self.onWake = onWake
    }

    func startObserving() {
        observation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let now = Date.now
                if let last = self.lastWakeAt, now.timeIntervalSince(last) < 5 { return }
                self.lastWakeAt = now
                self.onWake()
            }
        }
    }

    func stopObserving() {
        if let obs = observation {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            observation = nil
        }
    }
}
