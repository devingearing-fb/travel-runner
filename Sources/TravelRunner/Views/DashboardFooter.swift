import SwiftUI

struct DashboardFooter: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    let selectedServiceID: String?
    @State private var gitBranches: [String: String] = [:]

    private var displayedBranch: String? {
        if let sid = selectedServiceID {
            return gitBranches[sid]
        }
        return gitBranches["travel-portal"]
    }

    private var branchLabel: String? {
        if let sid = selectedServiceID, let branch = gitBranches[sid] {
            let name = supervisor.serviceStates[sid]?.definition.displayName ?? sid
            return "\(name): \(branch)"
        }
        if let branch = gitBranches["travel-portal"] {
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
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button("Local Database") { supervisor.toggleDatabaseMode() }
                    .disabled(supervisor.dbMode == .local)
                Button("Dev Database") { supervisor.toggleDatabaseMode() }
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
        .task(id: selectedServiceID) {
            let sid = selectedServiceID ?? "travel-portal"
            if gitBranches[sid] == nil, let cwd = supervisor.serviceCwd(sid) {
                gitBranches[sid] = await fetchGitBranch(cwd)
            }
        }
        .task {
            if let cwd = supervisor.serviceCwd("travel-portal") {
                gitBranches["travel-portal"] = await fetchGitBranch(cwd)
            }
        }
    }

    private func fetchGitBranch(_ path: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: branch?.isEmpty == false ? branch : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}
