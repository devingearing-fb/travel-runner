import SwiftUI

struct TriageCard: View {
    let state: ServiceState
    let logStore: LogStore
    let onRestart: () -> Void
    let onCascadeRestart: () -> Void
    var onClearCache: (() -> Void)? = nil
    var onPublishRetry: (() -> Void)? = nil

    @State private var logTail: [LogEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 7, height: 7)

                Text(state.definition.displayName)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)

                Text(state.phase.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.red)

                Spacer()

                if state.isCircuitBroken {
                    Text("crash-looping")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if let stopped = state.lastStopped {
                    Text("failed \(stopped, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.7))
                }

                if state.restartCount > 0 {
                    Text("\(state.restartCount)x")
                        .font(.system(.caption2, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                        .contentTransition(.numericText())
                }
            }

            if !logTail.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(logTail) { entry in
                        Text(formatLogLine(entry))
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(logColor(entry))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            HStack(spacing: 6) {
                Button(action: onRestart) {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button(action: onCascadeRestart) {
                    Label("Cascade", systemImage: "arrow.clockwise.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                if let onClearCache {
                    Button(action: onClearCache) {
                        Label("Clear Cache", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.orange)
                }

                if let onPublishRetry {
                    Button("Publish & Retry", action: onPublishRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(.orange)
                }
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.red.opacity(0.25), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task {
            while !Task.isCancelled {
                let entries = await logStore.entries(for: state.id)
                logTail = Array(entries.suffix(3))
                try? await Task.sleep(for: .milliseconds(1000))
            }
        }
    }

    private func formatLogLine(_ entry: LogEntry) -> String {
        let raw = entry.text.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("{"),
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let msg = json["msg"] as? String {
            let module = json["module"] as? String
            if let module { return "[\(module)] \(msg)" }
            return msg
        }
        return raw
    }

    private func logColor(_ entry: LogEntry) -> Color {
        switch entry.level {
        case .error: .red
        case .warning: .orange
        default: entry.stream == .stderr ? .red.opacity(0.8) : .white.opacity(0.7)
        }
    }
}
