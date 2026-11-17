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

    /// What a click on the pill, or on "Update now", does.
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

    // MARK: - Restart without a click

    /// What a restart of the app would interrupt now.
    struct RestartState: Equatable, Sendable {
        /// A service, a start, a stop or an action of the stack runs, or the holds viewer does.
        var stackRunning = false
        /// The window is open: somebody may be working in it.
        var panelOpen = false
        /// A database reset or setup runs.
        var databaseBusy = false
        /// A fix of the setup checks runs.
        var fixRunning = false
        /// New paths are being applied.
        var reconfigureRunning = false
        /// A problem report saves its zip, or `/api/preflight` runs its checks.
        var otherWorkRunning = false
    }

    /// How often the update controller looks at the app's state.
    static let tickInterval: Duration = .seconds(60)
    /// The app must be idle at this many ticks in a row before it restarts by itself.
    /// Somebody who just stopped the stack may start it again a moment later.
    static let idleTicksBeforeRestart = 2

    /// A downloaded update installs and relaunches without a click only when nothing
    /// would be interrupted. A dev build never does: the release would replace it.
    static func mayRestartUnattended(_ state: RestartState, isDev: Bool) -> Bool {
        guard !isDev else { return false }
        return !state.stackRunning && !state.panelOpen && !state.databaseBusy
            && !state.fixRunning && !state.reconfigureRunning && !state.otherWorkRunning
    }

    /// The idle restart needs a downloaded update and Sparkle's handler that installs it.
    static func canInstallUnattended(_ pending: PendingUpdate?, hasInstallHandler: Bool) -> Bool {
        guard case .ready = pending else { return false }
        return hasInstallHandler
    }

    /// The idle ticks in a row after this tick. The restart runs at `idleTicksBeforeRestart`.
    static func idleTicks(after previous: Int, idle: Bool) -> Int {
        idle ? previous + 1 : 0
    }

    // MARK: - Versions behind

    /// The element of the appcast item that lists the released versions (`release.sh`),
    /// separated by spaces. Sparkle keeps an element of another namespace under its full name.
    static let releasedVersionsElement = "travelrunner:releasedVersions"
    /// Where the app keeps what it knows about the newest version.
    static let behindKey = "updateBehind_v1"
    /// How long a newer version waits before the banner asks for the update.
    static let behindNoticeDelay: TimeInterval = 7 * 24 * 60 * 60

    /// This copy is behind the newest release, since `since`.
    struct BehindRecord: Codable, Equatable, Sendable {
        /// The version of this copy when the newer version was first seen.
        var current: String
        var latest: String
        var versionsBehind: Int
        var since: Date
    }

    /// The released versions above `current`, up to `latest`. An appcast without the
    /// list (older than this release) counts as one version. 0 when `latest` is not newer.
    static func versionsBehind(current: String, latest: String, released: String?) -> Int {
        guard let mine = Compatibility.Version(runner: current),
              let newest = Compatibility.Version(runner: latest),
              mine < newest else { return 0 }
        let versions = Set((released ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
            .compactMap { Compatibility.Version(manifest: $0) }
        let between = versions.filter { mine < $0 && $0 <= newest }.count
        return max(1, between)
    }

    /// Records the newest version that a check found. The date of the first finding stays
    /// while this copy keeps its version, so the banner comes 7 days after it.
    /// Returns nil, and forgets the record, when this copy is up to date.
    static func recordLatest(
        defaults: UserDefaults,
        current: String,
        latest: String,
        released: String?,
        now: Date
    ) -> BehindRecord? {
        let count = versionsBehind(current: current, latest: latest, released: released)
        guard count > 0 else {
            defaults.removeObject(forKey: behindKey)
            return nil
        }
        let since = storedBehind(defaults: defaults, current: current)?.since ?? now
        let record = BehindRecord(current: current, latest: latest, versionsBehind: count, since: since)
        if let data = try? JSONEncoder().encode(record) { defaults.set(data, forKey: behindKey) }
        return record
    }

    /// The record of an earlier run. A copy with a new version forgets it: it was updated.
    static func storedBehind(defaults: UserDefaults, current: String) -> BehindRecord? {
        guard let data = defaults.data(forKey: behindKey),
              let record = try? JSONDecoder().decode(BehindRecord.self, from: data) else { return nil }
        guard record.current == current else {
            defaults.removeObject(forKey: behindKey)
            return nil
        }
        return record
    }

    /// Forgets the record: a check found no newer version.
    static func clearBehind(defaults: UserDefaults) {
        defaults.removeObject(forKey: behindKey)
    }

    /// The banner text, 7 days after a newer version was first seen. `nil` before then.
    static func behindNotice(_ record: BehindRecord?, appName: String, now: Date) -> String? {
        guard let record, record.versionsBehind > 0,
              now.timeIntervalSince(record.since) >= behindNoticeDelay else { return nil }
        let versions = record.versionsBehind == 1 ? "1 version" : "\(record.versionsBehind) versions"
        return "This \(appName) is \(versions) behind (you: \(record.current), latest: \(record.latest)). "
            + "Old versions can mis-handle the database."
    }
}
