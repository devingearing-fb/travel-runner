import SwiftUI
import AppKit

extension DebugTracker.Issue: Identifiable {}

struct WorkshopIssuesView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @State private var statusFilter = "open"
    @State private var issues: [DebugTracker.Issue] = []
    @State private var selectedID: String?
    @State private var isLoading = false

    private var selectedIssue: DebugTracker.Issue? {
        issues.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if issues.isEmpty && !isLoading {
                ContentUnavailableView(
                    statusFilter == "open" ? "No Open Issues" : "No Closed Issues",
                    systemImage: statusFilter == "open" ? "checkmark.seal" : "archivebox",
                    description: Text(statusFilter == "open"
                        ? "Crashes, circuit breaker trips, and probe failures are captured here automatically"
                        : "Closed issues with their resolutions appear here")
                )
            } else {
                VSplitView {
                    issueList
                        .frame(minHeight: 120, idealHeight: 200)
                    if let issue = selectedIssue {
                        IssueDetailView(
                            issue: issue,
                            status: statusFilter,
                            onClosed: {
                                selectedID = nil
                                Task { await reload() }
                            }
                        )
                        .frame(minHeight: 200)
                    } else {
                        ContentUnavailableView(
                            "Select an Issue",
                            systemImage: "ant",
                            description: Text("Choose an issue above to inspect logs and state")
                        )
                        .frame(minHeight: 200)
                    }
                }
            }
        }
        .task(id: statusFilter) { await reload() }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $statusFilter) {
                Text("Open").tag("open")
                Text("Closed").tag("closed")
            }
            .pickerStyle(.segmented)
            .frame(width: 160)

            Spacer()

            if isLoading {
                ProgressView().controlSize(.small)
            }

            Button {
                Task { await reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var issueList: some View {
        List(issues, selection: $selectedID) { issue in
            HStack(spacing: 8) {
                Image(systemName: severityIcon(issue.severity))
                    .foregroundStyle(severityColor(issue.severity))
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.summary)
                        .font(.caption)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let sid = issue.serviceId, !sid.isEmpty {
                            Text(sid)
                                .font(.system(size: 9, design: .monospaced))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                        Text(issue.trigger)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let date = Self.parseISO(issue.createdAt) {
                            Text(date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if issue.recurrenceCount > 0 {
                    Text("×\(issue.recurrenceCount + 1)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.orange, in: Capsule())
                        .help("Recurred \(issue.recurrenceCount) time\(issue.recurrenceCount == 1 ? "" : "s") after first capture")
                }
            }
            .tag(issue.id)
        }
        .listStyle(.inset)
    }

    private func reload() async {
        isLoading = true
        issues = await supervisor.listDebugIssues(status: statusFilter)
        isLoading = false
    }

    private func severityIcon(_ severity: String) -> String {
        switch severity {
        case "error", "high": "exclamationmark.circle.fill"
        case "warning": "exclamationmark.triangle.fill"
        default: "info.circle.fill"
        }
    }

    private func severityColor(_ severity: String) -> Color {
        switch severity {
        case "error": .red
        case "high": .orange
        case "warning": .yellow
        default: .secondary
        }
    }

    static func parseISO(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }
}

private struct IssueDetailView: View {
    let issue: DebugTracker.Issue
    let status: String
    let onClosed: () -> Void

    @Environment(EnvironmentSupervisor.self) var supervisor
    @State private var detailTab = 0
    @State private var logs: [String: String] = [:]
    @State private var selectedLogFile: String?
    @State private var snapshot: String?
    @State private var resolutionText = ""
    @State private var isClosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader
            Divider()

            Picker("", selection: $detailTab) {
                Text("Logs").tag(0)
                Text("State").tag(1)
                Text("Info").tag(2)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .padding(8)

            Group {
                switch detailTab {
                case 0: logsTab
                case 1: stateTab
                default: infoTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if status == "open" {
                Divider()
                closeBar
            }
        }
        .task(id: issue.id) {
            logs = await supervisor.debugIssueLogs(id: issue.id, status: status)
            selectedLogFile = logs.keys.sorted().first
            snapshot = await supervisor.debugIssueSnapshot(id: issue.id, status: status)
            resolutionText = ""
        }
    }

    private var detailHeader: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.summary)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text("\(issue.trigger) · \(issue.severity)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let date = WorkshopIssuesView.parseISO(issue.createdAt) {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let resolution = issue.resolution, !resolution.isEmpty {
                        Text("Resolved: \(resolution)")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Button {
                Task {
                    if let folder = await supervisor.debugIssueFolder(id: issue.id, status: status) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                    }
                }
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var logsTab: some View {
        VStack(spacing: 0) {
            if logs.isEmpty {
                ContentUnavailableView("No Logs Captured", systemImage: "doc.text")
            } else {
                Picker("", selection: $selectedLogFile) {
                    ForEach(logs.keys.sorted(), id: \.self) { file in
                        Text(file.replacingOccurrences(of: "logs-", with: "").replacingOccurrences(of: ".txt", with: ""))
                            .tag(Optional(file))
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

                monospacedScroll(selectedLogFile.flatMap { logs[$0] } ?? "")
            }
        }
    }

    private var stateTab: some View {
        Group {
            if let snapshot {
                monospacedScroll(prettyJSON(snapshot))
            } else {
                ContentUnavailableView("No State Snapshot", systemImage: "camera")
            }
        }
    }

    private var infoTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                infoRow("ID", issue.id)
                infoRow("Status", issue.status)
                infoRow("Category", issue.category)
                infoRow("Trigger", issue.trigger)
                infoRow("Service", issue.serviceId ?? "—")
                infoRow("Error", issue.errorMessage)
                infoRow("Signature", issue.errorSignature)
                infoRow("Created", issue.createdAt)
                infoRow("Updated", issue.updatedAt)
                if let resolved = issue.resolvedAt {
                    infoRow("Resolved", resolved)
                }
                if let resolution = issue.resolution {
                    infoRow("Resolution", resolution)
                }
                if !issue.recurrenceTimestamps.isEmpty {
                    infoRow("Recurrences", issue.recurrenceTimestamps.joined(separator: "\n"))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var closeBar: some View {
        HStack(spacing: 8) {
            TextField("Resolution (e.g. Fixed in v0.11.0: ...)", text: $resolutionText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            Button {
                Task {
                    isClosing = true
                    let ok = await supervisor.closeDebugIssue(
                        id: issue.id,
                        resolution: resolutionText.isEmpty ? "Closed from Workshop" : resolutionText
                    )
                    isClosing = false
                    if ok { onClosed() }
                }
            } label: {
                if isClosing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Close Issue", systemImage: "checkmark.circle")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isClosing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func monospacedScroll(_ text: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .background(Color.black.opacity(0.2))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func prettyJSON(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8)
        else { return raw }
        return string
    }
}
