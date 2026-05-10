import AppKit

@MainActor
final class SleepWakeObserver {
    private var observation: (any NSObjectProtocol)?
    private let onWake: @MainActor () -> Void

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
                self?.onWake()
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
