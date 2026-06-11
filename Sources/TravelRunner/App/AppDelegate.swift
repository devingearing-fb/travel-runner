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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        supervisor = EnvironmentSupervisor()
        supervisor.loadConfig()

        supervisor.onServiceCrash = { [weak self] serviceName, exitCode in
            self?.postCrashNotification(serviceName: serviceName, exitCode: exitCode)
        }

        updateController = UpdateController()

        WorkshopPanel.shared.configure(supervisor: supervisor)

        setupNotifications()
        setupStatusItem()
        setupGlobalHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = rightClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalHotkeyMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localHotkeyMonitor { NSEvent.removeMonitor(monitor) }
        iconTimer?.invalidate()
        supervisor.resetEnvToLocalhost()

        // Phase 1: Collect the full process tree BEFORE sending signals.
        // Killing a parent reparents its children to launchd, making them
        // invisible to pgrep -P.
        var allPids = Set<pid_t>()
        for (_, state) in supervisor.serviceStates {
            if let pid = state.pid {
                allPids.insert(pid)
                collectDescendants(of: pid, into: &allPids)
            }
        }

        // Phase 2: SIGTERM everything we collected
        for pid in allPids {
            kill(pid, SIGTERM)
        }

        Thread.sleep(forTimeInterval: 1.0)

        // Phase 3: SIGKILL anything still alive
        for pid in allPids {
            kill(pid, SIGKILL)
        }

        // Phase 4: Kill by known service ports as a fallback
        killProcessesOnPorts([3000, 3002, 54322])
    }

    private func collectDescendants(of pid: pid_t, into result: inout Set<pid_t>) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return }
            for pidStr in text.split(separator: "\n") {
                if let child = pid_t(pidStr.trimmingCharacters(in: .whitespaces)) {
                    if result.insert(child).inserted {
                        collectDescendants(of: child, into: &result)
                    }
                }
            }
        } catch {}
    }

    private func killProcessesOnPorts(_ ports: [Int]) {
        for port in ports {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/lsof")
            task.arguments = ["-ti", "TCP:\(port)", "-sTCP:LISTEN"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                guard let text = String(data: data, encoding: .utf8) else { continue }
                for pidStr in text.split(separator: "\n") {
                    if let pid = pid_t(pidStr.trimmingCharacters(in: .whitespaces)) {
                        kill(pid, SIGKILL)
                    }
                }
            } catch {
                continue
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

        let openItem = NSMenuItem(title: "Open Travel Runner", action: #selector(openPanel), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let terminalsItem = NSMenuItem(title: "Open Terminals", action: #selector(openTerminals), keyEquivalent: "")
        terminalsItem.target = self
        menu.addItem(terminalsItem)

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = updateController.canCheckForUpdates
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Travel Runner", action: #selector(quitApp), keyEquivalent: "q")
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
        if let symbol = NSImage(systemSymbolName: "suitcase.rolling.fill", accessibilityDescription: "Travel Runner")?
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

    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let openAction = UNNotificationAction(identifier: "OPEN_LOGS", title: "Open Logs", options: [.foreground])
        let category = UNNotificationCategory(identifier: "CRASH", actions: [openAction], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    private func postCrashNotification(serviceName: String, exitCode: Int32) {
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
                && event.charactersIgnoringModifiers?.lowercased() == "t"
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
