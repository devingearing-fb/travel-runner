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
    /// The banner after 7 days behind the newest release. `nil` before then.
    private(set) var behindNotice: String?
    @ObservationIgnored private var behind: UpdatePolicy.BehindRecord?

    /// What a restart would interrupt now. Without it the app never restarts by itself.
    @ObservationIgnored var restartState: (@MainActor () async -> UpdatePolicy.RestartState)?
    @ObservationIgnored private var idleTicks = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private let build: BuildInfo
    @ObservationIgnored private let defaults: UserDefaults

    var updater: SPUUpdater { updaterController.updater }

    init(build: BuildInfo = .current, defaults: UserDefaults = .standard) {
        self.build = build
        self.defaults = defaults
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
        if let current = build.version, !build.isDev {
            behind = UpdatePolicy.storedBehind(defaults: defaults, current: current)
        }
        refreshBehindNotice()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: UpdatePolicy.tickInterval)
                await self?.tick()
            }
        }
    }

    /// Runs once a minute: the banner may be due, and a downloaded update may install now.
    private func tick() async {
        refreshBehindNotice()
        await restartIfIdle()
    }

    /// Installs a downloaded update when nothing would be interrupted: the stack is
    /// stopped, the window is closed, and no database step, fix or reconfigure runs.
    private func restartIfIdle() async {
        guard case .ready = pending, installHandler != nil, let restartState else {
            idleTicks = 0
            return
        }
        let state = await restartState()
        let idle = UpdatePolicy.mayRestartUnattended(state, isDev: build.isDev)
        idleTicks = UpdatePolicy.idleTicks(after: idleTicks, idle: idle)
        // The update may have gone while the state was read.
        guard idleTicks >= UpdatePolicy.idleTicksBeforeRestart, case .ready = pending, let installHandler else { return }
        idleTicks = 0
        installHandler()
    }

    private func refreshBehindNotice() {
        behindNotice = UpdatePolicy.behindNotice(behind, appName: build.flavor.displayName, now: Date())
    }

    /// A check found `item` as the newest version. A dev build keeps no record: its
    /// version is not a release.
    private func noteLatest(_ item: SUAppcastItem) {
        guard !build.isDev, let current = build.version else { return }
        behind = UpdatePolicy.recordLatest(
            defaults: defaults,
            current: current,
            latest: item.displayVersionString,
            released: item.propertiesDictionary[UpdatePolicy.releasedVersionsElement] as? String,
            now: Date()
        )
        refreshBehindNotice()
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

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        noteLatest(item)
    }

    /// This copy is the newest version.
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        guard !build.isDev else { return }
        behind = nil
        UpdatePolicy.clearBehind(defaults: defaults)
        refreshBehindNotice()
    }

    /// An update was downloaded in the background. Sparkle installs it at quit;
    /// the pill lets the user install it now, and an idle app installs it by itself.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        installHandler = immediateInstallHandler
        idleTicks = 0
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
