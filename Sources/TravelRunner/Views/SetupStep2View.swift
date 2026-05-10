import SwiftUI

struct SetupStep2View: View {
    let checker: EnvironmentChecker
    let onBack: () -> Void
    let onComplete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "checkmark.shield")
                    .font(.title2)
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Environment Check")
                        .font(.headline)
                    Text("Verifying everything needed for local development")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)

            Divider()

            // Summary bar
            summaryBar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(CheckSection.allCases, id: \.rawValue) { section in
                        let sectionChecks = checker.checks.filter { $0.section == section }
                        if !sectionChecks.isEmpty {
                            sectionView(title: section.rawValue, checks: sectionChecks)
                        }
                    }
                }
                .padding(14)
            }

            Divider()

            // Footer
            HStack {
                Button("Back") { onBack() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                Spacer()
                Button(action: onComplete) {
                    Label("Save & Start", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!checker.allRequiredPassing)
                .controlSize(.regular)
            }
            .padding(14)
        }
        .task {
            checker.buildChecks()
            await checker.runAllChecks()
        }
    }

    // MARK: - Summary Bar

    private var summaryBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await checker.runAllChecks() }
            } label: {
                Label("Re-check All", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            let total = checker.checks.count
            let passed = checker.checks.filter { if case .passing = $0.status { return true }; return false }.count
            let failed = checker.checks.filter { if case .failing = $0.status { return true }; return false }.count
            let warned = checker.checks.filter { if case .warning = $0.status { return true }; return false }.count
            let pending = checker.checks.filter { if case .pending = $0.status { return true }; return false }.count

            if pending > 0 {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Checking...").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 10) {
                    if passed > 0 {
                        Label("\(passed)", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                    if failed > 0 {
                        Label("\(failed)", systemImage: "xmark.circle.fill")
                            .font(.caption).foregroundStyle(.red)
                    }
                    if warned > 0 {
                        Label("\(warned)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("\(passed)/\(total)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.03))
    }

    // MARK: - Section

    private func sectionView(title: String, checks: [HealthCheck]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 1)
            }

            ForEach(checks) { check in
                checkRow(check)
            }
        }
    }

    // MARK: - Check Row (verbose)

    private func checkRow(_ check: HealthCheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top line: icon + name + status badge + fix button
            HStack(spacing: 8) {
                statusIcon(check.status)
                    .frame(width: 18)

                Text(check.name)
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)

                if !check.isRequired {
                    Text("OPTIONAL")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }

                Spacer()

                // Status result text
                statusBadge(check.status)

                // Fix button
                if let fixLabel = check.fixLabel, shouldShowFix(check.status) {
                    Button(fixLabel) {
                        Task { await checker.fix(check.id) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.blue)
                }
            }

            // Description line
            Text(check.checkDescription)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 26)

            // Command line (shows what's being checked)
            HStack(spacing: 4) {
                Text("$")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(check.checkCommand)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 26)

            // Path being checked (if applicable)
            if let path = check.checkPath {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(abbreviatePath(path))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.leading, 26)
            }

            // Result detail
            switch check.status {
            case .passing(let detail):
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right").font(.system(size: 8))
                    Text(detail)
                }
                .font(.caption2)
                .foregroundStyle(.green.opacity(0.8))
                .padding(.leading, 26)

            case .failing(let detail):
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right").font(.system(size: 8))
                    Text(detail)
                }
                .font(.caption2)
                .foregroundStyle(.red.opacity(0.9))
                .padding(.leading, 26)

            case .warning(let detail):
                HStack(spacing: 4) {
                    Image(systemName: "arrow.right").font(.system(size: 8))
                    Text(detail)
                }
                .font(.caption2)
                .foregroundStyle(.orange.opacity(0.9))
                .padding(.leading, 26)

            default:
                EmptyView()
            }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(checkBackground(check.status))
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusIcon(_ status: CheckStatus) -> some View {
        switch status {
        case .pending:
            ProgressView().controlSize(.small)
        case .passing:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failing:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fixing:
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: CheckStatus) -> some View {
        switch status {
        case .passing(let d):
            Text(d)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        case .failing:
            Text("FAIL")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        case .warning:
            Text("WARN")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        case .fixing:
            Text("FIXING...")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.blue)
        case .pending:
            Text("...")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func shouldShowFix(_ status: CheckStatus) -> Bool {
        switch status {
        case .failing, .warning: true
        default: false
        }
    }

    private func checkBackground(_ status: CheckStatus) -> Color {
        switch status {
        case .failing: Color.red.opacity(0.04)
        case .warning: Color.orange.opacity(0.03)
        case .passing: Color.green.opacity(0.02)
        default: Color.clear
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
