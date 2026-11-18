import SwiftUI
import AppKit

struct WorkshopDiagnosticsView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @State private var diagnosticCopied = false
    /// Nil while the first read runs.
    @State private var toolReports: [ToolReport]?

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

                Text("Copies this Mac, the stack, the checks and the last \(DiagnosticsBundle.maxLogLines) lines of each failed service and DB step. Secrets are masked.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Button {
                    ReportProblem.run(supervisor: supervisor)
                } label: {
                    Label("Report a Problem…", systemImage: "square.and.arrow.up")
                }
                .controlSize(.regular)
                .disabled(supervisor.reportExportRunning)

                Text("Saves a zip to Downloads with the diagnostics, the logs and the open issues, and copies a summary for Slack.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                preflightSection

                Divider()

                toolsSection

                Divider()

                sectionHeader("Issue Capture")

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
                    Text("Issue capture is off")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                sectionHeader("About")

                let info = BuildInfo.current
                Text("\(info.flavor.displayName) \(info.summary) (build \(info.build ?? "?"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .task { await loadTools() }
    }

    /// The start checks with each reason and fix, and a button that runs them now.
    @ViewBuilder
    private var preflightSection: some View {
        HStack {
            sectionHeader("Preflight Checks")
            Spacer()
            Button {
                Task { await supervisor.runPreflightOnly() }
            } label: {
                if supervisor.preflightOnlyRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Text("Run Checks Now")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(supervisor.preflightOnlyRunning || supervisor.startRunning)
            .help(supervisor.startRunning ? ActionFeedback.checksDuringStart : "Runs the checks without a start. Opens no app.")
        }

        if supervisor.preflightChecks.isEmpty {
            Text("No checks have run yet. Press Run Checks Now to run them without a start.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(supervisor.preflightChecks) { check in
                PreflightCheckRow(check: check)
            }
        }
        let leftOut = supervisor.preflightPortsLeftOut
        if !leftOut.isEmpty {
            Text("Run Checks Now leaves out the ports of running services (\(leftOut.map(String.init).joined(separator: ", "))): those services hold them.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Where each tool is and which version the services get.
    @ViewBuilder
    private var toolsSection: some View {
        HStack {
            sectionHeader("Tools")
            Spacer()
            Button("Look Again") {
                Task {
                    toolReports = nil
                    await supervisor.tools.resolve(runner: supervisor.shell)
                    await loadTools()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(toolReports == nil)
        }

        if let toolReports {
            ForEach(toolReports) { tool in
                HStack(alignment: .top, spacing: 8) {
                    Group {
                        if tool.problem != nil {
                            // Not read is not the same as not found.
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        } else if tool.isFound {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                    .frame(width: 16)
                    Text(tool.text())
                        .font(.caption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
            if let note = supervisor.tools.capture.note {
                Text("\(note) \(Flavor.current.displayName) uses the PATH of the login shell and the standard tool folders.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func loadTools() async {
        let reports = await supervisor.tools.report(runner: supervisor.shell, cwd: toolsCwd)
        // The view went away: its commands were stopped, so the result says nothing.
        guard !Task.isCancelled else { return }
        toolReports = reports
    }

    /// The monorepo, so the Node is the one that its `.nvmrc` picks.
    private var toolsCwd: String? {
        guard let path = supervisor.monorepoPath, FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func copyDiagnosticBundle() async {
        let json = await supervisor.diagnosticsBundleJSON()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        diagnosticCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            diagnosticCopied = false
        }
    }
}
