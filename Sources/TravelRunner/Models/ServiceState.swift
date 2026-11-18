import Foundation
import SwiftUI

enum ServicePhase: String, Sendable {
    case pending = "PENDING"
    case starting = "STARTING"
    /// A dependency is not up. The service starts when it is.
    case waiting = "WAITING"
    case running = "RUNNING"
    case completed = "DONE"
    case skipped = "SKIPPED"
    case failed = "FAILED"
    case stopping = "STOPPING"
    case stopped = "STOPPED"

    var color: Color {
        switch self {
        case .pending: .gray
        case .starting, .waiting: .orange
        case .running, .completed: .green
        case .skipped: .secondary
        case .failed: .red
        case .stopping: .yellow
        case .stopped: .gray
        }
    }
}

@Observable
@MainActor
final class ServiceState {
    nonisolated let id: String
    let definition: ServiceDefinition
    var phase: ServicePhase = .pending
    var pid: Int32? = nil
    var exitCode: Int32? = nil
    var lastStarted: Date? = nil
    /// When the current process passed its probe; nil while it starts.
    var readyAt: Date? = nil
    var lastStopped: Date? = nil
    var restartCount: Int = 0
    var capturedArtifact: String? = nil
    /// The row text for the captured webhook secret: the last four characters only.
    var capturedArtifactSummary: String? {
        capturedArtifact.map { "Webhook secret captured (…\($0.suffix(4)))" }
    }
    /// How the service runs, for the row: the Stripe CLI says whether it uses the
    /// test key or the developer's login. Never a secret value.
    var modeNote: String? = nil
    /// What the service does now, while it starts or stops: the last line of
    /// `supabase start` during a cold image pull, or the stop of the stack.
    var progressNote: String? = nil
    var failureTimestamps: [Date] = []
    /// The failures in `failureTimestamps` that were kills from outside, and the
    /// signal of the last one. Three kills in a minute are no crash loop.
    var killTimestamps: [Date] = []
    var lastKillSignal: Int32? = nil
    /// The SIGKILL of this series sent its one notification.
    var memoryNotified = false
    /// Why the supervisor stopped its automatic restarts. Nil while it restarts.
    var haltReason: HaltReason? = nil
    /// The automatic restarts stopped. Setting false clears the reason.
    var isCircuitBroken: Bool {
        get { haltReason != nil }
        set {
            if !newValue { haltReason = nil } else if haltReason == nil { haltReason = .crashLoop }
        }
    }
    /// The daemon ended with code 0 and got its one automatic restart.
    var cleanExitRestarted = false
    /// Why the service is failed or skipped, and the fix. Nil while it starts or runs.
    var condition: ServiceCondition? = nil
    /// The line of this launch's log that best says why it failed.
    var likelyCause: String? = nil
    /// The last check of the startup probe.
    var lastProbe: ProbeOutcome? = nil
    /// Counts the failure records. A record that reads the log writes its condition
    /// only when no newer record came in the meantime.
    @ObservationIgnored var failureRecordCount = 0

    /// The service starts or runs: the old "why" no longer applies.
    func clearCondition() {
        condition = nil
        likelyCause = nil
        failureRecordCount += 1
    }

    init(definition: ServiceDefinition) {
        self.id = definition.id
        self.definition = definition
    }
}

extension ServiceState: Identifiable {}
