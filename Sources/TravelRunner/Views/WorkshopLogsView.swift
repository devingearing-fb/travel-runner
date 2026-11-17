import SwiftUI

struct WorkshopLogsView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor

    // Selection lives on the shared navigation object so header chips can
    // deep-link into a service's console.
    private var navigation: WorkshopNavigation { WorkshopPanel.shared.navigation }

    private var selectedServiceID: String? {
        navigation.selectedLogServiceID
    }

    /// The `db-setup-<step>` buffers in the log store, read again after each setup.
    @State private var storedDbStepKeys: [String] = []

    /// One tab for each DB step with output: the steps of the pipeline on screen, in
    /// order, then any older step log the store still holds.
    private var dbSetupTabs: [DbSetupTab] {
        var tabs: [DbSetupTab] = []
        var seen = Set<String>()
        for step in supervisor.dbSetupPipeline?.steps ?? [] where step.status != .pending || storedDbStepKeys.contains(step.logKey) {
            tabs.append(DbSetupTab(key: step.logKey, name: step.name, color: step.status.color))
            seen.insert(step.logKey)
        }
        for key in storedDbStepKeys.sorted() where !seen.contains(key) {
            tabs.append(DbSetupTab(key: key, name: String(key.dropFirst(DbSetupTab.prefix.count)), color: .secondary))
        }
        return tabs
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
        .task(id: supervisor.dbResetRunning) {
            storedDbStepKeys = await supervisor.logStore.serviceIDs().filter { $0.hasPrefix(DbSetupTab.prefix) }
        }
    }

    private var serviceTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(supervisor.sortedServiceIDs.enumerated()), id: \.element) { index, id in
                    let state = supervisor.serviceStates[id]
                    // A finished one-shot's console is historical output, not a
                    // live process — dim it so daemon tabs stand out.
                    let isQuietOneshot = state?.definition.resolvedType == .oneshot
                        && (state?.phase == .completed || state?.phase == .skipped)
                    tabButton(
                        id: id, name: state?.definition.displayName ?? id,
                        color: state?.phase.color ?? .gray, dimmed: isQuietOneshot
                    )
                    .modifier(IndexedShortcut(index: index))
                }

                let dbTabs = dbSetupTabs
                if !dbTabs.isEmpty {
                    Divider()
                        .frame(height: 16)
                        .padding(.horizontal, 4)
                    Text("DB SETUP")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 2)
                    ForEach(dbTabs) { tab in
                        tabButton(id: tab.key, name: tab.name, color: tab.color, dimmed: true)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    private func tabButton(id: String, name: String, color: Color, dimmed: Bool) -> some View {
        let isSelected = selectedServiceID == id
        return Button {
            navigation.selectedLogServiceID = id
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(name)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundStyle(dimmed && !isSelected ? .secondary : .primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? color.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
    }
}

/// A tab of the "DB setup" group: the log of one DB step.
private struct DbSetupTab: Identifiable {
    static let prefix = DbSetupStep.logKeyPrefix
    let key: String
    let name: String
    let color: Color
    var id: String { key }
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
