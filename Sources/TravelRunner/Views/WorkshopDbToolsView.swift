import SwiftUI

struct WorkshopDbToolsView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor

    private var isDbSetupRunning: Bool {
        supervisor.dbResetRunning || supervisor.dbSetupPipeline?.isRunning == true
    }

    private var validSelectedScenario: DbSeedScenario? {
        guard supervisor.dbSeedScenarioLoadError == nil else { return nil }
        return supervisor.selectedDbSeedScenario
    }

    private var canResetDatabase: Bool {
        !isDbSetupRunning && validSelectedScenario != nil && supervisor.compatibilityNotice == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Database Mode")

                Picker("Mode", selection: Binding(
                    get: { supervisor.dbMode },
                    set: { _ in supervisor.toggleDatabaseMode() }
                )) {
                    Text("Local").tag(EnvironmentSupervisor.DatabaseMode.local)
                    Text("Dev").tag(EnvironmentSupervisor.DatabaseMode.remote)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Divider()

                sectionHeader("Seed Scenario")

                DbSeedScenarioSelectorView(
                    scenarios: supervisor.dbSeedScenarios,
                    selectedID: supervisor.selectedDbSeedScenarioID,
                    selectedScenario: supervisor.selectedDbSeedScenario,
                    loadError: supervisor.dbSeedScenarioLoadError,
                    isRunning: isDbSetupRunning,
                    onSelect: { supervisor.selectDbSeedScenario($0) },
                    onReload: { supervisor.reloadDbSeedScenarios() }
                )

                if let notice = supervisor.dbSeedScenarioNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                sectionHeader("Actions")

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Button {
                            supervisor.askToResetDatabase()
                        } label: {
                            HStack(spacing: 8) {
                                if isDbSetupRunning {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(isDbSetupRunning ? "Reset Running" : "Reset Database")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.regular)
                        .disabled(!canResetDatabase)
                        .help(resetHelp)
                        .accessibilityLabel("Reset Database")
                        .accessibilityValue(resetAccessibilityValue)
                        .accessibilityHint(resetAccessibilityHint)

                        if let notice = supervisor.migrationNotice, notice.offersApply {
                            Button("Apply Migrations") { supervisor.applyMigrations() }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .disabled(isDbSetupRunning || supervisor.compatibilityNotice != nil)
                                .help("Apply only the migrations the database lacks. Nothing is deleted.")
                        }
                    }

                    if let notice = supervisor.migrationNotice {
                        Label(supervisor.migrationApplyError ?? notice.headline, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(resetStatusText)
                        .font(.caption2)
                        .foregroundStyle(canResetDatabase ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    if let note = supervisor.portalRestartNotice {
                        HStack(spacing: 8) {
                            Label(note, systemImage: "arrow.clockwise.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(EnvironmentSupervisor.restartPortalsTitle) { supervisor.restartPortals() }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }

                Divider()

                sectionHeader("Hotels")

                hotelActions

                Divider()

                sectionHeader("Pipeline")

                if let pipeline = supervisor.dbSetupPipeline,
                   pipeline.isRunning || pipeline.steps.contains(where: { $0.status != .pending }) {
                    DbSetupPipelineView(
                        pipeline: pipeline,
                        isRunning: supervisor.dbResetRunning,
                        onRetryFrom: { supervisor.runDbSetup(from: $0) },
                        onCancel: { supervisor.cancelDbSetup() },
                        onDismiss: { supervisor.dismissDbSetup() },
                        onCopy: { supervisor.copyDbStepReport($0) },
                        actionTitle: { title(for: $0) },
                        onAction: { perform($0, step: $1) }
                    )
                } else {
                    Text("No pipeline running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        // The verify reads the whole dump, so it runs once; a DB step that writes the
        // dump reads it again.
        .task { if supervisor.hotelDump == .unknown { await supervisor.refreshHotelDump() } }
    }

    // MARK: - Hotels

    private var canChangeDatabase: Bool {
        !isDbSetupRunning && supervisor.compatibilityNotice == nil
    }

    @ViewBuilder
    private var hotelActions: some View {
        let canLoad = supervisor.manifestProfileHasStep("reset", HotelCatalog.loadStepID)
        let canDownload = supervisor.manifestProfileHasStep("reset", HotelCatalog.fetchStepID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if canLoad {
                    Button(HotelCatalog.loadHotelsOnlyTitle) { supervisor.loadHotels() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(!canChangeDatabase)
                        .help("Load the hotels into the database as it is. Nothing is deleted.")
                }
                if canDownload {
                    Button(HotelCatalog.redownloadTitle) { supervisor.redownloadHotels() }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(!canChangeDatabase)
                        .help("Download the hotel dump from dev again. The database is not changed.")
                }
                Text(supervisor.hotelDump.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !canLoad && !canDownload {
                Text("This branch has no hotel steps in scripts/db/manifest.json.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The text of the fix button of a failed step, or nil when DB Tools has no
    /// button for it. Retry is on every failed row already.
    private func title(for action: RecoveryAction) -> String? {
        switch action {
        case .importSharedEnv: HotelCatalog.importButtonTitle
        case .redownloadHotels: HotelCatalog.redownloadTitle
        case .resetWithoutHotels: "\(HotelCatalog.resetWithoutHotelsTitle)…"
        case .openContainerRuntime: "Open \(ContainerRuntime.detect().appName)"
        case .openLog: "Open in Terminals"
        default: nil
        }
    }

    /// Runs the fix button of a failed step. A reset of any kind asks first.
    private func perform(_ action: RecoveryAction, step: DbSetupStep) {
        switch action {
        case .importSharedEnv:
            supervisor.importSharedEnvForHotels()
        case .redownloadHotels:
            supervisor.redownloadHotels()
        case .resetWithoutHotels:
            supervisor.askToResetDatabase()
        case .openContainerRuntime:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/\(ContainerRuntime.detect().appName).app"))
        case .openLog:
            WorkshopPanel.shared.navigation.selectedLogServiceID = step.logKey
            WorkshopPanel.shared.navigation.selectedSection = .logs
        default:
            break
        }
    }

    private var resetScenarioName: String? {
        if isDbSetupRunning, let pipeline = supervisor.dbSetupPipeline {
            return pipeline.seedScenario.name
        }
        return validSelectedScenario?.name
    }

    private var resetStatusText: String {
        if isDbSetupRunning {
            if let resetScenarioName {
                return "Database setup is running with the captured \(resetScenarioName) scenario."
            }
            return "Database setup is running. Wait for it to finish or cancel it from the pipeline."
        }
        if let notice = supervisor.compatibilityNotice { return notice.text }
        if let scenario = validSelectedScenario {
            return "Destructive: recreates the database using \(scenario.name)."
        }
        return "Reset is unavailable until a valid seed scenario is selected."
    }

    private var resetHelp: String {
        if isDbSetupRunning {
            if let resetScenarioName {
                return "Database setup is already running with the \(resetScenarioName) seed scenario"
            }
            return "Database setup is already running"
        }
        if supervisor.compatibilityNotice != nil {
            return "Update \(Flavor.current.displayName) before resetting the database"
        }
        if let scenario = validSelectedScenario {
            return "Reset the database using the \(scenario.name) seed scenario"
        }
        return "Choose a valid seed scenario before resetting the database"
    }

    private var resetAccessibilityValue: String {
        resetScenarioName ?? "No valid seed scenario selected"
    }

    private var resetAccessibilityHint: String {
        if isDbSetupRunning {
            return "Unavailable while database setup is running"
        }
        if let notice = supervisor.compatibilityNotice { return notice.text }
        if let scenario = validSelectedScenario {
            return "Destructive. Recreates the database using \(scenario.name), selected for the next reset"
        }
        return "Choose a valid seed scenario in the section above before resetting"
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}
