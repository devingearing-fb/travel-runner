import Foundation
import SwiftUI

enum ServicePhase: String, Sendable {
    case pending = "PENDING"
    case starting = "STARTING"
    case running = "RUNNING"
    case completed = "DONE"
    case skipped = "SKIPPED"
    case failed = "FAILED"
    case stopping = "STOPPING"
    case stopped = "STOPPED"

    var color: Color {
        switch self {
        case .pending: .gray
        case .starting: .orange
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
    var failureTimestamps: [Date] = []
    var isCircuitBroken: Bool = false
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
