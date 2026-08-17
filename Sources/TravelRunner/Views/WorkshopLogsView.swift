import SwiftUI

struct WorkshopLogsView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor

    // Selection lives on the shared navigation object so header chips can
    // deep-link into a service's console.
    private var navigation: WorkshopNavigation { WorkshopPanel.shared.navigation }

    private var selectedServiceID: String? {
        navigation.selectedLogServiceID
    }

    var body: some View {
        VStack(spacing: 0) {
            serviceTabBar
            Divider()

            if let serviceID = selectedServiceID {
                ServiceConsoleView(serviceID: serviceID, logStore: supervisor.logStore)
            } else {
                ContentUnavailableView(
                    "Select a Service",
                    systemImage: "terminal",
                    description: Text("Choose a service above to view its terminal output")
                )
            }
        }
        .onAppear {
            if navigation.selectedLogServiceID == nil {
                navigation.selectedLogServiceID = supervisor.sortedServiceIDs.first
            }
        }
    }

    private var serviceTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(supervisor.sortedServiceIDs.enumerated()), id: \.element) { index, id in
                    let state = supervisor.serviceStates[id]
                    let name = state?.definition.displayName ?? id
                    let isSelected = selectedServiceID == id
                    let color = state?.phase.color ?? .gray
                    // A finished one-shot's console is historical output, not a
                    // live process — dim it so daemon tabs stand out.
                    let isQuietOneshot = state?.definition.resolvedType == .oneshot
                        && (state?.phase == .completed || state?.phase == .skipped)

                    Button {
                        navigation.selectedLogServiceID = id
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(color)
                                .frame(width: 6, height: 6)
                            Text(name)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(isSelected ? .bold : .regular)
                                .foregroundStyle(isQuietOneshot && !isSelected ? .secondary : .primary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? color.opacity(0.15) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.borderless)
                    .modifier(IndexedShortcut(index: index))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}

private struct IndexedShortcut: ViewModifier {
    let index: Int

    func body(content: Content) -> some View {
        if index < 9, let char = "\(index + 1)".first {
            content.keyboardShortcut(KeyEquivalent(char), modifiers: .command)
        } else {
            content
        }
    }
}
