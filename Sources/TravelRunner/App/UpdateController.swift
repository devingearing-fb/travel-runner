import Foundation
import Sparkle

@MainActor
final class UpdateController {
    private let updaterController: SPUStandardUpdaterController

    var updater: SPUUpdater { updaterController.updater }

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        updater.canCheckForUpdates
    }
}
