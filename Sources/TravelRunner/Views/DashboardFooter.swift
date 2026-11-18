import SwiftUI

struct DashboardFooter: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    let selectedServiceID: String?

    private var branchLabel: String? {
        if let sid = selectedServiceID, let branch = supervisor.gitBranches[sid] {
            let name = supervisor.serviceStates[sid]?.definition.displayName ?? sid
            return "\(name): \(branch)"
        }
        if let branch = supervisor.gitBranches["travel-portal"] {
            return branch
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if let label = branchLabel {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8))
                    Text(label)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)

                    if let sid = selectedServiceID ?? (supervisor.gitBranches.keys.contains("travel-portal") ? "travel-portal" : nil),
                       let behind = supervisor.gitBehindCounts[sid], behind > 0 {
                        Text("\(behind)\u{2193}")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.blue)
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            DatabaseModeControl(style: .menu)

            Button {
                supervisor.toggleNetworkMode()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: supervisor.networkMode ? "wifi" : "wifi.slash")
                        .font(.system(size: 8))
                    Text("LAN")
                        .font(.system(.caption2, design: .monospaced))
                }
                .foregroundStyle(supervisor.networkMode ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help(supervisor.networkMode
                ? "LAN Mode ON\(supervisor.localIP.map { " (\($0))" } ?? "")"
                : "LAN Mode OFF")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.15))
    }
}
