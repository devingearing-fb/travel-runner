import SwiftUI

struct WorkshopView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @Bindable var navigation: WorkshopNavigation
    let toastCenter: ToastCenter
    @State private var showSetup = false

    private var isFirstRun: Bool {
        ConfigLoader.isFirstRun && supervisor.sortedServiceIDs.isEmpty
    }

    private var failedServiceCount: Int {
        supervisor.sortedServiceIDs
            .compactMap { supervisor.serviceStates[$0] }
            .filter { $0.phase == .failed || $0.isCircuitBroken }
            .count
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if showSetup || isFirstRun {
                    SetupView(isFirstRun: isFirstRun) {
                        showSetup = false
                        supervisor.loadConfig()
                    }
                } else {
                    WorkshopHeaderBar()

                    NavigationSplitView {
                        List(WorkshopSection.allCases, selection: $navigation.selectedSection) { section in
                            Label(section.rawValue, systemImage: section.icon)
                                .badge(section == .issues ? supervisor.debugOpenIssueCount : 0)
                        }
                        .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
                    } detail: {
                        switch navigation.selectedSection {
                        case .status:
                            WorkshopStatusView()
                        case .issues:
                            WorkshopIssuesView()
                        case .logs:
                            WorkshopLogsView()
                        case .dbTools:
                            WorkshopDbToolsView()
                        case .settings:
                            WorkshopSettingsView()
                        case .diagnostics:
                            WorkshopDiagnosticsView()
                        case nil:
                            WorkshopStatusView()
                        }
                    }

                    DashboardFooter(selectedServiceID: nil)
                }
            }

            ToastOverlay(center: toastCenter)
        }
        .preferredColorScheme(.dark)
        .onChange(of: failedServiceCount) { old, new in
            if new >= 2 {
                navigation.selectedSection = .status
            }
        }
        .onAppear {
            if failedServiceCount >= 2 {
                navigation.selectedSection = .status
            }
        }
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
