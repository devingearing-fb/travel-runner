import SwiftUI

struct WorkshopHeaderBar: View {
    @Environment(EnvironmentSupervisor.self) var supervisor

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
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(supervisor.health.color)
                    .frame(width: 10, height: 10)

                Text(healthLabel)
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundStyle(isIncident ? .red : .primary)
                    .lineLimit(1)

                if supervisor.health == .starting, let began = supervisor.startupBeganAt {
                    Text(began, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if supervisor.networkMode, let ip = supervisor.localIP {
                    HStack(spacing: 4) {
                        Image(systemName: "wifi")
                            .font(.caption)
                        Text(ip)
                            .font(.system(.caption, design: .monospaced))
                    }
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }

                primaryActionButton
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if let error = supervisor.lastError {
                alertBanner(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    text: error,
                    subtitle: supervisor.rootCauseDescription,
                    action: ("Retry", { supervisor.retryStartAll() })
                )
            } else if supervisor.migrationsBannerVisible {
                alertBanner(
                    icon: "arrow.triangle.2.circlepath",
                    color: .orange,
                    text: "Migrations changed since last db:reset",
                    subtitle: nil,
                    action: ("Reset DB", { supervisor.resetDatabase() }),
                    onDismiss: { supervisor.dismissMigrationsBanner() }
                )
            }

            Divider()
        }
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

    private func alertBanner(
        icon: String,
        color: Color,
        text: String,
        subtitle: String?,
        action: (label: String, handler: () -> Void),
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.caption)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(action.label) { action.handler() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(color)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
    }
}
