import Foundation

/// An update that waits for the user.
enum PendingUpdate: Equatable, Sendable {
    /// Downloaded. A restart installs it.
    case ready(version: String)
    /// Found, but not downloaded. Sparkle's own window installs it.
    case available(version: String)
}

/// What Sparkle reports about an update. `UpdateController` maps its delegate calls to these.
enum UpdateEvent: Equatable, Sendable {
    /// An update was downloaded in the background and waits for a restart.
    case downloaded(version: String)
    /// A check found an update and Sparkle shows its window.
    case found(version: String, userInitiated: Bool)
    /// The user saw Sparkle's window.
    case seen
    /// Sparkle's window closed.
    case windowSessionEnded
    /// The update cycle ended. Sparkle's handler for the downloaded update is dead after this.
    case cycleEnded
}

/// What a click on the pill does.
enum PillAction: Equatable, Sendable {
    /// Open Sparkle's window.
    case showUpdateWindow
    /// Install and restart at once.
    case install
    /// Ask first, with this text.
    case ask(String)
    /// Do nothing, for this reason.
    case blocked(String)
}

/// The update rules that do not need Sparkle, so the tests can run them.
enum UpdatePolicy {
    /// Set after the one-time switch to automatic downloads.
    static let didDefaultAutoUpdateKey = "didDefaultAutoUpdate_v1"

    /// Turn automatic downloads on once per install. Installed copies already store
    /// `SUAutomaticallyUpdate = 0`, so a default in Info.plist changes nothing for them.
    /// A later choice by the user stays, because this runs only once.
    /// A dev build leaves the flag for the release copy. It shares the defaults of the
    /// release copy, so it can still read the setting: see `mayProceed`.
    static func applyAutoUpdateDefault(
        defaults: UserDefaults,
        build: BuildInfo,
        enable: () -> Void
    ) {
        guard !build.isDev, !defaults.bool(forKey: didDefaultAutoUpdateKey) else { return }
        enable()
        defaults.set(true, forKey: didDefaultAutoUpdateKey)
    }

    /// `defaults write ai.fastbreak.travel-runner updateChannel canary` puts a copy
    /// on the canary channel. Any other value, or none, is the normal channel.
    static let channelKey = "updateChannel"
    static let canaryChannel = "canary"
    /// The fixed release that holds the appcast of the newest release, promoted or not (`release.sh`).
    static let canaryFeedURL = "https://github.com/devingearing-fb/travel-runner/releases/download/canary-appcast/appcast.xml"

    /// The feed of a copy on the canary channel, or nil for the feed in Info.plist.
    /// A new release goes to the canary feed first; `release.sh --promote` gives it
    /// to everyone. The hackathon app has one feed and no canary.
    static func feedURL(defaults: UserDefaults, flavor: Flavor) -> String? {
        guard flavor == .standard, defaults.string(forKey: channelKey) == canaryChannel else { return nil }
        return canaryFeedURL
    }

    /// The text of the pill in the header.
    static func pillText(_ update: PendingUpdate) -> String {
        switch update {
        case .ready(let version): "Update \(version) ready — Restart to install"
        case .available(let version): "Update \(version) available"
        }
    }

    /// What a restart costs while services run. `nil` when the stack is stopped: no question then.
    static func restartWarning(liveServices: Int) -> String? {
        guard liveServices > 0 else { return nil }
        let services = liveServices == 1 ? "1 service" : "\(liveServices) services"
        return "Restarting stops the running stack (\(services)). Supabase keeps running."
    }

    /// A dev build does not install an update in the background: the release would replace
    /// it at quit, with no notice. "Check for Updates…" still works in a dev build.
    static func mayProceed(isDev: Bool, backgroundCheck: Bool, automaticDownloads: Bool) -> Bool {
        !(isDev && backgroundCheck && automaticDownloads)
    }

    /// The pending update after an event from Sparkle.
    static func pending(_ current: PendingUpdate?, after event: UpdateEvent) -> PendingUpdate? {
        switch event {
        case .downloaded(let version):
            return .ready(version: version)
        case .found(let version, let userInitiated):
            // The user asked for the check and looks at Sparkle's window: no pill.
            return userInitiated ? current : .available(version: version)
        case .seen, .windowSessionEnded:
            // A downloaded update stays in the pill until the restart.
            if case .available = current { return nil }
            return current
        case .cycleEnded:
            return nil
        }
    }

    /// Why a restart must wait. `nil` when a restart is safe.
    /// A restart in the middle of a database reset or setup leaves the database half built.
    static func restartBlockedReason(dbResetRunning: Bool, setupPipelineRunning: Bool) -> String? {
        if dbResetRunning { return "A database reset is running. Restart after it ends." }
        if setupPipelineRunning { return "A database setup is running. Restart after it ends." }
        return nil
    }

    /// What a click on the pill does.
    static func pillAction(pending: PendingUpdate, liveServices: Int, blockedReason: String?) -> PillAction {
        if let blockedReason { return .blocked(blockedReason) }
        switch pending {
        case .available:
            return .showUpdateWindow
        case .ready:
            if let warning = restartWarning(liveServices: liveServices) { return .ask(warning) }
            return .install
        }
    }
}
