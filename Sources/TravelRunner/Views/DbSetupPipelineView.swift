import SwiftUI

struct DbSetupPipelineView: View {
    let pipeline: DbSetupPipeline
    let isRunning: Bool
    let onRetryFrom: (String) -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void

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
        HStack(spacing: 8) {
            headerStatusIcon
            Text("Database Setup")
                .font(.system(.callout, design: .monospaced))
                .fontWeight(.medium)
            Spacer()
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
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var headerStatusIcon: some View {
        if isRunning {
            ProgressView()
                .controlSize(.small)
        } else if pipeline.allRequiredPassed {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if pipeline.firstFailed != nil {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        } else {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 8) {
            if isRunning {
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
                        onRetry: { onRetryFrom(step.id) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            mainRow
            detailRow
            progressRow
            errorRow

            if isExpanded && !step.logEntries.isEmpty {
                stepLogView
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
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
                .lineLimit(1)

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

            if let elapsed = step.elapsed, step.completedAt != nil {
                Text(formatStepElapsed(elapsed))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if step.status == .failed || step.status == .timedOut {
                Button("Retry") { onRetry() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.orange)
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
                ProgressView(value: min(max(progress, 0), 100), total: 100)
                    .tint(.blue)
                Text("\(Int(progress))%")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    // MARK: - Error Row

    @ViewBuilder
    private var errorRow: some View {
        if let error = step.errorMessage {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Spacer().frame(width: 24)
                    Text(error)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
                if let guidance = step.recoveryGuidance {
                    HStack(spacing: 4) {
                        Spacer().frame(width: 24)
                        Text(guidance)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
            }
        }
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

    private func formatStepElapsed(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}
