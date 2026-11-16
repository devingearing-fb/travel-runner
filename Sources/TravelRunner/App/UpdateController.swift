import Foundation
import Observation
import Sparkle

@Observable
@MainActor
final class UpdateController: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    @ObservationIgnored private var updaterController: SPUStandardUpdaterController!
    /// Sparkle's handler that installs the downloaded update and relaunches the app.
    @ObservationIgnored private var installHandler: (() -> Void)?

    /// The update the header pill shows. `nil` when there is none.
    private(set) var pending: PendingUpdate?

    var updater: SPUUpdater { updaterController.updater }

    override init() {
        super.init()
        // A menu-bar app has no window where Sparkle's prompt is seen, so this class
        // is the delegate and shows a pending update in the header.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        let updater = updaterController.updater
        UpdatePolicy.applyAutoUpdateDefault(defaults: .standard, build: .current) {
            updater.automaticallyDownloadsUpdates = true
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }

    /// Install the downloaded update and relaunch. The app quits the normal way, so the stack stops.
    func installAndRestart() {
        installHandler?()
    }

    // MARK: - SPUUpdaterDelegate

    /// An update was downloaded in the background. Sparkle installs it at quit;
    /// the pill lets the user install it now.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        installHandler = immediateInstallHandler
        pending = .ready(version: item.displayVersionString)
        return true
    }

    // MARK: - SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle found an update in a scheduled check and shows its window, maybe behind other apps.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        pending = .available(version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearAvailable()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearAvailable()
    }

    /// A downloaded update stays in the pill until the restart.
    private func clearAvailable() {
        if case .available = pending { pending = nil }
    }
}
