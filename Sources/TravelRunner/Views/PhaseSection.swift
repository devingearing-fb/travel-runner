import SwiftUI

struct PhaseSection: View {
    let phase: String
    let services: [ServiceState]
    let logStore: LogStore
    let onRestart: (String) -> Void
    let onCascadeRestart: ((String) -> Void)?
    let onPublishRetry: (() -> Void)?
    var onResetDb: (() -> Void)? = nil
    var dbResetRunning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(phase)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)

                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 1)

                if phase == "GROUND", let resetDb = onResetDb {
                    if dbResetRunning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Reset DB") { resetDb() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Run npx supabase db reset")
                    }
                }
            }
            .padding(.top, 4)

            ForEach(services) { state in
                ServiceRow(
                    state: state,
                    logStore: logStore,
                    onRestart: { onRestart(state.id) },
                    onPublishRetry: state.id == "yalc-link" ? onPublishRetry : nil,
                    onCascadeRestart: onCascadeRestart.map { callback in { callback(state.id) } }
                )
            }
        }
    }
}
