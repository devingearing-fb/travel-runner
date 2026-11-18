import Foundation

/// Why a service is in its phase, in words, with the button that fixes it.
/// It is the one "why" model of the service rows, the triage card and `/api/status`.
struct ServiceCondition: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case notInProfile
        /// An optional service (Stripe, the agent) is off. The rest of the stack runs.
        case optionalOff
        case waitingForDependency(String)
        case slowStart
        case unhealthy
        case failed
        /// The supervisor stopped its automatic restarts. `reason` is the short form.
        case halted(reason: String)
        case retrying
    }

    let kind: Kind
    /// One sentence: what is wrong.
    let headline: String
    /// What it means, or the cause line from the log.
    var detail: String? = nil
    /// The buttons, the most useful first.
    var actions: [RecoveryAction] = []
    let since: Date

    /// The main button.
    var action: RecoveryAction? { actions.first }

    /// The headline and the detail as one line, for `/api/status` and the log.
    var text: String {
        [headline, detail].compactMap { $0 }.joined(separator: " ")
    }
}

/// One fix that a button can run. It serves the service rows, the DB steps and the
/// fix buttons of the checks.
enum RecoveryAction: Equatable, Hashable, Sendable {
    case restart
    /// A start that passed its soft limit: wait another 15 min before the stop.
    case keepWaiting
    case startService
    /// Stop the processes that listen on `port` (the port of the EADDRINUSE line),
    /// then start again. With no port, the start frees the port of the probe.
    case stopForeignAndRetry(port: Int?)
    case openContainerRuntime
    case installDependencies
    case clearCacheAndRestart
    case openLog
    case stripeLogin
    case installStripe
    case updateStripe
    case importSharedEnv
    case redownloadHotels
    case resetWithoutHotels
    case retryFromStep
    case ghAuth
    case openHealth

    /// The button text. `runtime` is the name of the container app on this Mac.
    func title(runtime: String = ContainerRuntime.detect().appName) -> String {
        switch self {
        case .restart: "Restart"
        case .keepWaiting: "Keep waiting"
        case .startService: "Start"
        case .stopForeignAndRetry: "Free port and restart"
        case .openContainerRuntime: "Open \(runtime)"
        case .installDependencies: "Install dependencies"
        case .clearCacheAndRestart: "Clear cache and restart"
        case .openLog: "Open log"
        case .stripeLogin: "Log in…"
        case .installStripe: "Install"
        case .updateStripe: "Update Stripe CLI"
        case .importSharedEnv: "Import…"
        case .redownloadHotels: "Download hotels again"
        case .resetWithoutHotels: "Reset without hotels"
        case .retryFromStep: "Retry from this step"
        case .ghAuth: "Log in to GitHub"
        case .openHealth: "Open Health"
        }
    }
}
