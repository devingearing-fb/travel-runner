import SwiftUI

/// Phase-grouped status summary for the header bar. One chip per startup phase,
/// colored by the worst service state in that phase; clicking opens a popover
/// with per-service detail and deep-links into the service's console.
struct ServicePhaseChips: View {
    @Environment(EnvironmentSupervisor.self) var supervisor

    var body: some View {
        HStack(spacing: 6) {
            ForEach(supervisor.servicesByPhase(), id: \.phase) { group in
                PhaseChip(phase: group.phase, services: group.services) { serviceID in
                    WorkshopPanel.shared.navigation.selectedLogServiceID = serviceID
                    WorkshopPanel.shared.open(section: .logs)
                }
            }
        }
    }
}

private struct PhaseChip: View {
    let phase: String
    let services: [ServiceState]
    let onOpenService: (String) -> Void

    @State private var showPopover = false

    private var label: String {
        phase == "VERIFICATION" ? "VERIFY" : phase
    }

    private var failCount: Int {
        services.filter { $0.phase == .failed || $0.isCircuitBroken }.count
    }

    private var healthyCount: Int {
        services.filter { $0.phase == .running || $0.phase == .completed || $0.phase == .skipped }.count
    }

    private var statusColor: Color {
        if failCount > 0 { return .red }
        if services.contains(where: { $0.phase == .starting || $0.phase == .stopping }) { return .orange }
        let phases = services.map(\.phase)
        if phases.allSatisfy({ $0 == .pending || $0 == .stopped }) { return .gray }
        if phases.allSatisfy({ $0 == .running || $0 == .completed || $0 == .skipped }) { return .green }
        return .orange
    }

    var body: some View {
        Button { showPopover.toggle() } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.medium)
                Text("\(healthyCount)/\(services.count)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                if failCount > 0 {
                    Text("\(failCount)")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .help("\(label): \(healthyCount) of \(services.count) healthy — click for services")
        .accessibilityLabel("\(label) phase, \(healthyCount) of \(services.count) services healthy")
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(services) { state in
                    Button {
                        showPopover = false
                        onOpenService(state.id)
                    } label: {
                        ServicePopoverRow(state: state)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
    }
}

private struct ServicePopoverRow: View {
    let state: ServiceState
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            if state.phase == .completed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.green)
                    .frame(width: 7)
            } else {
                Circle()
                    .fill(state.phase.color)
                    .frame(width: 7, height: 7)
            }

            Text(state.definition.displayName)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)

            if let port = state.definition.probe?.port {
                Text(":\(port)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if state.definition.resolvedType == .oneshot {
                Text("one-shot")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }

            Spacer(minLength: 12)

            if state.restartCount > 0 {
                Text("\(state.restartCount)↻")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.orange)
            }

            Text(state.phase.rawValue.lowercased())
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(state.phase == .failed ? .red : .secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(isHovering ? Color.primary.opacity(0.08) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { isHovering = $0 }
    }
}
