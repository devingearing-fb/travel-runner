import SwiftUI

struct WorkshopStatusView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @State private var preflightExpanded = true
    @State private var dbResetHasLogs = false
    @State private var dbResetEntries: [LogEntry] = []

    private var failedServices: [ServiceState] {
        supervisor.sortedServiceIDs
            .compactMap { supervisor.serviceStates[$0] }
            .filter { $0.phase == .failed || $0.isCircuitBroken }
    }

    private var allPreflightsPassed: Bool {
        !supervisor.preflightChecks.isEmpty && supervisor.preflightChecks.allSatisfy { $0.result.isPassed }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ServiceDotMinimap(
                    serviceStates: supervisor.serviceStates,
                    sortedIDs: supervisor.sortedServiceIDs
                )
                .padding(.horizontal, 4)

                ForEach(failedServices) { state in
                    TriageCard(
                        state: state,
                        logStore: supervisor.logStore,
                        onRestart: { supervisor.restartService(state.id) },
                        onCascadeRestart: { supervisor.restartCascade(state.id) },
                        onClearCache: state.id == "travel-portal"
                            ? { supervisor.clearCacheAndRestart(state.id) } : nil,
                        onPublishRetry: state.id == "yalc-link"
                            ? { supervisor.publishAndRetryYalc() } : nil
                    )
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
                        onDismiss: { supervisor.dismissDbSetup() }
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
                            onRestart: { supervisor.restartService($0) },
                            onCascadeRestart: { supervisor.restartCascade($0) },
                            onPublishRetry: group.phase == "GATEWAY" ? { supervisor.publishAndRetryYalc() } : nil,
                            dbResetRunning: supervisor.dbResetRunning,
                            isServiceStale: { $0 == "yalc-link" && supervisor.yalcStale },
                            serviceBehindCount: { supervisor.gitBehindCounts[$0] ?? 0 },
                            isServiceDepsStale: { supervisor.npmStaleServices.contains($0) }
                        )
                    }
                }
            }
            .padding(16)
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

    private var preflightSection: some View {
        DisclosureGroup("Preflight Checks", isExpanded: $preflightExpanded) {
            ForEach(supervisor.preflightChecks) { check in
                HStack(spacing: 8) {
                    Group {
                        switch check.result {
                        case .pending:
                            ProgressView().controlSize(.small)
                        case .passed:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .warning:
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        case .failed:
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                    .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.name)
                            .font(.caption)
                        if case .warning(let message) = check.result {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if case .failed(let message, let fix) = check.result {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                            if let fix {
                                Text("Fix: \(fix)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    Spacer()

                    if case .passed(let detail) = check.result {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background {
                    if case .failed = check.result {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.red.opacity(0.08))
                    }
                }
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
