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
    /// A copy of Sparkle's `canCheckForUpdates` that SwiftUI can observe.
    private(set) var canCheckForUpdates = false
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

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
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            } else {
                Task { @MainActor in self?.canCheckForUpdates = value }
            }
        }
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    /// Install the downloaded update and relaunch. The app quits the normal way, so the stack stops.
    func installAndRestart() {
        guard let installHandler else {
            // Sparkle dropped the download. Show its window, so the user sees what is true now.
            pending = nil
            checkForUpdates()
            return
        }
        installHandler()
    }

    // MARK: - SPUUpdaterDelegate

    /// Nil keeps the feed of Info.plist. A copy on the canary channel reads the canary feed.
    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdatePolicy.feedURL(defaults: .standard, flavor: .current)
    }

    /// An update was downloaded in the background. Sparkle installs it at quit;
    /// the pill lets the user install it now.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        installHandler = immediateInstallHandler
        apply(.downloaded(version: item.displayVersionString))
        return true
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate updateItem: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        let allowed = UpdatePolicy.mayProceed(
            isDev: BuildInfo.current.isDev,
            backgroundCheck: updateCheck == .updatesInBackground,
            automaticDownloads: updater.automaticallyDownloadsUpdates
        )
        guard !allowed else { return }
        throw NSError(
            domain: "TravelRunner.Update",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "A dev build does not install updates in the background."]
        )
    }

    /// The cycle failed, for example the installer is gone. Sparkle's install handler is dead now.
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        endCycle()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        endCycle()
    }

    private func endCycle() {
        installHandler = nil
        apply(.cycleEnded)
    }

    private func apply(_ event: UpdateEvent) {
        pending = UpdatePolicy.pending(pending, after: event)
    }

    // MARK: - SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle found an update in a scheduled check and shows its window, maybe behind other apps.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        apply(.found(version: update.displayVersionString, userInitiated: state.userInitiated))
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        apply(.seen)
    }

    func standardUserDriverWillFinishUpdateSession() {
        apply(.windowSessionEnded)
    }
}
