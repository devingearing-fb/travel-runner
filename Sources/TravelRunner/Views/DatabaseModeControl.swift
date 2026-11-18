import SwiftUI

/// The one control that switches the database mode. DB Tools, Settings and the
/// footer use it, so each asks before a switch to the shared dev database.
struct DatabaseModeControl: View {
    enum Style {
        case segmented(width: CGFloat)
        case menu
    }

    @Environment(EnvironmentSupervisor.self) var supervisor
    let style: Style
    @State private var confirmingDev = false

    private var isSwitching: Bool { supervisor.actionsInFlight.contains("db-mode") }

    var body: some View {
        control
            .confirmationDialog(
                EnvironmentSupervisor.devDatabaseConfirmationTitle,
                isPresented: $confirmingDev,
                titleVisibility: .visible
            ) {
                Button(EnvironmentSupervisor.switchToDevTitle) { supervisor.setDatabaseMode(.remote) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(supervisor.devDatabaseConfirmation)
            }
    }

    /// A switch to dev asks first. A refused switch, such as one without the hosted
    /// dev values, goes straight through, so its notice says why.
    private func choose(_ mode: EnvironmentSupervisor.DatabaseMode) {
        guard mode != supervisor.dbMode else { return }
        if mode == .remote && supervisor.databaseModeRefusal(for: .remote) == nil {
            confirmingDev = true
        } else {
            supervisor.setDatabaseMode(mode)
        }
    }

    @ViewBuilder
    private var control: some View {
        switch style {
        case .segmented(let width):
            HStack(spacing: 6) {
                if isSwitching {
                    ProgressView().controlSize(.small)
                }
                Picker("", selection: Binding(
                    get: { supervisor.dbMode },
                    set: { choose($0) }
                )) {
                    Text("Local").tag(EnvironmentSupervisor.DatabaseMode.local)
                    Text("Dev").tag(EnvironmentSupervisor.DatabaseMode.remote)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: width)
                .disabled(isSwitching)
            }
        case .menu:
            Menu {
                Button("Local Database") { choose(.local) }
                    .disabled(supervisor.dbMode == .local)
                Button("Dev Database…") { choose(.remote) }
                    .disabled(supervisor.dbMode == .remote)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: supervisor.dbMode == .local ? "externaldrive" : "cloud")
                        .font(.system(size: 8))
                    Text("DB: \(supervisor.dbMode == .local ? "local" : "dev")")
                        .font(.system(.caption2, design: .monospaced))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(supervisor.dbMode == .remote ? Color.purple.opacity(0.2) : Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton)
            .disabled(isSwitching)
        }
    }
}

/// The header chip that stays while the apps use the shared dev database.
struct DevDatabaseChip: View {
    @Environment(EnvironmentSupervisor.self) var supervisor

    var body: some View {
        if supervisor.dbMode == .remote {
            HStack(spacing: 4) {
                Image(systemName: "cloud")
                    .font(.caption)
                Text("DEV DB")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
            }
            .foregroundStyle(.purple)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.purple.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .help("The portals read and write the shared hosted dev database.")
            .accessibilityLabel("Dev database in use")
        }
    }
}
