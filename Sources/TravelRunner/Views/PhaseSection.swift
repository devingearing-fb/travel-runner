import SwiftUI

struct PhaseSection: View {
    let phase: String
    let services: [ServiceState]
    let logStore: LogStore
    let onRestart: (String) -> Void
    let onCascadeRestart: ((String) -> Void)?
    let onPublishRetry: (() -> Void)?
    var dbResetRunning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(phase)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 0.5)
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
