import SwiftUI

struct WorkshopLogsView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @State private var selectedServiceID: String?

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
            if selectedServiceID == nil {
                selectedServiceID = supervisor.sortedServiceIDs.first
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

                    Button {
                        selectedServiceID = id
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(color)
                                .frame(width: 6, height: 6)
                            Text(name)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(isSelected ? .bold : .regular)
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
