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

    private var uptimeString: String? {
        guard supervisor.health == .healthy || supervisor.health == .degraded else { return nil }
        guard let earliest = supervisor.sortedServiceIDs
            .compactMap({ supervisor.serviceStates[$0]?.lastStarted })
            .min() else { return nil }
        let seconds = Int(Date.now.timeIntervalSince(earliest))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }

    private var totalRestarts: Int {
        supervisor.sortedServiceIDs
            .compactMap { supervisor.serviceStates[$0] }
            .reduce(0) { $0 + $1.restartCount }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Row 1: Health status + action button
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

            // Row 2: Service badges + indicators
            if !supervisor.sortedServiceIDs.isEmpty {
                HStack(spacing: 6) {
                    ForEach(supervisor.sortedServiceIDs, id: \.self) { id in
                        if let state = supervisor.serviceStates[id] {
                            serviceBadge(id: id, state: state)
                        }
                    }

                    Spacer()

                    if supervisor.yalcStale {
                        statusTag("STALE", icon: "arrow.triangle.2.circlepath", color: .yellow)
                    }

                    if supervisor.dbResetRunning {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("DB Reset")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }

                    if let uptime = uptimeString {
                        Text(uptime)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .help("Uptime since services started")
                    }

                    if totalRestarts > 0 {
                        statusTag("\(totalRestarts)\u{21BB}", icon: nil, color: .orange)
                            .help("\(totalRestarts) auto-restart\(totalRestarts == 1 ? "" : "s") since boot")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Banners
            if let error = supervisor.lastError {
                alertBanner(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    text: error,
                    subtitle: supervisor.rootCauseDescription,
                    action: ("Retry", { supervisor.retryStartAll() })
                )
            }
            if supervisor.migrationsBannerVisible {
                alertBanner(
                    icon: "arrow.triangle.2.circlepath",
                    color: .orange,
                    text: "Migrations changed since last db:reset",
                    subtitle: nil,
                    action: ("Reset DB", { supervisor.resetDatabase() }),
                    onDismiss: { supervisor.dismissMigrationsBanner() }
                )
            }
            if supervisor.totalBehindCount > 0 && !supervisor.behindBannerDismissed {
                alertBanner(
                    icon: "arrow.down.circle.fill",
                    color: .blue,
                    text: "\(supervisor.totalBehindCount) commit\(supervisor.totalBehindCount == 1 ? "" : "s") behind remote",
                    subtitle: nil,
                    action: ("Dismiss", { supervisor.dismissBehindBanner() }),
                    onDismiss: { supervisor.dismissBehindBanner() }
                )
            }

            Divider()
        }
    }

    // MARK: - Service badge

    private func serviceBadge(id: String, state: ServiceState) -> some View {
        let abbrev = Self.abbreviation(for: id)
        let showRestart = state.restartCount > 0

        return HStack(spacing: 3) {
            Circle()
                .fill(state.phase.color)
                .frame(width: 6, height: 6)
            Text(abbrev)
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.medium)
            if showRestart {
                Text("\(state.restartCount)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(state.phase.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .help("\(state.definition.displayName): \(state.phase.rawValue)"
              + (state.restartCount > 0 ? " (\(state.restartCount) restart\(state.restartCount == 1 ? "" : "s"))" : ""))
    }

    private static func abbreviation(for serviceID: String) -> String {
        switch serviceID {
        case "supabase": "SB"
        case "universal-login": "UL"
        case "travel-portal": "TP"
        case "stripe": "ST"
        case "yalc-link": "YL"
        case "partner-portal": "PP"
        default: String(serviceID.prefix(2)).uppercased()
        }
    }

    // MARK: - Status tag

    private func statusTag(_ text: String, icon: String?, color: Color) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
            }
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .fontWeight(.medium)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Action button

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

    // MARK: - Alert banner

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
