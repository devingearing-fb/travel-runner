import Foundation

/// What an action did, for a toast and the "Recent activity" list in Status.
struct ActionFeedback: Identifiable, Equatable, Sendable {
    enum Style: Equatable, Sendable {
        case success, error, info
    }

    let id = UUID()
    let message: String
    let style: Style
    /// The service it is about, when there is one. An error toast opens its triage card.
    var serviceID: String? = nil
    let at: Date

    static func == (lhs: ActionFeedback, rhs: ActionFeedback) -> Bool {
        lhs.id == rhs.id
    }

    /// The text of a guard that refused an action, because the same one runs.
    static let startInProgress = "A start is already in progress."
    static let dbSetupRunning = "A database setup is already running."
    static func alreadyRestarting(_ name: String) -> String {
        "\(name) is already restarting."
    }
}

/// The recent feedback and crashes, the newest first.
struct RecentActivity: Equatable, Sendable {
    /// Status lists this many.
    static let limit = 30

    private(set) var entries: [ActionFeedback] = []

    mutating func add(_ entry: ActionFeedback) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }
}

/// The notification of a crash: which service, why, and what the runner does next.
struct CrashAlert: Equatable, Sendable {
    /// What the runner does after the crash.
    enum Next: Equatable, Sendable {
        /// An automatic restart is scheduled; `attempt` counts from 1.
        case restarting(attempt: Int)
        /// The circuit breaker stopped the automatic restarts.
        case autoRestartStopped
        /// The service is not restarted by itself.
        case none
    }

    let serviceID: String
    let name: String
    let exitCode: Int32
    /// The cause from the log, as one sentence, or nil.
    let cause: String?
    let next: Next

    var title: String { "\(name) crashed" }

    /// "Port 3002 is already in use. Restarting (attempt 1)."
    var body: String {
        let what = cause.map(FailureAdvisor.sentence) ?? "Exited with code \(exitCode)."
        switch next {
        case .restarting(let attempt): return "\(what) Restarting (attempt \(attempt))."
        case .autoRestartStopped: return "\(what) Auto-restart stopped."
        case .none: return what
        }
    }

    /// The key of the service ID in the notification's user info.
    static let serviceIDKey = "serviceID"
}
