import SwiftUI
import AppKit

struct TerminalPane: View {
    let selectedServiceID: String?
    let logStore: LogStore
    @Environment(EnvironmentSupervisor.self) private var supervisor

    @State private var autoScroll = true
    @State private var entries: [LogEntry] = []
    @State private var lastVersion: Int = 0

    private var isAllMode: Bool { selectedServiceID == nil }
    private var isCascadeMode: Bool { selectedServiceID == "__cascade__" }

    private var displayEntries: [LogEntry] {
        entries
    }

    var body: some View {
        VStack(spacing: 0) {
            TerminalTextView(
                entries: displayEntries,
                autoScroll: autoScroll,
                format: { entry in
                    if isAllMode || isCascadeMode {
                        return formatInterleaved(entry)
                    }
                    return formatSingle(entry)
                }
            )

            terminalFooter
        }
        .task(id: taskKey) {
            lastVersion = 0
            entries = []
            while !Task.isCancelled {
                if !supervisor.panelVisible {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                await refreshEntries()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private var taskKey: String {
        selectedServiceID ?? "__all__"
    }

    private func refreshEntries() async {
        if isAllMode {
            let v = await logStore.allVersion()
            if v != lastVersion {
                lastVersion = v
                entries = await logStore.allEntries()
            }
        } else if isCascadeMode {
            let failedIDs = supervisor.sortedServiceIDs
                .compactMap { supervisor.serviceStates[$0] }
                .filter { $0.phase == .failed || $0.isCircuitBroken }
                .map(\.id)
            var compositeVersion = 0
            for id in failedIDs {
                compositeVersion += await logStore.version(for: id)
            }
            if compositeVersion != lastVersion {
                lastVersion = compositeVersion
                var merged: [LogEntry] = []
                for id in failedIDs {
                    merged.append(contentsOf: await logStore.entries(for: id))
                }
                entries = merged.sorted { $0.timestamp < $1.timestamp }
            }
        } else if let sid = selectedServiceID {
            let v = await logStore.version(for: sid)
            if v != lastVersion {
                lastVersion = v
                entries = await logStore.entries(for: sid)
            }
        }
    }

    private func formatInterleaved(_ entry: LogEntry) -> (text: String, color: NSColor) {
        let serviceTag = identifyService(entry)
        let tagColor = serviceTagColor(serviceTag)
        let text = "[\(serviceTag)] \(entry.text)"
        let color: NSColor = if entry.text.lowercased().contains("error") || entry.text.lowercased().contains("fail") {
            .systemRed
        } else if entry.text.lowercased().contains("warn") {
            .systemOrange
        } else {
            tagColor
        }
        return (text, color)
    }

    private func formatSingle(_ entry: LogEntry) -> (text: String, color: NSColor) {
        let text = entry.text
        let lower = text.lowercased()
        let color: NSColor = if lower.contains("error") || lower.contains("500") || lower.contains("fail") {
            .systemRed
        } else if lower.contains("warn") {
            .systemOrange
        } else if lower.contains("200") || lower.contains("ready") {
            .systemGreen
        } else if lower.contains("whsec_") {
            .systemYellow
        } else if entry.stream == .stderr {
            .systemOrange
        } else {
            .white
        }
        return (text, color)
    }

    private func identifyService(_ entry: LogEntry) -> String {
        for id in supervisor.sortedServiceIDs {
            if entry.text.contains(id) {
                return abbreviateID(id)
            }
        }
        return "???"
    }

    private func abbreviateID(_ id: String) -> String {
        let parts = id.split(separator: "-")
        if parts.count > 1 {
            return parts.map { String($0.prefix(3)).uppercased() }.prefix(2).joined()
        }
        return String(id.prefix(4)).uppercased()
    }

    private func serviceTagColor(_ tag: String) -> NSColor {
        let hash = tag.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let colors: [NSColor] = [.systemTeal, .systemBlue, .systemPurple, .systemPink, .systemIndigo, .systemMint]
        return colors[hash % colors.count]
    }

    private var terminalFooter: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $autoScroll) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 9))
                    Text("tail")
                        .font(.system(.caption2, design: .monospaced))
                }
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            Text("\(entries.count) lines")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                let allText = entries.map(\.text).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(allText, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Copy visible")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.3))
    }
}
