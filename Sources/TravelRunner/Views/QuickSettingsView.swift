import SwiftUI
import AppKit

struct QuickSettingsView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    let onDismiss: () -> Void
    let onOpenFullSettings: () -> Void
    @State private var diagnosticCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.bold)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsSection("Environment") {
                        settingRow("Database Mode") {
                            Picker("", selection: Binding(
                                get: { supervisor.dbMode },
                                set: { _ in supervisor.toggleDatabaseMode() }
                            )) {
                                Text("Local").tag(EnvironmentSupervisor.DatabaseMode.local)
                                Text("Dev").tag(EnvironmentSupervisor.DatabaseMode.remote)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 140)
                        }

                        settingRow("LAN Mode") {
                            Toggle("", isOn: Binding(
                                get: { supervisor.networkMode },
                                set: { _ in supervisor.toggleNetworkMode() }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }

                        if supervisor.networkMode, let ip = supervisor.localIP {
                            HStack {
                                Spacer()
                                Text(ip)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        settingRow("Partner Portal") {
                            Toggle("", isOn: Binding(
                                get: { supervisor.partnerPortalEnabled },
                                set: { supervisor.setPartnerPortalEnabled($0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }

                        settingRow("Auto-relink yalc") {
                            HStack(spacing: 6) {
                                if supervisor.yalcStale {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                Toggle("", isOn: Binding(
                                    get: { supervisor.autoRelinkYalc },
                                    set: { supervisor.setAutoRelinkYalc($0) }
                                ))
                                .toggleStyle(.switch)
                                .controlSize(.small)
                            }
                        }
                    }

                    settingsSection("Actions") {
                        Button("Reset Database") {
                            supervisor.resetDatabase()
                            onDismiss()
                        }
                        .font(.caption)

                        Button("Clear Cache & Restart Portal") {
                            supervisor.clearCacheAndRestart("travel-portal")
                            onDismiss()
                        }
                        .font(.caption)

                        if supervisor.yalcStale {
                            Button("Relink fb-travel-data Now") {
                                supervisor.publishAndRetryYalc()
                                onDismiss()
                            }
                            .font(.caption)
                        }

                        Button {
                            Task { await copyDiagnostics() }
                        } label: {
                            Label(
                                diagnosticCopied ? "Copied!" : "Copy Diagnostics",
                                systemImage: diagnosticCopied ? "checkmark" : "doc.text.magnifyingglass"
                            )
                            .font(.caption)
                        }
                    }

                    Divider()

                    Button {
                        onOpenFullSettings()
                    } label: {
                        HStack {
                            Text("Full Settings & Diagnostics")
                                .font(.caption)
                            Spacer()
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.accentColor)

                    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                    Text("v\(version)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
            }
        }
        .frame(width: 280)
        .frame(maxHeight: 420)
    }

    private func settingsSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func settingRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.caption)
            Spacer()
            control()
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

    private func copyDiagnostics() async {
        let secretPatterns = ["SECRET", "KEY", "TOKEN", "PASSWORD"]
        var bundle: [String: Any] = [
            "health": supervisor.health.rawValue,
            "currentPhase": supervisor.currentPhase.rawValue,
            "networkMode": supervisor.networkMode,
            "localIP": supervisor.localIP ?? "none",
            "generatedAt": ISO8601DateFormatter().string(from: .now),
        ]
        if let error = supervisor.lastError { bundle["lastError"] = error }
        if let rootCause = supervisor.rootCauseDescription { bundle["rootCause"] = rootCause }

        var services: [String: [String: Any]] = [:]
        for (id, state) in supervisor.serviceStates {
            var info: [String: Any] = [
                "phase": state.phase.rawValue,
                "restartCount": state.restartCount,
            ]
            if let pid = state.pid { info["pid"] = pid }
            if let exitCode = state.exitCode { info["exitCode"] = exitCode }
            if let started = state.lastStarted { info["uptimeSeconds"] = Int(Date.now.timeIntervalSince(started)) }
            if state.isCircuitBroken { info["circuitBroken"] = true }
            services[id] = info
        }
        bundle["services"] = services

        var gitBranches: [String: String] = [:]
        for id in supervisor.sortedServiceIDs {
            if let cwd = supervisor.serviceCwd(id) {
                if let branch = await fetchGitBranch(cwd) {
                    gitBranches[id] = branch
                }
            }
        }
        bundle["gitBranches"] = gitBranches

        var logs: [String: [String]] = [:]
        for id in supervisor.sortedServiceIDs {
            let entries = await supervisor.logStore.entries(for: id)
            logs[id] = entries.suffix(20).map { entry in
                let upper = entry.text.uppercased()
                for pat in secretPatterns where upper.contains(pat) {
                    return "[REDACTED]"
                }
                return entry.text
            }
        }
        bundle["recentLogs"] = logs

        if let data = try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
            diagnosticCopied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                diagnosticCopied = false
            }
        }
    }
}
