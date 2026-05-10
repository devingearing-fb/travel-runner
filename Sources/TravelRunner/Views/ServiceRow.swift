import SwiftUI

struct ServiceRow: View {
    let state: ServiceState
    let logStore: LogStore
    let onRestart: () -> Void
    var onPublishRetry: (() -> Void)? = nil
    var onCascadeRestart: (() -> Void)? = nil

    @State private var showLogs = false
    @State private var logEntries: [LogEntry] = []
    @State private var lastVersion: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Main row
            HStack(spacing: 6) {
                Circle()
                    .fill(state.phase.color)
                    .frame(width: 7, height: 7)

                Text(state.definition.displayName)
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                // Port badge
                if let port = state.definition.probe?.port {
                    Text(":\(port)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Text(state.phase.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(state.phase == .failed ? .red : .secondary)

                if state.phase == .running || state.phase == .failed {
                    Button(action: onRestart) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .help("Restart")

                    if let onCascadeRestart {
                        Button(action: onCascadeRestart) {
                            Image(systemName: "arrow.clockwise.circle")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help("Restart with dependents")
                    }
                }

                Button {
                    showLogs.toggle()
                } label: {
                    Image(systemName: showLogs ? "chevron.up" : "terminal")
                        .font(.caption2)
                        .foregroundStyle(showLogs ? .primary : .secondary)
                }
                .buttonStyle(.borderless)
                .help(showLogs ? "Hide logs" : "Show logs")
            }

            // Subtitle line: timestamps, restart count, secret
            HStack(spacing: 8) {
                if let started = state.lastStarted, state.phase == .running {
                    Text("up \(started, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if state.phase == .failed, let stopped = state.lastStopped {
                    Text("failed \(stopped, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.7))
                }
                if state.isCircuitBroken {
                    Text("crash-looping — auto-restart stopped")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if state.restartCount > 0 {
                    Text("restarted \(state.restartCount)x")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let artifact = state.capturedArtifact {
                    Text(artifact.prefix(20) + "...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            // Publish & Retry for yalc failures
            if state.phase == .failed, let retry = onPublishRetry {
                Button("Publish & Retry") { retry() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.orange)
            }

            // Log viewer
            if showLogs {
                logView
                    .frame(height: 120)
                    .task {
                        while !Task.isCancelled {
                            let v = await logStore.version(for: state.id)
                            if v != lastVersion {
                                lastVersion = v
                                logEntries = await logStore.entries(for: state.id)
                            }
                            try? await Task.sleep(for: .milliseconds(500))
                        }
                    }
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .onChange(of: state.phase) { _, newPhase in
            if newPhase == .failed { showLogs = true }
        }
    }

    private var logView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("LOGS")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let allText = logEntries.map(\.text).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(allText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Copy all logs")

                Button {
                    Task { await logStore.clear(serviceID: state.id) }
                    logEntries = []
                } label: {
                    Image(systemName: "trash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear logs")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)

            TerminalTextView(
                entries: logEntries,
                autoScroll: true,
                format: { entry in
                    let formatted = PinoFormatter.format(entry) { e in
                        e.stream == .stderr ? .systemRed : .white
                    }
                    return (formatted.text, formatted.color)
                }
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
