import SwiftUI

enum DashboardMode: String {
    case terminal
    case status
}

struct DashboardHeader: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @Binding var mode: DashboardMode
    let onOpenSettings: () -> Void
    let onOpenWorkshop: () -> Void

    private var healthLabel: String {
        switch supervisor.health {
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .healthy: return "All OK"
        case .degraded:
            let failCount = supervisor.sortedServiceIDs
                .compactMap { supervisor.serviceStates[$0] }
                .filter { $0.phase == .failed || $0.isCircuitBroken }
                .count
            return failCount > 0 ? "\(failCount) Failing" : "Degraded"
        }
    }

    private var isIncident: Bool {
        let failCount = supervisor.sortedServiceIDs
            .compactMap { supervisor.serviceStates[$0] }
            .filter { $0.phase == .failed || $0.isCircuitBroken }
            .count
        return failCount >= 2
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(supervisor.health.color)
                .frame(width: 8, height: 8)

            Text(healthLabel)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundStyle(isIncident ? .red : .primary)
                .lineLimit(1)

            if supervisor.health == .starting, let began = supervisor.startupBeganAt {
                Text(began, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            primaryActionButton

            Button {
                mode = mode == .terminal ? .status : .terminal
            } label: {
                Image(systemName: mode == .terminal ? "list.bullet" : "terminal")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(mode == .terminal ? "Switch to Status" : "Switch to Terminals")
            .keyboardShortcut("e", modifiers: .command)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Settings")
            .keyboardShortcut(",", modifiers: .command)

            Button(action: onOpenWorkshop) {
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Open Workshop")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if supervisor.health == .stopped {
            Button(action: { supervisor.startAll() }) {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.small)
        } else if supervisor.health == .degraded && supervisor.currentPhase == .idle {
            Button("Retry") { supervisor.retryStartAll() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
        } else if supervisor.health == .starting {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Button(action: { supervisor.stopAll() }) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            Button(action: { supervisor.stopAll() }) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
