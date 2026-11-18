import Foundation

/// The place a notice belongs to. Each key holds at most one live notice, so a
/// new problem of one place replaces its old one and leaves the others alone.
enum NoticeKey: Hashable, Sendable {
    /// A service failed. It resolves when the service runs again.
    case service(String)
    /// A DB setup or reset failed, or could not start.
    case dbSetup
    /// A DB setup runs. It resolves when the setup ends.
    case dbProgress
    case preflight
    /// The other runner app holds the stack.
    case siblingRunner
    /// The registry of secrets did not start.
    case secretRegistry
    case dbMode
    /// LAN mode could not restart an app.
    case lan
    /// The profile could not be saved.
    case profile
    /// The config could not be loaded or applied.
    case config

    var id: String {
        switch self {
        case .service(let serviceID): "service:\(serviceID)"
        case .dbSetup: "db-setup"
        case .dbProgress: "db-progress"
        case .preflight: "preflight"
        case .siblingRunner: "sibling-runner"
        case .secretRegistry: "secret-registry"
        case .dbMode: "db-mode"
        case .lan: "lan"
        case .profile: "profile"
        case .config: "config"
        }
    }

    /// A start or a stop of the stack makes the notice stale. The profile and the
    /// config are not part of the stack, so their notices stay.
    var endsWithStack: Bool {
        switch self {
        case .profile, .config: false
        default: true
        }
    }
}

/// One message for the header: what went wrong, or what runs now.
struct Notice: Equatable, Sendable, Identifiable {
    enum Severity: Equatable, Sendable {
        case error
        /// Progress, such as a DB setup that runs.
        case info
    }

    let key: NoticeKey
    let severity: Severity
    let text: String
    let since: Date

    var id: String { key.id }
}

/// The live notices, one per key, the newest first. It replaces the one global
/// error slot: a notice resolves on its own key, and a new one hides no other.
struct NoticeCenter: Equatable, Sendable {
    /// The header shows this many; the rest are in Status.
    static let headerLimit = 3

    /// The newest first.
    private(set) var all: [Notice] = []

    /// Sets the notice of `key`. The same text again keeps its first time; an error
    /// moves to the front, so `newestError` is the error that happened last.
    /// `atFront` false puts it last: a later failure of a start keeps the first
    /// failure as the newest error.
    mutating func post(
        _ key: NoticeKey, _ text: String, severity: Notice.Severity = .error, now: Date = Date(), atFront: Bool = true
    ) {
        if let index = all.firstIndex(where: { $0.key == key }),
           all[index].text == text, all[index].severity == severity {
            if severity == .error, atFront { all.insert(all.remove(at: index), at: 0) }
            return
        }
        all.removeAll { $0.key == key }
        let notice = Notice(key: key, severity: severity, text: text, since: now)
        if atFront { all.insert(notice, at: 0) } else { all.append(notice) }
    }

    /// The problem is gone.
    mutating func resolve(_ key: NoticeKey) {
        all.removeAll { $0.key == key }
    }

    /// Resolves the notice of `key` only while it still says `text`. A newer one stays.
    mutating func resolve(_ key: NoticeKey, ifText text: String) {
        all.removeAll { $0.key == key && $0.text == text }
    }

    mutating func resolveAll(where shouldResolve: (NoticeKey) -> Bool) {
        all.removeAll { shouldResolve($0.key) }
    }

    /// The person closed it. It comes back only with a new post.
    mutating func dismiss(_ key: NoticeKey) {
        resolve(key)
    }

    func notice(_ key: NoticeKey) -> Notice? {
        all.first { $0.key == key }
    }

    func text(_ key: NoticeKey) -> String? {
        notice(key)?.text
    }

    /// The newest error, the old single "last error".
    var newestError: Notice? {
        all.first { $0.severity == .error }
    }

    /// The notices the header shows, and how many it leaves to Status.
    var header: (shown: [Notice], more: Int) {
        (Array(all.prefix(Self.headerLimit)), max(0, all.count - Self.headerLimit))
    }

    /// The line under the header's notices when there are more.
    static func moreText(_ count: Int) -> String {
        "+\(count) more — see Status"
    }
}
