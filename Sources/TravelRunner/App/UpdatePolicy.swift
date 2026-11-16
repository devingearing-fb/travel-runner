import Foundation

/// An update that waits for the user.
enum PendingUpdate: Equatable, Sendable {
    /// Downloaded. A restart installs it.
    case ready(version: String)
    /// Found, but not downloaded. Sparkle's own window installs it.
    case available(version: String)
}

/// The update rules that do not need Sparkle, so the tests can run them.
enum UpdatePolicy {
    /// Set after the one-time switch to automatic downloads.
    static let didDefaultAutoUpdateKey = "didDefaultAutoUpdate_v1"

    /// Turn automatic downloads on once per install. Installed copies already store
    /// `SUAutomaticallyUpdate = 0`, so a default in Info.plist changes nothing for them.
    /// A later choice by the user stays, because this runs only once.
    /// A dev build keeps the prompt and leaves the flag for the release copy.
    static func applyAutoUpdateDefault(
        defaults: UserDefaults,
        build: BuildInfo,
        enable: () -> Void
    ) {
        guard !build.isDev, !defaults.bool(forKey: didDefaultAutoUpdateKey) else { return }
        enable()
        defaults.set(true, forKey: didDefaultAutoUpdateKey)
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
}
