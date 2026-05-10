import SwiftUI

struct TimelineStrip: View {
    let currentPhase: EnvironmentSupervisor.StartupPhase
    let completedPhases: Set<String>
    var phaseTimings: [String: TimeInterval] = [:]

    private let phases: [(id: String, label: String)] = [
        ("PREFLIGHT", "PRE"),
        ("GROUND", "GND"),
        ("GATEWAY", "GW"),
        ("PORTAL", "APP"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(phases, id: \.id) { phase in
                PhasePill(label: phase.label, state: pillState(for: phase.id), elapsed: phaseTimings[phase.id])
            }
        }
    }

    private func pillState(for phaseID: String) -> PhasePill.PillState {
        if completedPhases.contains(phaseID) { return .completed }
        if currentPhase.rawValue == phaseID { return .active }
        if currentPhase == .running { return .completed }
        return .pending
    }
}

struct PhasePill: View {
    let label: String
    let state: PillState
    var elapsed: TimeInterval? = nil

    enum PillState { case pending, active, completed }

    var body: some View {
        HStack(spacing: 3) {
            if state == .completed {
                Image(systemName: "checkmark")
                    .foregroundStyle(.green)
                    .font(.system(size: 8, weight: .bold))
            }
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(state == .active ? .bold : .regular)
                .foregroundStyle(state == .pending ? .secondary : .primary)
            if let elapsed, state == .completed {
                Text(elapsed < 1 ? "<1s" : "\(Int(elapsed))s")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(backgroundColor)
        }
    }

    private var backgroundColor: Color {
        switch state {
        case .active: Color.accentColor.opacity(0.25)
        case .completed: Color.green.opacity(0.1)
        case .pending: Color.secondary.opacity(0.08)
        }
    }
}
