import AppKit
import SwiftUI

enum WorkshopSection: String, CaseIterable, Identifiable {
    case logs = "Terminals"
    case dbTools = "DB Tools"
    case settings = "Settings"
    case diagnostics = "Diagnostics"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .logs: "terminal"
        case .dbTools: "cylinder.split.1x2"
        case .settings: "gearshape"
        case .diagnostics: "stethoscope"
        }
    }
}

@Observable
@MainActor
final class WorkshopNavigation {
    var selectedSection: WorkshopSection = .logs
}

@MainActor
final class WorkshopPanel {
    static let shared = WorkshopPanel()

    private var panel: NSPanel?
    private var supervisor: EnvironmentSupervisor?
    let navigation = WorkshopNavigation()

    func configure(supervisor: EnvironmentSupervisor) {
        self.supervisor = supervisor
    }

    func open(section: WorkshopSection = .logs) {
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

        let workshopView = WorkshopView(navigation: navigation)
            .environment(supervisor)

        let hostingView = NSHostingView(rootView: workshopView)

        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.title = "Travel Runner — Workshop"
        newPanel.titlebarAppearsTransparent = false
        newPanel.isFloatingPanel = true
        newPanel.level = .floating
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.isMovableByWindowBackground = false
        newPanel.contentView = hostingView
        newPanel.isReleasedWhenClosed = false
        newPanel.minSize = NSSize(width: 680, height: 480)
        newPanel.maxSize = NSSize(width: 1400, height: 1000)

        self.panel = newPanel
    }
}
