import SwiftUI

struct WorkshopView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @Bindable var navigation: WorkshopNavigation

    var body: some View {
        NavigationSplitView {
            List(WorkshopSection.allCases, selection: $navigation.selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
        } detail: {
            switch navigation.selectedSection {
            case .logs:
                WorkshopLogsView()
            case .dbTools:
                WorkshopDbToolsView()
            case .settings:
                WorkshopSettingsView()
            case .diagnostics:
                WorkshopDiagnosticsView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct WorkshopSettingsView: View {
    @State private var showSetup = false

    var body: some View {
        if showSetup {
            SetupView(isFirstRun: false) {
                showSetup = false
            }
        } else {
            SettingsPageView(
                onDismiss: {},
                onReconfigureRepos: { showSetup = true }
            )
        }
    }
}
