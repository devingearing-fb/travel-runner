import SwiftUI

/// The pill that shows a pending update. A click installs it, or opens Sparkle's window.
/// As the "Update now" button of the banner it does the same, and opens Sparkle's
/// window when nothing is downloaded.
struct UpdatePill: View {
    enum Style {
        case pill
        case updateNowButton
    }

    var style: Style = .pill

    @Environment(EnvironmentSupervisor.self) var supervisor
    @Environment(UpdateController.self) var updates: UpdateController?
    @State private var restartWarning: String?

    /// Services with a live process. A restart of the app stops them.
    private var liveServiceCount: Int {
        supervisor.serviceStates.values.filter { $0.pid != nil }.count
    }

    private var blockedReason: String? {
        UpdatePolicy.restartBlockedReason(
            dbResetRunning: supervisor.dbResetRunning,
            setupPipelineRunning: supervisor.dbSetupPipeline?.isRunning == true
        )
    }

    /// The update a click acts on. The button without a download asks Sparkle for it.
    private func target(_ updates: UpdateController) -> PendingUpdate? {
        switch style {
        case .pill: updates.pending
        case .updateNowButton: updates.pending ?? .available(version: "")
        }
    }

    var body: some View {
        if let updates, let pending = target(updates) {
            Button(action: { act(on: pending, updates: updates) }) {
                switch style {
                case .pill: pillLabel(pending)
                case .updateNowButton: Text("Update now")
                }
            }
            .modifier(ButtonLook(style: style))
            .disabled(blockedReason != nil)
            .help(blockedReason ?? "")
            .alert(
                UpdatePolicy.pillText(pending),
                isPresented: Binding(
                    get: { restartWarning != nil },
                    set: { if !$0 { restartWarning = nil } }
                )
            ) {
                Button("Restart now") {
                    // A reset or setup may have started while the question was open.
                    if blockedReason == nil { updates.installAndRestart() }
                }
                Button("Later", role: .cancel) {}
            } message: {
                Text(restartWarning ?? "")
            }
        }
    }

    private func pillLabel(_ pending: PendingUpdate) -> some View {
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

    private struct ButtonLook: ViewModifier {
        let style: Style

        func body(content: Content) -> some View {
            switch style {
            case .pill:
                content.buttonStyle(.plain)
            case .updateNowButton:
                content.buttonStyle(.bordered).controlSize(.small).tint(.orange)
            }
        }
    }

    private func act(on pending: PendingUpdate, updates: UpdateController) {
        let action = UpdatePolicy.pillAction(
            pending: pending,
            liveServices: liveServiceCount,
            blockedReason: blockedReason
        )
        switch action {
        case .showUpdateWindow: updates.checkForUpdates()
        case .install: updates.installAndRestart()
        case .ask(let warning): restartWarning = warning
        case .blocked: break
        }
    }
}
