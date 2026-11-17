import SwiftUI

struct WorkshopHeaderBar: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @Environment(UpdateController.self) var updates: UpdateController?
    @State private var confirmingReset = false
    @State private var confirmingResetWithoutHotels = false

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
        // Only meaningful when everything is up; next to a failure banner it
        // reads as contradictory and competes for the little space row 2 has.
        guard supervisor.health == .healthy else { return nil }
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

                UpdatePill()

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

            // Row 2: Phase chips + indicators
            if !supervisor.sortedServiceIDs.isEmpty {
                HStack(spacing: 6) {
                    ServicePhaseChips()

                    Spacer()

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
                            .lineLimit(1)
                            .fixedSize()
                            .help("Uptime since services started")
                    }

                    if totalRestarts > 0 {
                        statusTag("\(totalRestarts)↻", icon: nil, color: .orange)
                            .help("\(totalRestarts) auto-restart\(totalRestarts == 1 ? "" : "s") since boot")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            // Banners
            if let error = supervisor.lastError {
                // When the primary header button is already Retry, the banner
                // shows context only — one Retry affordance, not two.
                let headerOffersRetry = supervisor.health == .degraded && supervisor.currentPhase == .idle
                alertBanner(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    text: error,
                    subtitle: supervisor.rootCauseDescription,
                    action: headerOffersRetry ? nil : ("Retry", { supervisor.retryStartAll() })
                )
            }
            if let error = supervisor.controlAPIError {
                alertBanner(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    text: error,
                    subtitle: ControlServer.BindFailure.advice(),
                    action: nil
                )
            }
            // Keyed by place: two skipped services can give the same text.
            ForEach(Array(supervisor.configIssues.enumerated()), id: \.offset) { _, issue in
                alertBanner(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    text: issue,
                    subtitle: "Correct the file, then quit \(Flavor.current.displayName) and open it again.",
                    action: ("Open services.json", {
                        NSWorkspace.shared.open(URL(fileURLWithPath: ConfigLoader.configPath))
                    })
                )
            }
            if let notice = supervisor.misplacedCopyNotice {
                alertBanner(
                    icon: "folder.badge.questionmark",
                    color: .orange,
                    text: notice.text,
                    subtitle: notice.advice,
                    action: notice.revealPath.map { path in
                        ("Show in Finder", {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        })
                    },
                    onDismiss: { supervisor.dismissMisplacedCopyNotice() }
                )
            }
            if let notice = supervisor.compatibilityNotice {
                // No dismiss: it stays while the resets are blocked.
                alertBanner(
                    icon: "arrow.up.circle.fill",
                    color: .red,
                    text: notice.text,
                    subtitle: nil,
                    link: (Compatibility.downloadLinkTitle, notice.downloadURL),
                    action: (Compatibility.updateButtonTitle, {
                        // Without the updater (a source run), the link is the only way.
                        if let updates { updates.checkForUpdates() } else { NSWorkspace.shared.open(notice.downloadURL) }
                    })
                )
            }
            if supervisor.migrationsBannerVisible, let notice = supervisor.migrationNotice {
                let isDbSetupRunning = supervisor.dbResetRunning || supervisor.dbSetupPipeline?.isRunning == true
                // A runner that is too old for the checkout cannot change the database.
                let canChange = supervisor.compatibilityNotice == nil && !isDbSetupRunning
                alertBanner(
                    icon: "arrow.triangle.2.circlepath",
                    color: .orange,
                    text: notice.headline,
                    subtitle: supervisor.migrationApplyError ?? notice.detail,
                    action: canChange && notice.offersApply ? ("Apply migrations", { supervisor.applyMigrations() }) : nil,
                    secondaryAction: canChange ? ("Reset and reseed…", { confirmingReset = true }) : nil,
                    onDismiss: { supervisor.dismissMigrationsBanner() }
                )
                .confirmationDialog(
                    DbResetPolicy.resetConfirmationTitle,
                    isPresented: $confirmingReset,
                    titleVisibility: .visible
                ) {
                    Button("Reset and reseed", role: .destructive) { supervisor.resetDatabase() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(notice.resetConfirmation)
                }
            }
            if let notice = supervisor.hotelSourceNotice {
                let isDbSetupRunning = supervisor.dbResetRunning || supervisor.dbSetupPipeline?.isRunning == true
                // The data can still be there: the reset asks first, as "Reset and reseed…" does.
                let canReset = notice.beforeReset && supervisor.compatibilityNotice == nil && !isDbSetupRunning
                    && supervisor.manifestHasProfile(HotelCatalog.withoutHotelsProfile)
                alertBanner(
                    icon: "building.2",
                    color: .orange,
                    text: notice.text,
                    subtitle: nil,
                    action: (HotelCatalog.importButtonTitle, { supervisor.importSharedEnvForHotels() }),
                    secondaryAction: canReset
                        ? ("\(HotelCatalog.resetWithoutHotelsTitle)…", { confirmingResetWithoutHotels = true }) : nil,
                    onDismiss: { supervisor.dismissHotelSourceNotice() }
                )
                .confirmationDialog(
                    DbResetPolicy.resetConfirmationTitle,
                    isPresented: $confirmingResetWithoutHotels,
                    titleVisibility: .visible
                ) {
                    Button(HotelCatalog.resetWithoutHotelsTitle, role: .destructive) { supervisor.resetWithoutHotels() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(notice.resetConfirmation)
                }
            }
            if supervisor.hotelCatalogBannerVisible, let notice = supervisor.hotelCatalogNotice {
                let isDbSetupRunning = supervisor.dbResetRunning || supervisor.dbSetupPipeline?.isRunning == true
                let canLoad = supervisor.compatibilityNotice == nil && !isDbSetupRunning
                alertBanner(
                    icon: "building.2",
                    color: .orange,
                    text: notice.text,
                    subtitle: nil,
                    action: canLoad ? (HotelCatalog.loadHotelsTitle, { supervisor.loadHotels() }) : nil,
                    onDismiss: { supervisor.dismissHotelCatalogBanner() }
                )
            }
            if let note = supervisor.migrationsAppliedNotice {
                alertBanner(
                    icon: "checkmark.circle.fill",
                    color: .green,
                    text: note,
                    subtitle: nil,
                    action: nil,
                    onDismiss: { supervisor.dismissMigrationsAppliedNotice() }
                )
            }
            if supervisor.totalBehindCount > 0 && !supervisor.behindBannerDismissed {
                alertBanner(
                    icon: "arrow.down.circle.fill",
                    color: .blue,
                    text: "\(supervisor.totalBehindCount) commit\(supervisor.totalBehindCount == 1 ? "" : "s") behind remote",
                    subtitle: nil,
                    action: nil,
                    onDismiss: { supervisor.dismissBehindBanner() }
                )
            }

            Divider()
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
        link: (label: String, url: URL)? = nil,
        action: (label: String, handler: () -> Void)?,
        secondaryAction: (label: String, handler: () -> Void)? = nil,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.caption)
                    .lineLimit(link == nil ? 2 : 3)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let link {
                    Link(link.label, destination: link.url)
                        .font(.caption2)
                }
            }
            Spacer()
            if let action {
                Button(action.label) { action.handler() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(color)
            }
            if let secondaryAction {
                Button(secondaryAction.label) { secondaryAction.handler() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
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
