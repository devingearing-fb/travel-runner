import SwiftUI

/// Health: every setup check with its Fix and Import… buttons, and where each
/// tool was found. These are the checks of the wizard's Environment Check; the
/// preflight of a start runs the fast ones.
struct WorkshopHealthView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let checker = supervisor.healthChecker {
                SetupStep2View(checker: checker, embedded: true, onBack: {}, onComplete: { _ in })
                    .frame(maxHeight: .infinity)
            } else {
                Text("Set up the repos in Settings first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(14)
                Spacer()
            }
            Divider()
            ScrollView {
                ToolsSection()
                    .padding(14)
            }
            .frame(maxHeight: 220)
        }
    }
}

/// The Status banner while setup checks fail: "2 setup items need attention — Open Health".
struct HealthAttentionBanner: View {
    let count: Int
    let onOpen: () -> Void

    var body: some View {
        // The whole banner opens Health.
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(CheckRegistry.attentionText(count: count))
                    .font(.caption)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
