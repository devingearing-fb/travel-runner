import SwiftUI

/// The pill that shows a pending update. A click installs it, or opens Sparkle's window.
struct UpdatePill: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @Environment(UpdateController.self) var updates: UpdateController?
    @State private var restartWarning: String?

    /// Services with a live process. A restart of the app stops them.
    private var liveServiceCount: Int {
        supervisor.serviceStates.values.filter { $0.pid != nil }.count
    }

    var body: some View {
        if let updates, let pending = updates.pending {
            Button(action: { act(on: pending, updates: updates) }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                    Text(UpdatePolicy.pillText(pending))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            // A restart in the middle of a database reset leaves the database half built.
            .disabled(supervisor.dbResetRunning)
            .help(supervisor.dbResetRunning ? "A database reset is running. Restart after it ends." : "")
            .alert(
                UpdatePolicy.pillText(pending),
                isPresented: Binding(
                    get: { restartWarning != nil },
                    set: { if !$0 { restartWarning = nil } }
                )
            ) {
                Button("Restart now") { updates.installAndRestart() }
                Button("Later", role: .cancel) {}
            } message: {
                Text(restartWarning ?? "")
            }
        }
    }

    private func act(on pending: PendingUpdate, updates: UpdateController) {
        switch pending {
        case .available:
            updates.checkForUpdates()
        case .ready:
            if let warning = UpdatePolicy.restartWarning(liveServices: liveServiceCount) {
                restartWarning = warning
            } else {
                updates.installAndRestart()
            }
        }
    }
}
