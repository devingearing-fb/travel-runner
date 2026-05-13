import Foundation
import SwiftUI

enum DbStepStatus: String, Sendable {
    case pending = "PENDING"
    case running = "RUNNING"
    case healthCheck = "CHECKING"
    case passed = "PASSED"
    case failed = "FAILED"
    case skipped = "SKIPPED"
    case timedOut = "TIMED_OUT"

    var color: Color {
        switch self {
        case .pending: .secondary
        case .running, .healthCheck: .blue
        case .passed: .green
        case .failed: .red
        case .skipped: .secondary
        case .timedOut: .orange
        }
    }
}

@Observable
@MainActor
final class DbSetupStep: Identifiable {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated let command: String
    nonisolated let healthCheckCommand: String?
    nonisolated let timeoutSeconds: Int
    nonisolated let isOptional: Bool
    nonisolated let stepNumber: Int

    var status: DbStepStatus = .pending
    var progress: Double? = nil
    var progressLabel: String? = nil
    var healthResult: String? = nil
    var errorMessage: String? = nil
    var recoveryGuidance: String? = nil
    var logEntries: [LogEntry] = []
    var startedAt: Date? = nil
    var completedAt: Date? = nil

    var elapsed: TimeInterval? {
        guard let start = startedAt else { return nil }
        return (completedAt ?? .now).timeIntervalSince(start)
    }

    nonisolated init(id: String, name: String, command: String, healthCheckCommand: String?,
                     timeoutSeconds: Int, isOptional: Bool, stepNumber: Int) {
        self.id = id
        self.name = name
        self.command = command
        self.healthCheckCommand = healthCheckCommand
        self.timeoutSeconds = timeoutSeconds
        self.isOptional = isOptional
        self.stepNumber = stepNumber
    }
}

@Observable
@MainActor
final class DbSetupPipeline {
    var steps: [DbSetupStep] = []
    var isRunning = false
    var startedAt: Date? = nil
    var completedAt: Date? = nil

    var currentStep: DbSetupStep? {
        steps.first { $0.status == .running || $0.status == .healthCheck }
    }

    var firstFailed: DbSetupStep? {
        steps.first { $0.status == .failed || $0.status == .timedOut }
    }

    var allRequiredPassed: Bool {
        steps.filter { !$0.isOptional }.allSatisfy { $0.status == .passed }
    }

    var totalElapsed: TimeInterval? {
        guard let start = startedAt else { return nil }
        return (completedAt ?? .now).timeIntervalSince(start)
    }

    static func buildDefault() -> [DbSetupStep] {
        [
            DbSetupStep(id: "check-prerequisites", name: "Prerequisites",
                        command: "node scripts/db/check-prerequisites.mjs",
                        healthCheckCommand: "node scripts/db/check-prerequisites.mjs --verify",
                        timeoutSeconds: 30, isOptional: false, stepNumber: 1),
            DbSetupStep(id: "start-supabase", name: "Start Supabase",
                        command: "node scripts/db/start-supabase.mjs",
                        healthCheckCommand: "node scripts/db/start-supabase.mjs --verify",
                        timeoutSeconds: 300, isOptional: false, stepNumber: 2),
            DbSetupStep(id: "sync-migrations", name: "Sync Migrations",
                        command: "node scripts/db/sync-migrations.mjs",
                        healthCheckCommand: "node scripts/db/sync-migrations.mjs --verify",
                        timeoutSeconds: 15, isOptional: false, stepNumber: 3),
            DbSetupStep(id: "reset-database", name: "Apply Migrations",
                        command: "node scripts/db/reset-database.mjs",
                        healthCheckCommand: "node scripts/db/reset-database.mjs --verify",
                        timeoutSeconds: 180, isOptional: false, stepNumber: 4),
            DbSetupStep(id: "load-hotels", name: "Load Hotels",
                        command: "node scripts/db/load-hotels.mjs",
                        healthCheckCommand: "node scripts/db/load-hotels.mjs --verify",
                        timeoutSeconds: 120, isOptional: true, stepNumber: 5),
            DbSetupStep(id: "copy-event-data", name: "Event Contracts",
                        command: "node scripts/db/copy-event-data.mjs",
                        healthCheckCommand: "node scripts/db/copy-event-data.mjs --verify",
                        timeoutSeconds: 90, isOptional: true, stepNumber: 6),
            DbSetupStep(id: "verify-data", name: "Verify Data",
                        command: "node scripts/db/verify-data.mjs",
                        healthCheckCommand: nil,
                        timeoutSeconds: 30, isOptional: false, stepNumber: 7),
        ]
    }
}
