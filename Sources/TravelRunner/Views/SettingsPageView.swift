import SwiftUI

struct SettingsPageView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    let onDismiss: () -> Void
    let onReconfigureRepos: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    modesSection
                    pathsSection
                    aboutSection
                }
                .padding(16)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onDismiss) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                    Text("Back")
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer()

            Text("Settings")
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.bold)

            Spacer()

            Color.clear.frame(width: 40)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Modes

    private var modesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Modes")

            VStack(spacing: 0) {
                settingsRow {
                    HStack {
                        Label("Database", systemImage: "cylinder")
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { supervisor.dbMode },
                            set: { _ in supervisor.toggleDatabaseMode() }
                        )) {
                            Text("Local").tag(EnvironmentSupervisor.DatabaseMode.local)
                            Text("Dev").tag(EnvironmentSupervisor.DatabaseMode.remote)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                    }
                }

                Divider().padding(.leading, 32)

                settingsRow {
                    Toggle(isOn: Binding(
                        get: { supervisor.networkMode },
                        set: { _ in supervisor.toggleNetworkMode() }
                    )) {
                        Label("LAN Mode", systemImage: "wifi")
                            .font(.system(.caption, design: .monospaced))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if supervisor.networkMode, let ip = supervisor.localIP {
                    HStack {
                        Spacer()
                        Text(ip)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.green)
                            .padding(.trailing, 8)
                    }
                    .padding(.bottom, 4)
                }

                Divider().padding(.leading, 32)

                settingsRow {
                    Toggle(isOn: Binding(
                        get: { supervisor.partnerPortalEnabled },
                        set: { supervisor.setPartnerPortalEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Partner Portal", systemImage: "building.2")
                                .font(.system(.caption, design: .monospaced))
                            Text("Run partner portal on port 3001 sharing the same database")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                Divider().padding(.leading, 32)

                settingsRow {
                    Toggle(isOn: Binding(
                        get: { supervisor.autoRelinkYalc },
                        set: { supervisor.setAutoRelinkYalc($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Auto-relink fb-travel-data", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(.caption, design: .monospaced))
                            Text("Rebuilds and relinks when source changes are detected")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if supervisor.yalcStale {
                    HStack(spacing: 4) {
                        Spacer()
                        Text("stale")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                        Button("Relink Now") {
                            supervisor.publishAndRetryYalc()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .padding(.trailing, 8)
                    }
                    .padding(.bottom, 4)
                }
            }
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Paths

    private var pathsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Repository Paths")

            VStack(spacing: 0) {
                pathRow(label: "Booking Portal", icon: "globe",
                        path: supervisor.serviceCwd("travel-portal"))
                Divider().padding(.leading, 32)
                pathRow(label: "Universal Login", icon: "person.badge.key",
                        path: supervisor.serviceCwd("universal-login"))
                Divider().padding(.leading, 32)
                pathRow(label: "fb-travel-data", icon: "shippingbox",
                        path: expandedPath(config?.paths?.travelData))
                Divider().padding(.leading, 32)
                pathRow(label: "Partner Portal", icon: "building.2",
                        path: expandedPath(config?.paths?.partnerPortal))
            }
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: onReconfigureRepos) {
                Label("Reconfigure Repos...", systemImage: "folder.badge.gearshape")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("About")

            VStack(spacing: 0) {
                settingsRow {
                    HStack {
                        Label("Version", systemImage: "info.circle")
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().padding(.leading, 32)

                settingsRow {
                    HStack {
                        Label("Debug Tracking", systemImage: "ant")
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        if supervisor.debugTrackingEnabled {
                            let count = supervisor.debugOpenIssueCount
                            Text(count > 0 ? "\(count) open issue\(count == 1 ? "" : "s")" : "Active")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(count > 0 ? .orange : .green)
                        } else {
                            Text("Disabled")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }

    private func settingsRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }

    private func pathRow(label: String, icon: String, path: String?) -> some View {
        settingsRow {
            HStack {
                Label(label, systemImage: icon)
                    .font(.system(.caption, design: .monospaced))
                Spacer()
                if let path {
                    Text(abbreviatePath(path))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .trailing)
                } else {
                    Text("Not configured")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.7))
                }
            }
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func expandedPath(_ path: String?) -> String? {
        path.map { NSString(string: $0).expandingTildeInPath }
    }

    private var config: ServiceConfig? {
        try? ConfigLoader.load()
    }
}
