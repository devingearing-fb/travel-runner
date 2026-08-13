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
        !isDbSetupRunning && validSelectedScenario != nil
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

                Divider()

                sectionHeader("Actions")

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Button {
                            supervisor.resetDatabase()
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

                        if supervisor.migrationsBannerVisible {
                            Label("Migrations changed", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(resetStatusText)
                        .font(.caption2)
                        .foregroundStyle(canResetDatabase ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                sectionHeader("Pipeline")

                if let pipeline = supervisor.dbSetupPipeline,
                   pipeline.isRunning || pipeline.steps.contains(where: { $0.status != .pending }) {
                    DbSetupPipelineView(
                        pipeline: pipeline,
                        isRunning: supervisor.dbResetRunning,
                        onRetryFrom: { supervisor.runDbSetup(from: $0) },
                        onCancel: { supervisor.cancelDbSetup() },
                        onDismiss: { supervisor.dismissDbSetup() }
                    )
                } else {
                    Text("No pipeline running")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
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
