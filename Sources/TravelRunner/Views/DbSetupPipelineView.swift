import SwiftUI

struct DbSetupPipelineView: View {
    let pipeline: DbSetupPipeline
    let isRunning: Bool
    let onRetryFrom: (String) -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void
    /// "Copy error + log" of a step.
    var onCopy: (DbSetupStep) -> Void = { _ in }
    /// The text of the fix button for an action, or nil for no button.
    var actionTitle: (RecoveryAction) -> String? = { _ in nil }
    var onAction: (RecoveryAction, DbSetupStep) -> Void = { _, _ in }
    /// "Report" on a failed step, with the step id.
    var onReport: ((String) -> Void)? = nil

    private var isActivelyRunning: Bool {
        isRunning || pipeline.isRunning
    }

    @State private var expandedStepID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            stepList
        }
        .onChange(of: pipeline.currentStep?.id) { _, newID in
            if let newID { expandedStepID = newID }
        }
        .onChange(of: pipeline.firstFailed?.id) { _, newID in
            if let newID { expandedStepID = newID }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            headerStatusIcon

            VStack(alignment: .leading, spacing: 2) {
                Text("Database Setup")
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
                Text("Scenario: \(pipeline.seedScenario.name)  •  Profile: \(pipeline.profile)"
                     + (pipeline.stepsSource.map { "  •  \($0)" } ?? ""))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let elapsed = pipeline.totalElapsed {
                Text(formatElapsed(elapsed))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(isActivelyRunning)
            .help(isActivelyRunning ? "Database setup cannot be dismissed while running" : "Dismiss database setup")
            .accessibilityLabel("Dismiss database setup")
            .accessibilityHint(
                isActivelyRunning
                    ? "Unavailable while database setup is running"
                    : "Removes the completed setup pipeline from view"
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var headerStatusIcon: some View {
        if isActivelyRunning {
            ProgressView()
                .controlSize(.small)
        } else if pipeline.allRequiredPassed {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if pipeline.firstFailed != nil {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else if pipeline.firstCancelled != nil {
            Image(systemName: "stop.circle")
                .foregroundStyle(.secondary)
        } else {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            if isActivelyRunning {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
            } else if let failed = pipeline.firstFailed {
                Button("Retry from \(failed.name)") {
                    onRetryFrom(failed.id)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Run All") {
                    onRetryFrom(pipeline.steps.first?.id ?? "")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if !pipeline.allRequiredPassed && !pipeline.steps.isEmpty {
                Button("Run All") {
                    onRetryFrom(pipeline.steps.first?.id ?? "")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                if pipeline.firstCancelled != nil {
                    Text(DbSetupPipeline.cancelledMessage)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Step List

    private var stepList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(pipeline.steps) { step in
                    DbSetupStepRow(
                        step: step,
                        isExpanded: expandedStepID == step.id,
                        onToggleExpand: {
                            expandedStepID = expandedStepID == step.id ? nil : step.id
                        },
                        onRetry: { onRetryFrom(step.id) },
                        onCopy: { onCopy(step) },
                        actionTitle: actionTitle,
                        onAction: { onAction($0, step) },
                        onReport: onReport.map { report in { report(step.id) } }
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Formatting

    private func formatElapsed(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}

// MARK: - Step Row

struct DbSetupStepRow: View {
    let step: DbSetupStep
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onRetry: () -> Void
    var onCopy: () -> Void = {}
    var actionTitle: (RecoveryAction) -> String? = { _ in nil }
    var onAction: (RecoveryAction) -> Void = { _ in }
    var onReport: (() -> Void)? = nil

    /// The height of the log pane. The person can drag its bottom edge.
    @State private var logHeight: CGFloat = DbSetupStepRow.logPaneHeight
    @State private var dragStartHeight: CGFloat?

    /// The log pane of a step (plan 4.0, item 17): 220 pt, resizable.
    static let logPaneHeight: CGFloat = 220
    static let logPaneHeightRange: ClosedRange<CGFloat> = 100...800

    private var hasFailed: Bool {
        step.status == .failed || step.status == .timedOut
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            mainRow
            detailRow
            progressRow
            errorRow

            if isExpanded && !step.logEntries.isEmpty {
                VStack(spacing: 0) {
                    stepLogView
                        .frame(height: logHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    resizeHandle
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundFill)
        }
    }

    // MARK: - Main Row

    private var mainRow: some View {
        HStack(spacing: 6) {
            stepNumberCircle
            statusIcon
            Text(step.name)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)

            if step.isOptional {
                Text("OPTIONAL")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.12))
                    }
            }

            if step.status == .passed, let health = step.healthResult, !health.isEmpty {
                Text(health)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.green.opacity(0.1))
                    }
            }

            Spacer()

            elapsedLabel

            if step.status == .failed || step.status == .timedOut || step.status == .cancelled {
                Button("Retry") { onRetry() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.orange)
                if let onReport {
                    Button("Report") { onReport() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help("Save a report zip to Downloads and copy a summary for Slack")
                }
            }

            Button {
                onToggleExpand()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "terminal")
                    .font(.caption2)
                    .foregroundStyle(isExpanded ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
            .help(isExpanded ? "Hide logs" : "Show logs")
        }
    }

    // MARK: - Step Number Circle

    private var stepNumberCircle: some View {
        ZStack {
            Circle()
                .fill(step.status.color.opacity(0.15))
                .frame(width: 18, height: 18)
            Text("\(step.stepNumber)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(step.status.color)
        }
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .pending:
            Image(systemName: "circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .healthCheck:
            ProgressView()
                .controlSize(.mini)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        case .skipped:
            Image(systemName: "arrow.right.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .timedOut:
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "stop.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Detail Row

    @ViewBuilder
    private var detailRow: some View {
        if step.status == .running || step.status == .healthCheck {
            HStack(spacing: 4) {
                Spacer().frame(width: 24)
                if step.status == .healthCheck {
                    Text("Verifying...")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.blue)
                } else if let label = step.progressLabel {
                    Text(label)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    // MARK: - Progress Row

    @ViewBuilder
    private var progressRow: some View {
        if step.status == .running, let progress = step.progress {
            HStack(spacing: 6) {
                Spacer().frame(width: 24)
                ProgressView(value: DbSetupStep.barValue(progress), total: 1)
                    .tint(.blue)
                Text(DbSetupStep.percentLabel(progress))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    // MARK: - Elapsed

    /// The time of the step against its hard cap ("1m 05s / 15m"). It counts while
    /// the step runs.
    @ViewBuilder
    private var elapsedLabel: some View {
        if step.startedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let seconds = Int(step.elapsed ?? 0)
                Text(DbSetupDiagnostics.elapsedLabel(seconds: seconds, capSeconds: step.hardCapSeconds))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Time of the step, and the longest it may run")
            }
        }
    }

    // MARK: - Error Row

    @ViewBuilder
    private var errorRow: some View {
        if let error = step.errorMessage {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    Spacer().frame(width: 24)
                    Text(error)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let guidance = step.recoveryGuidance {
                    HStack(alignment: .top, spacing: 4) {
                        Spacer().frame(width: 24)
                        Text(guidance)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if hasFailed {
                    HStack(spacing: 6) {
                        Spacer().frame(width: 24)
                        if let action = step.recoveryAction, let title = actionTitle(action) {
                            Button(title) { onAction(action) }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                        }
                        Button("Copy error + log") { onCopy() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .help("Copy the error, what to do and the whole log, with secrets removed")
                        if !step.logEntries.isEmpty, let title = actionTitle(.openLog) {
                            Button(title) { onAction(.openLog) }
                                .buttonStyle(.borderless)
                                .controlSize(.mini)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Resize Handle

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartHeight ?? logHeight
                        dragStartHeight = start
                        let range = Self.logPaneHeightRange
                        logHeight = min(max(start + value.translation.height, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .help("Drag to resize the log")
    }

    // MARK: - Log View

    private var stepLogView: some View {
        TerminalTextView(
            entries: step.logEntries,
            autoScroll: true,
            format: { entry in
                let text = entry.text
                let lower = text.lowercased()
                let color: NSColor = if lower.contains("error") || lower.contains("fail") {
                    .systemRed
                } else if text.contains("\u{2713}") || lower.contains("done") || lower.contains("success") {
                    .systemGreen
                } else if lower.contains("warn") {
                    .systemOrange
                } else {
                    .white
                }
                return (text, color)
            }
        )
    }

    // MARK: - Helpers

    private var backgroundFill: Color {
        switch step.status {
        case .running, .healthCheck: Color.blue.opacity(0.06)
        case .failed, .timedOut: Color.red.opacity(0.04)
        case .passed: Color.green.opacity(0.03)
        default: Color.clear
        }
    }
}
