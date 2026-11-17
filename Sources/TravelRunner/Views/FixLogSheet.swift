import AppKit
import SwiftUI

/// Shows one fix of a setup check: its output while it runs, the time, Cancel,
/// and on failure the last lines and why. A guidance fix shows its text.
struct FixLogSheet: View {
    let run: FixRun
    let onClose: () -> Void

    @State private var commandCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: run.state == .guidance ? 220 : 420)
        .interactiveDismissDisabled(run.isRunning)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            stateIcon
            VStack(alignment: .leading, spacing: 2) {
                Text("Fix: \(run.checkName)").font(.headline)
                Text(stateText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if run.state != .guidance {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let end = run.endedAt ?? context.date
                    Text(FixRun.elapsedText(seconds: Int(end.timeIntervalSince(run.startedAt))))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch run.state {
        case .running: ProgressView().controlSize(.small)
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "stop.circle.fill").foregroundStyle(.secondary)
        case .guidance: Image(systemName: "info.circle.fill").foregroundStyle(.blue)
        }
    }

    private var stateText: String {
        switch run.state {
        case .running: "Running…"
        case .succeeded: "Done. The check runs again."
        case .failed(let text): text
        case .cancelled: "Cancelled."
        case .guidance: "Travel Runner does not install this for you."
        }
    }

    // MARK: - Output

    @ViewBuilder
    private var content: some View {
        if case .guidance(let text, _, let url) = run.action {
            VStack(alignment: .leading, spacing: 10) {
                Text(text).textSelection(.enabled)
                if let url {
                    Link(url.absoluteString, destination: url).font(.caption)
                }
                Spacer()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // On failure only the last lines show, so the cause is on screen.
            let lines = isFailed ? run.failureTail : run.lines
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if isFailed, run.lines.count > lines.count {
                            Text("The last \(lines.count) of \(run.lines.count) lines:")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.isEmpty ? " " : line).id(index)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
                .background(Color.secondary.opacity(0.05))
                .onChange(of: lines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = run.state { return true }
        return false
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let command = run.action.copyCommand {
                Button(commandCopied ? "Copied" : "Copy command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    commandCopied = true
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            Spacer()
            if run.isRunning {
                Button("Cancel", role: .cancel) { run.cancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            } else {
                Button("Close", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
    }
}
