import SwiftUI

struct WorkshopView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @Bindable var navigation: WorkshopNavigation
    let toastCenter: ToastCenter
    @State private var showSetup = false

    private var isFirstRun: Bool {
        (supervisor.sortedServiceIDs.isEmpty && ConfigLoader.needsSetup) || !SetupState.live.completed
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
                    SetupView(isFirstRun: isFirstRun) { outcome in
                        showSetup = false
                        guard case .saved(let start) = outcome else { return }
                        supervisor.loadConfig()
                        if start { supervisor.startAll() }
                    }
                } else {
                    WorkshopHeaderBar()

                    NavigationSplitView {
                        List(WorkshopSection.visible(), selection: $navigation.selectedSection) { section in
                            Label(section.rawValue, systemImage: section.icon)
                                .badge(section == .issues ? supervisor.debugOpenIssueCount
                                       : section == .status ? failedServiceCount
                                       : section == .health ? supervisor.setupItemsNeedingAttention.count : 0)
                        }
                        .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
                    } detail: {
                        switch navigation.selectedSection {
                        case .status:
                            WorkshopStatusView()
                        case .health:
                            WorkshopHealthView()
                        case .issues:
                            WorkshopIssuesView()
                        case .logs:
                            WorkshopLogsView()
                        case .rooms:
                            WorkshopRoomsView()
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
                    .toolbar(removing: .sidebarToggle)

                    DashboardFooter(selectedServiceID: nil)
                }
            }

            ToastOverlay(center: toastCenter)
        }
        .preferredColorScheme(.dark)
        // One confirmation for every reset button: DB Tools and the banners.
        .confirmationDialog(
            DbResetPolicy.resetConfirmationTitle,
            isPresented: Binding(
                get: { supervisor.resetConfirmation != nil },
                set: { if !$0 { supervisor.cancelResetConfirmation() } }
            ),
            titleVisibility: .visible,
            presenting: supervisor.resetConfirmation
        ) { request in
            Button(DbResetPolicy.resetAndReseedTitle, role: .destructive) { supervisor.resetDatabase() }
            if request.offersWithoutHotels {
                Button(HotelCatalog.resetWithoutHotelsTitle, role: .destructive) { supervisor.resetWithoutHotels() }
            }
            Button("Cancel", role: .cancel) { supervisor.cancelResetConfirmation() }
        } message: { request in
            Text(request.message)
        }
    }
}

struct WorkshopSettingsView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @State private var showSetup = false
    @State private var askStop = false

    var body: some View {
        Group {
            if showSetup {
                SetupView(isFirstRun: false) { outcome in
                    showSetup = false
                    if case .saved = outcome { applySavedPaths() }
                }
            } else {
                SettingsPageView(
                    onDismiss: {},
                    onReconfigureRepos: { showSetup = true }
                )
            }
        }
        .alert("Stop the stack and apply the new paths?", isPresented: $askStop) {
            Button("Stop and apply") { supervisor.stopAndReconfigure() }
            Button("Apply at next launch", role: .cancel) {}
        } message: {
            Text("The stack runs from the old paths. The new paths are saved.")
        }
    }

    /// The supervisor loads the saved paths now, or says that the stack must stop first.
    private func applySavedPaths() {
        Task {
            if await supervisor.reconfigure() == .needsStop { askStop = true }
        }
    }
}
