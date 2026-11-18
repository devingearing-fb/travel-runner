import SwiftUI

/// One start check: its state, its name, and for a warning or a failure the
/// reason and the fix. Status and Diagnostics show the same row.
struct PreflightCheckRow: View {
    let check: PreflightCheck

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                switch check.result {
                case .pending:
                    ProgressView().controlSize(.small)
                case .passed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .warning:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .failed:
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(check.name)
                    .font(.caption)
                if case .warning(let message) = check.result {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .failed(let message, let fix) = check.result {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let fix {
                        Text("Fix: \(fix)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer()

            if case .passed(let detail) = check.result {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background {
            if case .failed = check.result {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.red.opacity(0.08))
            }
        }
    }
}
