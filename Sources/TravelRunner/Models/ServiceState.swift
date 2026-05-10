import Foundation
import SwiftUI

enum ServicePhase: String, Sendable {
    case pending = "PENDING"
    case starting = "STARTING"
    case running = "RUNNING"
    case completed = "DONE"
    case failed = "FAILED"
    case stopping = "STOPPING"
    case stopped = "STOPPED"

    var color: Color {
        switch self {
        case .pending: .gray
        case .starting: .orange
        case .running, .completed: .green
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
    var lastStopped: Date? = nil
    var restartCount: Int = 0
    var capturedArtifact: String? = nil
    var failureTimestamps: [Date] = []
    var isCircuitBroken: Bool = false

    init(definition: ServiceDefinition) {
        self.id = definition.id
        self.definition = definition
    }
}

extension ServiceState: Identifiable {}
