import SwiftUI

struct WorkshopDbToolsView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor

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

                sectionHeader("Actions")

                HStack(spacing: 12) {
                    Button("Reset Database") {
                        supervisor.resetDatabase()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.regular)

                    if supervisor.migrationsBannerVisible {
                        Label("Migrations changed", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
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

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}
