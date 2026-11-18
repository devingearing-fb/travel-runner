import Foundation

/// The health of the stack with the reason for it. One pure function decides it,
/// so the header, the menu-bar tooltip and `/api/status` (`health_reason`) agree.
struct HealthSummary: Equatable, Sendable {
    /// One long-running service, in the order of the rows.
    struct Service: Equatable, Sendable {
        let id: String
        let name: String
        let phase: ServicePhase
        var conditionKind: ServiceCondition.Kind? = nil
        /// The headline of the service's condition: why it failed or was skipped.
        var headline: String? = nil
        var dependsOn: [String] = []
        var isCircuitBroken = false
    }

    struct Input: Equatable, Sendable {
        /// The daemons only: one-shot services do not count.
        var services: [Service]
        /// A start runs now.
        var startInFlight = false
        /// Services that a restart replaces now: their pending phase counts as starting.
        var restarting: Set<String> = []
        /// Why the last start did not start anything (a preflight or another runner).
        var refusal: String? = nil
        /// The database setup of the start failed. The text names the step when known.
        var dbSetupFailure: String? = nil
    }

    var status: HealthStatus
    /// One line: why the stack has this status. Nil when there is nothing to say.
    var reason: String? = nil
    /// The start was refused: nothing runs, and the header says "Not started".
    /// The wire keeps the four strings, so `status` stays degraded.
    var notStarted = false
    /// Services that are failed or stopped retrying.
    var failingCount = 0
    /// A short note for the header of a healthy stack, like "Stripe webhooks off".
    var note: String? = nil
    /// The first failed service whose dependencies did not fail.
    var rootCauseID: String? = nil

    static let stopped = HealthSummary(status: .stopped)

    /// The text of the header.
    var label: String {
        if notStarted { return "Not started" }
        switch status {
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .healthy: return note.map { "OK · \($0)" } ?? "All OK"
        case .degraded: return failingCount > 0 ? "\(failingCount) Failing" : "Degraded"
        }
    }

    /// Rules, first match wins:
    /// 1. All stopped, and no start runs → stopped; after a refused start → not started,
    ///    with the refusal. Once a service runs or fails, the refusal no longer applies.
    /// 2. Any failed, or the DB setup failed → degraded, with "<name> failed: <headline>".
    /// 3. A start, or a restart of a pending service, in flight → starting.
    /// 4. Otherwise healthy, with a note for the services that are off.
    static func compute(_ input: Input) -> HealthSummary {
        let services = input.services
        let failingCount = services.filter { $0.phase == .failed || $0.isCircuitBroken }.count

        let idle: Set<ServicePhase> = [.stopped, .pending]
        if !input.startInFlight, services.allSatisfy({ idle.contains($0.phase) }) {
            if let refusal = input.refusal {
                return HealthSummary(status: .degraded, reason: refusal, notStarted: true)
            }
            return .stopped
        }

        let failed = services.filter { $0.phase == .failed }
        if !failed.isEmpty || input.dbSetupFailure != nil {
            let failedIDs = Set(failed.map(\.id))
            let root = failed.first { !$0.dependsOn.contains(where: failedIDs.contains) } ?? failed.first
            var reason: String
            if let root {
                reason = "\(root.name) failed: \(root.headline.map(trimmed) ?? "it stopped")"
                if failed.count > 1 { reason += " (+\(failed.count - 1) more)" }
            } else {
                reason = input.dbSetupFailure ?? "Database setup failed"
            }
            return HealthSummary(
                status: .degraded, reason: reason, failingCount: failingCount, rootCauseID: root?.id
            )
        }

        let settled: Set<ServicePhase> = [.running, .completed, .skipped, .stopped, .pending, .failed]
        let busy = services.contains { service in
            !settled.contains(service.phase) || (service.phase == .pending && input.restarting.contains(service.id))
        }
        if input.startInFlight || busy {
            return HealthSummary(status: .starting, failingCount: failingCount)
        }

        return healthy(services, failingCount: failingCount)
    }

    /// A healthy stack names the services that are off and why.
    private static func healthy(_ services: [Service], failingCount: Int) -> HealthSummary {
        let skipped = services.filter { $0.phase == .skipped && $0.conditionKind != .notInProfile }
        let stopped = services.filter { $0.phase == .stopped || $0.phase == .pending }
        var parts: [String] = []
        if !skipped.isEmpty {
            let names = skipped.map { service in
                service.headline.map { "\(service.name) (\(trimmed($0)))" } ?? service.name
            }
            parts.append("\(skipped.count) skipped: \(names.joined(separator: ", "))")
        }
        if !stopped.isEmpty {
            parts.append("\(stopped.count) stopped: \(stopped.map(\.name).joined(separator: ", "))")
        }
        let off = skipped + stopped
        let note: String? = switch off.count {
        case 0: nil
        case 1: off[0].id == "stripe" ? "Stripe webhooks off" : "\(off[0].name) off"
        default: "\(off.count) services off"
        }
        return HealthSummary(
            status: .healthy, reason: parts.isEmpty ? nil : parts.joined(separator: "; "),
            failingCount: failingCount, note: note
        )
    }

    /// A headline without its closing period, to sit inside a sentence.
    private static func trimmed(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
