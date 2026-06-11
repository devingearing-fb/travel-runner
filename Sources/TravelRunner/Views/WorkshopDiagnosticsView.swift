import SwiftUI
import AppKit

struct WorkshopDiagnosticsView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @State private var diagnosticCopied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader("Diagnostics")

                Button {
                    Task { await copyDiagnosticBundle() }
                } label: {
                    Label(
                        diagnosticCopied ? "Copied!" : "Copy Diagnostics Bundle",
                        systemImage: diagnosticCopied ? "checkmark" : "doc.text.magnifyingglass"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Divider()

                sectionHeader("Preflight Checks")

                if supervisor.preflightChecks.isEmpty {
                    Text("No preflight checks have run yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(supervisor.preflightChecks) { check in
                        HStack(spacing: 8) {
                            Group {
                                switch check.result {
                                case .pending:
                                    ProgressView().controlSize(.small)
                                case .passed:
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                case .warning:
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                case .failed:
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                                }
                            }
                            .frame(width: 16)

                            Text(check.name)
                                .font(.caption)

                            Spacer()

                            if case .passed(let detail) = check.result {
                                Text(detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Divider()

                sectionHeader("Debug Tracking")

                if supervisor.debugTrackingEnabled {
                    HStack {
                        Image(systemName: "ant.fill")
                            .foregroundStyle(.green)
                        Text("Active — \(supervisor.debugOpenIssueCount) open issue\(supervisor.debugOpenIssueCount == 1 ? "" : "s")")
                            .font(.caption)
                        if supervisor.debugOpenIssueCount > 0 {
                            Button("View Issues") {
                                WorkshopPanel.shared.open(section: .issues)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                } else {
                    Text("Debug tracking is not enabled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                sectionHeader("About")

                let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                Text("Travel Runner v\(version) (build \(build))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
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

    private func copyDiagnosticBundle() async {
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
