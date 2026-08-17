import SwiftUI

struct PhaseSection: View {
    let phase: String
    let services: [ServiceState]
    let logStore: LogStore
    let onRestart: (String) -> Void
    let onCascadeRestart: ((String) -> Void)?
    let onPublishRetry: (() -> Void)?
    var dbResetRunning: Bool = false
    var isServiceStale: ((String) -> Bool)? = nil
    var serviceBehindCount: ((String) -> Int)? = nil
    var isServiceDepsStale: ((String) -> Bool)? = nil

    @State private var isExpanded = true

    private var healthyCount: Int {
        services.filter { $0.phase == .running || $0.phase == .completed || $0.phase == .skipped }.count
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(services) { state in
                    ServiceRow(
                        state: state,
                        logStore: logStore,
                        onRestart: { onRestart(state.id) },
                        onPublishRetry: state.id == "yalc-link" ? onPublishRetry : nil,
                        onCascadeRestart: onCascadeRestart.map { callback in { callback(state.id) } },
                        isStale: isServiceStale?(state.id) ?? false,
                        behindCount: serviceBehindCount?(state.id) ?? 0,
                        depsStale: isServiceDepsStale?(state.id) ?? false
                    )
                }
            }
            .padding(.top, 2)
        } label: {
            HStack(spacing: 4) {
                Text(phase)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Text("\(healthyCount)/\(services.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)

                Rectangle()
                    .fill(Color.secondary.opacity(0.12))
                    .frame(height: 0.5)
            }
        }
        .padding(.top, 4)
    }
}
