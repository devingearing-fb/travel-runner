import AppKit
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var toolbar: NSToolbar? {
        get { nil }
        set { }
    }
}

enum WorkshopSection: String, CaseIterable, Identifiable {
    case status = "Status"
    case health = "Health"
    case issues = "Issues"
    case logs = "Terminals"
    case rooms = "Rooms"
    case dbTools = "DB Tools"
    case settings = "Settings"
    case diagnostics = "Diagnostics"

    var id: Self { self }

    /// The sections this app shows. The Rooms tab needs the monolith's holds viewer.
    static func visible(in flavor: Flavor = .current) -> [WorkshopSection] {
        allCases.filter { $0 != .rooms || flavor.hasRoomsTab }
    }

    var icon: String {
        switch self {
        case .status: "heart.text.clipboard"
        case .health: "checkmark.shield"
        case .issues: "ant"
        case .logs: "terminal"
        case .rooms: "bed.double"
        case .dbTools: "cylinder.split.1x2"
        case .settings: "gearshape"
        case .diagnostics: "stethoscope"
        }
    }
}

@Observable
@MainActor
final class WorkshopNavigation {
    var selectedSection: WorkshopSection? = .status
    var selectedLogServiceID: String? = nil
}

@MainActor
final class WorkshopPanel {
    static let shared = WorkshopPanel()

    private var panel: KeyablePanel?
    private var supervisor: EnvironmentSupervisor?
    private var updateController: UpdateController?
    private var panelDelegate: PanelDelegate?
    let navigation = WorkshopNavigation()
    let toastCenter = ToastCenter()

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Visible or in the Dock: somebody may come back to work in it.
    var isOpen: Bool {
        guard let panel else { return false }
        return panel.isVisible || panel.isMiniaturized
    }

    func configure(supervisor: EnvironmentSupervisor, updateController: UpdateController? = nil) {
        self.supervisor = supervisor
        self.updateController = updateController
        supervisor.onFeedback = { [weak toastCenter] feedback in
            toastCenter?.show(feedback)
        }
        // An error toast opens Status, where the failed service has its triage card.
        toastCenter.onOpen = { [weak self] _ in self?.open(section: .status) }
        // Health lists the setup checks and where each tool was found.
        supervisor.onOpenHealth = { [weak self] in self?.open(section: .health) }
    }

    func open(section: WorkshopSection = .status) {
        navigation.selectedSection = section
        if let panel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        createPanelIfNeeded()
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func createPanelIfNeeded() {
        guard let supervisor else { return }
        if panel != nil { return }

        let workshopView = WorkshopView(navigation: navigation, toastCenter: toastCenter)
            .environment(supervisor)
            .environment(updateController)

        let hostingView = NSHostingView(rootView: workshopView)

        let delegate = PanelDelegate()
        delegate.supervisor = supervisor
        self.panelDelegate = delegate

        let newPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newPanel.title = Flavor.current.displayName
        newPanel.titlebarAppearsTransparent = false
        newPanel.isFloatingPanel = false
        newPanel.level = .normal
        newPanel.hidesOnDeactivate = false
        newPanel.becomesKeyOnlyIfNeeded = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isMovableByWindowBackground = false
        newPanel.contentView = hostingView
        newPanel.isReleasedWhenClosed = false
        newPanel.minSize = NSSize(width: 700, height: 500)
        newPanel.maxSize = NSSize(width: 1400, height: 1000)
        newPanel.delegate = delegate

        self.panel = newPanel
    }
}

private final class PanelDelegate: NSObject, NSWindowDelegate {
    weak var supervisor: EnvironmentSupervisor?

    func windowDidBecomeKey(_ notification: Notification) {
        Task { @MainActor in
            supervisor?.panelVisible = true
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            supervisor?.panelVisible = false
        }
    }
}
