import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var supervisor: EnvironmentSupervisor!
    private var iconTimer: Timer?
    private var rightClickMonitor: Any?
    private var globalHotkeyMonitor: Any?
    private var localHotkeyMonitor: Any?
    private var lastIconHealth: HealthStatus?
    private var pulseState: Bool = false
    private var updateController: UpdateController!
    /// Another copy of the app ran first. This copy only says so and quits: it has no
    /// supervisor, and it must not touch the env, the processes or the ports of the other.
    private var yieldsToRunningCopy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        // Before the supervisor: it would take the control port and write the config.
        var running = InstanceGuard.runningCopyNow()
        // A copy that quits still stops its stack. Wait for it to end; then this
        // launch is the only copy. Before, it said "already running" about a copy
        // that was gone a moment later.
        for _ in 0..<3 {
            guard let copy = running?.copy,
                  InstanceGuard.isQuitting(copy, marker: InstanceGuard.readQuittingMarker()),
                  InstanceGuard.waitForExit(pid: copy.pid) else { break }
            running = InstanceGuard.runningCopyNow()
        }
        if let running {
            yieldsToRunningCopy = true
            if InstanceGuard.skipsAlert() {
                FileHandle.standardError.write(Data((InstanceGuard.message(for: running.copy) + "\n").utf8))
                exit(InstanceGuard.smokeExitCode)
            }
            InstanceGuard.refuse(running) { NSApplication.shared.terminate(nil) }
            return
        }

        InstanceGuard.clearQuittingMarker()

        // Read the PATH of the user's shell first. A command that starts while
        // this runs waits for it.
        ToolEnvironment.shared.beginResolve(runner: LoginShell())

        supervisor = EnvironmentSupervisor(logSink: .live())
        supervisor.misplacedCopyNotice = InstanceGuard.misplacedNotice(
            bundlePath: Bundle.main.bundlePath,
            build: .current,
            defaults: .standard
        )
        supervisor.loadConfig()

        supervisor.onServiceCrash = { [weak self] serviceName, exitCode in
            self?.postCrashNotification(serviceName: serviceName, exitCode: exitCode)
        }

        updateController = UpdateController()
        let supervisor = self.supervisor!
        updateController.restartState = {
            await supervisor.updateRestartState(panelOpen: WorkshopPanel.shared.isOpen)
        }
        updateController.restartStateNow = {
            supervisor.updateRestartStateNow(panelOpen: WorkshopPanel.shared.isOpen)
        }

        WorkshopPanel.shared.configure(supervisor: supervisor, updateController: updateController)

        // A smoke launch has nobody to answer a permission prompt.
        if !LaunchEnvironment.isSmoke() { setupNotifications() }
        setupStatusItem()
        setupGlobalHotkey()

        // `open -a … --args --open-panel` shows the window at once (scripts, screenshots).
        // Without a usable config, or when the wizard never completed, show the wizard.
        // A smoke launch shows no window by itself.
        let opensWizard = SetupState.opensWizard(needsSetup: ConfigLoader.needsSetup, completed: SetupState.live.completed)
        if CommandLine.arguments.contains("--open-panel") || (opensWizard && !LaunchEnvironment.isSmoke()) {
            openPanel()
        }
    }

    /// A second launch from Finder or Spotlight shows the window. The app has no Dock icon.
    /// A window that is already open keeps its section.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !yieldsToRunningCopy else { return false }
        let panel = WorkshopPanel.shared
        if panel.isVisible {
            panel.open(section: panel.navigation.selectedSection ?? .status)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openPanel()
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !yieldsToRunningCopy else { return }
        // The stop below takes some seconds. A launch in that time waits for this copy.
        InstanceGuard.markQuitting()
        if let monitor = rightClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalHotkeyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localHotkeyMonitor { NSEvent.removeMonitor(monitor) }
        iconTimer?.invalidate()
        // While the other runner app runs a stack, the login's env and the ports are its.
        // An idle restart for an update leaves them alone too: see `quitCleanup`.
        let siblingRunsStack = !SiblingRunner.activeServicesNow().isEmpty
        let cleanup = UpdatePolicy.quitCleanup(
            unattendedUpdate: updateController?.quitsForUnattendedUpdate == true,
            siblingRunsStack: siblingRunsStack
        )
        if cleanup.resetsEnv { supervisor.resetEnvToLocalhost() }

        // Phase 1: Collect the full process tree BEFORE sending signals.
        // Killing a parent reparents its children to launchd.
        var allPids: [pid_t] = []
        for (_, state) in supervisor.serviceStates {
            if let pid = state.pid { allPids += ProcessTree.tree(of: pid) }
        }

        // The holds viewer of the Rooms tab is not a service, so it is not in the loop above.
        if let pid = supervisor.holdsViewer.pid { allPids += ProcessTree.tree(of: pid) }

        // A DB step that runs (a reset, a hotel load) is not a service either.
        if let pid = supervisor.dbStepProcessID { allPids += ProcessTree.tree(of: pid) }

        // Phase 2 and 3: SIGTERM, then SIGKILL to what is still alive after a second.
        ProcessTree.terminateNow(Array(Set(allPids)))

        // Phase 4: Kill by service port as a fallback. Only the ports that Stop All
        // clears: the services of the profile and those this session started, never a
        // reuse_if_running service (Supabase persists between sessions).
        defer { supervisor.markCleanExit() }
        guard cleanup.sweepsPorts else { return }
        killProcessesOnPorts(supervisor.sweepPorts)
    }

    /// A container runtime is never killed: its port helper serves every container.
    private func killProcessesOnPorts(_ ports: [Int]) {
        for port in ports {
            for listener in PortOwner.killable(PortOwner.listenersNow(on: port)) {
                kill(listener.pid, SIGKILL)
            }
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.action = #selector(togglePanel)
            button.target = self
        }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self,
                  let button = self.statusItem.button,
                  let buttonWindow = button.window,
                  event.window == buttonWindow else {
                return event
            }
            let pointInButton = button.convert(event.locationInWindow, from: nil)
            guard button.bounds.contains(pointInButton) else { return event }
            DispatchQueue.main.async {
                self.showStatusMenu()
            }
            return nil
        }

        updateStatusIcon()
        startIconTimer()
    }

    private func startIconTimer() {
        iconTimer?.invalidate()
        let interval: TimeInterval = supervisor.health == .starting ? 0.5 : 2.0
        iconTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusIcon()
            }
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        // Each item sets its own enabled state; AppKit would enable every item with an action.
        menu.autoenablesItems = false

        for serviceID in supervisor.sortedServiceIDs {
            guard let state = supervisor.serviceStates[serviceID] else { continue }
            let indicator: String = switch state.phase {
            case .running, .completed: "\u{2705}"
            case .skipped: "\u{23ED}\u{FE0F}"
            case .failed: "\u{274C}"
            case .starting: "\u{1F7E0}"
            case .stopping: "\u{1F7E1}"
            default: "\u{26AA}"
            }
            let item = NSMenuItem(
                title: "\(indicator)  \(state.definition.displayName): \(state.phase.rawValue)",
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.addItem(item)
        }

        if supervisor.debugTrackingEnabled && supervisor.debugOpenIssueCount > 0 {
            menu.addItem(.separator())
            let debugItem = NSMenuItem(
                title: "\u{1F41C} \(supervisor.debugOpenIssueCount) open debug issue\(supervisor.debugOpenIssueCount == 1 ? "" : "s")",
                action: #selector(openIssues),
                keyEquivalent: ""
            )
            debugItem.target = self
            menu.addItem(debugItem)
        }

        menu.addItem(.separator())

        let openItem = NSMenuItem(title: "Open \(Flavor.current.displayName)", action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let terminalsItem = NSMenuItem(title: "Open Terminals", action: #selector(openTerminals), keyEquivalent: "")
        terminalsItem.target = self
        menu.addItem(terminalsItem)

        let reportItem = NSMenuItem(title: "Report a Problem…", action: #selector(reportProblem), keyEquivalent: "")
        reportItem.target = self
        reportItem.isEnabled = !supervisor.reportExportRunning
        menu.addItem(reportItem)

        let buildItem = NSMenuItem(title: BuildInfo.current.menuTitle, action: nil, keyEquivalent: "")
        buildItem.isEnabled = false
        menu.addItem(buildItem)

        if let pending = updateController.pending {
            // The panel has the pill, with the restart question.
            let pendingItem = NSMenuItem(title: UpdatePolicy.pillText(pending), action: #selector(openPanel), keyEquivalent: "")
            pendingItem.target = self
            menu.addItem(pendingItem)
        }

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = updateController.canCheckForUpdates
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit \(Flavor.current.displayName)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanel() {
        WorkshopPanel.shared.open()
        NSApp.activate(ignoringOtherApps: true)
        supervisor.panelVisible = true
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func checkForUpdates() {
        updateController.checkForUpdates()
    }

    @objc private func openTerminals() {
        WorkshopPanel.shared.open(section: .logs)
        NSApp.activate(ignoringOtherApps: true)
        supervisor.panelVisible = true
    }

    /// Opens the panel first, so the sheet and the toast have a window.
    @objc private func reportProblem() {
        openPanel()
        ReportProblem.run(supervisor: supervisor)
    }

    @objc private func openIssues() {
        WorkshopPanel.shared.open(section: .issues)
        NSApp.activate(ignoringOtherApps: true)
        supervisor.panelVisible = true
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let currentHealth = supervisor.health

        if currentHealth == .starting {
            pulseState.toggle()
        } else {
            pulseState = false
        }

        // The tooltip says why, so a hover answers "why is it red?".
        let summary = supervisor.healthSummary
        let label = summary.status == currentHealth ? summary.label : HealthSummary(status: currentHealth).label
        let tooltip = ["\(Flavor.current.displayName): \(label)", summary.status == currentHealth ? summary.reason : nil]
            .compactMap { $0 }.joined(separator: "\n")
        if button.toolTip != tooltip { button.toolTip = tooltip }

        if currentHealth == lastIconHealth && currentHealth != .starting { return }
        lastIconHealth = currentHealth

        let color: NSColor = switch currentHealth {
        case .stopped: .systemGray
        case .starting: .systemOrange
        case .healthy: .systemGreen
        case .degraded: .systemRed
        }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(.init(paletteColors: [color]))
        if let symbol = NSImage(systemSymbolName: Flavor.current.menuBarSymbol, accessibilityDescription: Flavor.current.displayName)?
            .withSymbolConfiguration(symbolConfig) {
            symbol.isTemplate = false
            button.image = symbol
        }

        button.alphaValue = (currentHealth == .starting && pulseState) ? 0.4 : 1.0

        let desiredInterval: TimeInterval = currentHealth == .starting ? 0.5 : 2.0
        if abs((iconTimer?.timeInterval ?? 0) - desiredInterval) > 0.1 {
            startIconTimer()
        }
    }

    // MARK: - Notifications

    /// The notification centre aborts the process when the binary has no app bundle
    /// (`swift run`, or the bare executable). Such a run has no notifications.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func setupNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let openAction = UNNotificationAction(identifier: "OPEN_LOGS", title: "Open Logs", options: [.foreground])
        let category = UNNotificationCategory(identifier: "CRASH", actions: [openAction], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func postCrashNotification(serviceName: String, exitCode: Int32) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(serviceName) crashed"
        content.body = "Exited with code \(exitCode)"
        content.sound = .default
        content.categoryIdentifier = "CRASH"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotkey() {
        let isHotkey: (NSEvent) -> Bool = { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            return flags.contains([.control, .shift])
                && event.charactersIgnoringModifiers?.lowercased() == Flavor.current.hotkeyCharacter
        }

        globalHotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard isHotkey(event) else { return }
            Task { @MainActor in
                self?.togglePanel()
            }
        }

        localHotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard isHotkey(event) else { return event }
            Task { @MainActor in
                self?.togglePanel()
            }
            return nil
        }
    }

    // MARK: - Panel

    @objc private func togglePanel() {
        if WorkshopPanel.shared.isVisible {
            WorkshopPanel.shared.close()
            supervisor.panelVisible = false
        } else {
            WorkshopPanel.shared.open()
            NSApp.activate(ignoringOtherApps: true)
            supervisor.panelVisible = true
        }
    }
}
