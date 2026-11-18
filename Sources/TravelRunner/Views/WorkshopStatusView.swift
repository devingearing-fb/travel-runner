import SwiftUI

struct WorkshopStatusView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @State private var preflightExpanded = true
    @State private var dbResetHasLogs = false
    @State private var dbResetEntries: [LogEntry] = []
    /// The triage card that an error toast opened, outlined for a moment.
    @State private var highlightedServiceID: String?
    private let navigation = WorkshopPanel.shared.navigation

    private var failedServices: [ServiceState] {
        supervisor.sortedServiceIDs
            .compactMap { supervisor.serviceStates[$0] }
            .filter { $0.phase == .failed || $0.isCircuitBroken }
    }

    private var allPreflightsPassed: Bool {
        !supervisor.preflightChecks.isEmpty && supervisor.preflightChecks.allSatisfy { $0.result.isPassed }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    // The header shows the newest few; this lists them all.
                    if supervisor.notices.header.more > 0 {
                        noticesSection
                    }

                    let setupItems = supervisor.setupItemsNeedingAttention.count
                    if setupItems > 0 {
                        HealthAttentionBanner(count: setupItems) {
                            WorkshopPanel.shared.open(section: .health)
                        }
                    }

                    ForEach(failedServices) { state in
                        TriageCard(
                            state: state,
                            logStore: supervisor.logStore,
                            onRestart: { supervisor.requestRestart(state.id) },
                            onCascadeRestart: { supervisor.requestCascadeRestart(state.id) },
                            onClearCache: ["travel-portal", "partner-portal"].contains(state.id)
                                ? { supervisor.clearCacheAndRestart(state.id) } : nil
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .opacity(highlightedServiceID == state.id ? 1 : 0)
                        )
                        .id(Self.triageAnchor(state.id))
                        .transition(.opacity)
                    }
                    .animation(.easeInOut(duration: 0.15), value: failedServices.map(\.id))

                    if !supervisor.preflightChecks.isEmpty && !allPreflightsPassed {
                        preflightSection
                    }

                    if supervisor.health == .starting {
                        TimelineStrip(
                            currentPhase: supervisor.currentPhase,
                            completedPhases: supervisor.completedPhases,
                            phaseTimings: supervisor.phaseTimings
                        )
                        .padding(.horizontal, 4)
                    }

                    if let pipeline = supervisor.dbSetupPipeline,
                       pipeline.isRunning || pipeline.steps.contains(where: { $0.status != .pending }) {
                        DbSetupPipelineView(
                            pipeline: pipeline,
                            isRunning: supervisor.dbResetRunning,
                            onRetryFrom: { supervisor.runDbSetup(from: $0) },
                            onCancel: { supervisor.cancelDbSetup() },
                            onDismiss: { supervisor.dismissDbSetup() },
                            onReport: { ReportProblem.run(.dbStep(id: $0), supervisor: supervisor) }
                        )
                    } else if supervisor.dbResetRunning || dbResetHasLogs {
                        dbResetConsole
                    }

                    let failedIDs = Set(failedServices.map(\.id))
                    let groups = supervisor.servicesByPhase()
                    ForEach(groups, id: \.phase) { group in
                        let healthyServices = group.services.filter { !failedIDs.contains($0.id) }
                        if !healthyServices.isEmpty {
                            PhaseSection(
                                phase: group.phase,
                                services: healthyServices,
                                logStore: supervisor.logStore,
                                onRestart: { supervisor.requestRestart($0) },
                                onCascadeRestart: { supervisor.requestCascadeRestart($0) },
                                dbResetRunning: supervisor.dbResetRunning,
                                serviceBehindCount: { supervisor.gitBehindCounts[$0] ?? 0 },
                                isServiceDepsStale: { supervisor.npmStaleServices.contains($0) }
                            )
                        }
                    }

                    if !supervisor.recentActivity.entries.isEmpty {
                        recentActivitySection
                    }
                }
                .padding(16)
            }
            // A click on an error toast: Status scrolls to the triage card of its service.
            .onChange(of: navigation.focusedServiceID, initial: true) { _, serviceID in
                guard let serviceID else { return }
                navigation.focusedServiceID = nil
                guard failedServices.contains(where: { $0.id == serviceID }) else { return }
                highlightedServiceID = serviceID
                Task { @MainActor in
                    // On a fresh open this runs before the first layout, and a scroll
                    // then does nothing. A short wait lets the window lay out first.
                    try? await Task.sleep(for: .milliseconds(100))
                    withAnimation { proxy.scrollTo(Self.triageAnchor(serviceID), anchor: .top) }
                    try? await Task.sleep(for: .seconds(2))
                    if highlightedServiceID == serviceID {
                        withAnimation { highlightedServiceID = nil }
                    }
                }
            }
            .task {
                while !Task.isCancelled {
                    let dbVersion = await supervisor.logStore.version(for: "db-reset")
                    if dbVersion > 0 {
                        dbResetHasLogs = true
                        dbResetEntries = await supervisor.logStore.entries(for: "db-reset")
                    } else if !supervisor.dbResetRunning {
                        dbResetHasLogs = false
                    }
                    try? await Task.sleep(for: .milliseconds(1000))
                }
            }
        }
    }

    private static func triageAnchor(_ serviceID: String) -> String { "triage-\(serviceID)" }

    private var noticesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notices")
                .font(.caption)
                .fontWeight(.medium)
            ForEach(supervisor.notices.all) { notice in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: notice.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(notice.severity == .error ? .red : .blue)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.text)
                            .font(.caption)
                            .textSelection(.enabled)
                        Text(notice.since, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notice.text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the text")
                    Button {
                        supervisor.dismissNotice(notice.key)
                    } label: {
                        Image(systemName: "xmark").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// The toasts and the crashes of this run: a toast that went by can be read here.
    private var recentActivitySection: some View {
        DisclosureGroup("Recent activity") {
            ForEach(supervisor.recentActivity.entries) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: entry.style.icon)
                        .foregroundStyle(entry.style.color)
                        .frame(width: 16)
                    Text(entry.message)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer()
                    Text(entry.at, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let serviceID = entry.serviceID {
                        Button {
                            WorkshopPanel.shared.navigation.selectedLogServiceID = serviceID
                            WorkshopPanel.shared.open(section: .logs)
                        } label: {
                            Image(systemName: "terminal").font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Open the log")
                    }
                }
            }
        }
        .font(.caption)
    }

    private var preflightSection: some View {
        DisclosureGroup("Preflight Checks", isExpanded: $preflightExpanded) {
            ForEach(supervisor.preflightChecks) { check in
                PreflightCheckRow(check: check)
            }
        }
        .font(.caption)
    }

    private var dbResetConsole: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if supervisor.dbResetRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption2)
                }
                Text("Database Reset")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                Spacer()
                if !supervisor.dbResetRunning && dbResetHasLogs {
                    Button {
                        Task { await supervisor.logStore.clear(serviceID: "db-reset") }
                        dbResetEntries = []
                        dbResetHasLogs = false
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
            }

            TerminalTextView(
                entries: dbResetEntries,
                autoScroll: true,
                format: { entry in
                    let text = entry.text
                    let color: NSColor = if text.contains("error") || text.contains("ERROR") {
                        .systemRed
                    } else if text.contains("✓") || text.contains("done") || text.contains("complete") {
                        .systemGreen
                    } else {
                        .white
                    }
                    return (text, color)
                }
            )
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(10)
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
