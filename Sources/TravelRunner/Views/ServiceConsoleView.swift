import SwiftUI
import AppKit

struct ServiceConsoleView: View {
    let serviceID: String
    let logStore: LogStore
    @Environment(EnvironmentSupervisor.self) private var supervisor

    @State private var logEntries: [LogEntry] = []
    @State private var autoScroll = true
    @State private var enabledLevels: Set<LogLevel> = Set(LogLevel.allCases)
    @State private var lastVersion: Int = 0
    @State private var searchText = ""

    private var filteredEntries: [LogEntry] {
        logEntries.filter { entry in
            if let level = entry.level, !enabledLevels.contains(level) { return false }
            if !searchText.isEmpty, !entry.text.localizedCaseInsensitiveContains(searchText) { return false }
            return true
        }
    }

    private var levelCounts: [LogLevel: Int] {
        var counts: [LogLevel: Int] = [:]
        for entry in logEntries {
            if let level = entry.level {
                counts[level, default: 0] += 1
            }
        }
        return counts
    }

    var body: some View {
        VStack(spacing: 0) {
            filterToolbar

            TerminalTextView(
                entries: filteredEntries,
                autoScroll: autoScroll,
                format: { entry in
                    let formatted = PinoFormatter.format(entry) { e in
                        let text = e.text.lowercased()
                        if text.contains("error") || text.contains("500") || text.contains("fail") { return .systemRed }
                        if text.contains("warn") { return .systemOrange }
                        if text.contains("200") || text.contains("[200]") || text.contains("ready") { return .systemGreen }
                        if text.contains("post") || text.contains("-->") || text.contains("get") { return .systemTeal }
                        if text.contains("whsec_") { return .systemYellow }
                        if e.stream == .stderr { return .systemOrange }
                        return .white
                    }
                    return (formatted.text, formatted.color)
                }
            )

            statusBar
        }
        .task {
            while !Task.isCancelled {
                if !supervisor.panelVisible {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                let v = await logStore.version(for: serviceID)
                if v != lastVersion {
                    lastVersion = v
                    logEntries = await logStore.entries(for: serviceID)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Filter Toolbar

    private var filterToolbar: some View {
        HStack(spacing: 6) {
            let counts = levelCounts
            ForEach(LogLevel.allCases, id: \.self) { level in
                FilterPill(
                    level: level,
                    count: counts[level] ?? 0,
                    isEnabled: enabledLevels.contains(level)
                ) {
                    if enabledLevels.contains(level) {
                        enabledLevels.remove(level)
                    } else {
                        enabledLevels.insert(level)
                    }
                }
            }

            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(width: 120)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Spacer()

            Toggle(isOn: $autoScroll) {
                Text("Auto-scroll")
                    .font(.caption2)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Button {
                let allText = filteredEntries.map(\.text).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(allText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Copy visible")

            Button {
                Task { await logStore.clear(serviceID: serviceID) }
                logEntries = []
            } label: {
                Image(systemName: "trash")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Clear")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.3))
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(logEntries.isEmpty ? Color.gray : Color.green)
                .frame(width: 6, height: 6)

            if logEntries.isEmpty {
                Text("Waiting for output...")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else {
                let filtered = filteredEntries.count
                let total = logEntries.count
                Text(filtered == total ? "\(total) lines" : "\(filtered) of \(total) lines")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            let counts = levelCounts
            if let errCount = counts[.error], errCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 8))
                    Text("\(errCount)")
                        .font(.system(.caption2, design: .monospaced))
                }
                .foregroundStyle(.red)
            }
            if let wrnCount = counts[.warning], wrnCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                    Text("\(wrnCount)")
                        .font(.system(.caption2, design: .monospaced))
                }
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.3))
    }
}

// MARK: - Filter Pill

struct FilterPill: View {
    let level: LogLevel
    let count: Int
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Circle()
                    .fill(isEnabled ? level.pillColor : Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(level.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.medium)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(isEnabled ? level.pillColor : .secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(isEnabled ? level.pillColor.opacity(0.15) : Color.secondary.opacity(0.06))
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
    }
}

extension LogLevel {
    var pillColor: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .info: .green
        case .debug: .gray
        }
    }
}
