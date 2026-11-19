import SwiftUI

struct ServiceRow: View {
    let state: ServiceState
    let logStore: LogStore
    let onRestart: () -> Void
    var onCascadeRestart: (() -> Void)? = nil
    var behindCount: Int = 0
    var depsStale: Bool = false

    @Environment(EnvironmentSupervisor.self) var supervisor
    @State private var showLogs = false
    @State private var logEntries: [LogEntry] = []
    @State private var lastVersion: Int = 0

    private var showSubtitle: Bool {
        state.restartCount > 0 || state.isCircuitBroken || state.capturedArtifact != nil || rowCondition != nil
            || state.modeNote != nil || stoppingText != nil
    }

    /// What a stop with a teardown command does, while it runs. The Supabase
    /// stack says what its start or stop prints.
    private var stoppingText: String? {
        switch state.phase {
        case .starting: state.progressNote
        case .stopping: state.progressNote ?? state.definition.stoppingText
        default: nil
        }
    }

    /// Why a skipped, failed or waiting service is in that phase, why a start takes
    /// long, or why a running service is unhealthy.
    private var rowCondition: ServiceCondition? {
        switch (state.phase, state.condition?.kind) {
        case (.skipped, _), (.failed, _), (.waiting, _), (.stopped, .stoppedByUser?), (.starting, .slowStart?),
             (.running, .unhealthy?): state.condition
        default: nil
        }
    }

    /// The buttons of a slow start or an unhealthy service: "Keep waiting", "Restart".
    private var inlineActions: [RecoveryAction] {
        guard let condition = rowCondition, condition.kind == .slowStart || condition.kind == .unhealthy else { return [] }
        return condition.actions.filter { $0 != .openLog && supervisor.canPerform($0, for: state.id) }
    }

    private var isActionInFlight: Bool {
        supervisor.actionsInFlight.contains(state.id)
    }

    private var canRerunOneshot: Bool {
        state.definition.resolvedType == .oneshot
            && (state.phase == .completed || state.phase == .skipped)
    }

    private var canStart: Bool { supervisor.canStartFromRow(state) }

    private var canRestart: Bool { state.phase == .running || state.phase == .failed }

    /// In a stopped stack, Start on a row starts that service and what it needs.
    private var startTitle: String {
        supervisor.nothingRuns ? "Start \(state.definition.displayName) only (with what it needs)" : "Start"
    }

    /// One action of the row: an icon that is large enough to see, with a tooltip.
    private func rowButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }

    /// The actions of the service with their names. The "…" button and a right
    /// click on the row show the same list.
    @ViewBuilder private var menuItems: some View {
        if canStart {
            Button(startTitle) { supervisor.startFromRow(state.id) }
        }
        if canRerunOneshot {
            Button("Run again") { onRestart() }
        }
        if canRestart {
            Button("Restart") { onRestart() }
        }
        if canRestart || canRerunOneshot, let onCascadeRestart {
            Button("Restart with dependents") { onCascadeRestart() }
        }
        if canRestart {
            if EnvironmentSupervisor.cacheClearingServices.contains(state.id) {
                Button("Clear cache and restart") { supervisor.clearCacheAndRestart(state.id) }
            }
        }
        if supervisor.canStopFromRow(state) {
            Button("Stop") { supervisor.stopService(state.id) }
        }
        Divider()
        if let url = supervisor.browserURL(for: state.id) {
            Button("Open in browser") { NSWorkspace.shared.open(url) }
                .disabled(state.phase != .running)
        }
        Button(showLogs ? "Hide logs" : "Show logs") { showLogs.toggle() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if state.phase == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                        .frame(width: 7)
                } else {
                    Circle()
                        .fill(state.phase.color)
                        .frame(width: 7, height: 7)
                }

                Text(state.definition.displayName)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                    .lineLimit(1)

                if state.definition.resolvedType == .oneshot {
                    Text("one-shot")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }

                if let port = state.definition.probe?.port {
                    Text(":\(port)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Text(state.phase.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(state.phase == .failed ? .red : .secondary)

                if behindCount > 0 {
                    Text("\(behindCount) behind")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue, in: Capsule())
                        .contentTransition(.numericText())
                }

                if depsStale, supervisor.canPerform(.installDependencies, for: state.id) {
                    Button {
                        supervisor.perform(.installDependencies, for: state.id)
                    } label: {
                        Text(RecoveryAction.installDependencies.title())
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange, in: Capsule())
                    }
                    .buttonStyle(.borderless)
                    .disabled(isActionInFlight)
                    .help("The packages do not match the lockfile. Install them, then restart \(state.definition.displayName).")
                }

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

                Spacer()

                if isActionInFlight {
                    ProgressView().controlSize(.mini)
                } else {
                    if canRestart || canRerunOneshot {
                        rowButton("arrow.clockwise", help: canRerunOneshot && state.phase != .failed ? "Run again" : "Restart",
                                  action: onRestart)
                    }
                    if supervisor.canStopFromRow(state) {
                        rowButton("stop.fill", help: "Stop") { supervisor.stopService(state.id) }
                    }
                    if canStart {
                        rowButton("play.fill", help: startTitle) { supervisor.startFromRow(state.id) }
                    }
                }

                // Every action of the row, with its name.
                Menu {
                    menuItems
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Actions: start, stop, restart, open in browser")
                .accessibilityLabel("Actions of \(state.definition.displayName)")

                rowButton(showLogs ? "chevron.up" : "terminal", help: showLogs ? "Hide logs" : "Show logs") {
                    showLogs.toggle()
                }
                .foregroundStyle(showLogs ? .primary : .secondary)
            }
            .contentShape(Rectangle())
            .contextMenu { menuItems }

            if showSubtitle {
                HStack(spacing: 8) {
                    if let stoppingText {
                        Text(stoppingText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let condition = rowCondition {
                        Text(condition.text)
                            .font(.caption2)
                            .foregroundStyle(state.phase == .failed ? .red : condition.kind == .unhealthy ? .orange : .secondary)
                            .lineLimit(2)
                            .help(condition.text)
                    }
                    ForEach(inlineActions, id: \.self) { action in
                        Button(action.title()) {
                            supervisor.perform(action, for: state.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(supervisor.inlineActionsBusy(state.id))
                    }
                    if let halt = state.haltReason, rowCondition == nil {
                        Text("\(halt.label) — auto-restart stopped")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    } else if state.restartCount > 0 {
                        Text("restarted \(state.restartCount)x")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .contentTransition(.numericText())
                    }
                    if let mode = state.modeNote {
                        Text(mode)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let artifact = state.capturedArtifactSummary {
                        Text(artifact)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

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
        .padding(.vertical, 2)
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
                    let redactor = supervisor.makeRedactor()
                    let allText = logEntries.map { redactor.redact($0.text) }.joined(separator: "\n")
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
                .help("Clear view (the log file is kept)")
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
