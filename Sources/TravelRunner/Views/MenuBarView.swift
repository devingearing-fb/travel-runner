import SwiftUI

enum AppTab: String, CaseIterable {
    case services = "Services"
    case stripe = "Stripe"
    case booking = "Booking"
    case login = "Login"

    var serviceID: String? {
        switch self {
        case .services: nil
        case .stripe: "stripe"
        case .booking: "travel-portal"
        case .login: "universal-login"
        }
    }
}

struct MenuBarView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor
    @State private var selectedTab: AppTab = .services
    @State private var showSettings = false
    @State private var gitBranches: [String: String] = [:]
    @State private var logCounts: [String: LogCounts] = [:]
    @State private var preflightExpanded = true
    @State private var diagnosticCopied = false
    @State private var dbResetHasLogs = false
    @State private var dbResetEntries: [LogEntry] = []

    var isFirstRun: Bool {
        ConfigLoader.isFirstRun && supervisor.sortedServiceIDs.isEmpty
    }

    private var allPreflightsPassed: Bool {
        !supervisor.preflightChecks.isEmpty && supervisor.preflightChecks.allSatisfy { $0.result.isPassed }
    }

    private var failedServices: [ServiceState] {
        supervisor.sortedServiceIDs
            .compactMap { supervisor.serviceStates[$0] }
            .filter { $0.phase == .failed || $0.isCircuitBroken }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showSettings || isFirstRun {
                SetupView(isFirstRun: isFirstRun) {
                    showSettings = false
                    supervisor.loadConfig()
                }
            } else {
                mainContent
            }
        }
        .frame(minWidth: 440, idealWidth: 560)
        .preferredColorScheme(.dark)
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()

            if let error = supervisor.lastError {
                alertBanner(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    text: error,
                    subtitle: supervisor.rootCauseDescription,
                    action: ("Retry", { supervisor.retryStartAll() })
                )
            } else if supervisor.migrationsBannerVisible {
                alertBanner(
                    icon: "arrow.triangle.2.circlepath",
                    color: .orange,
                    text: "Migrations changed since last db:reset",
                    subtitle: nil,
                    action: ("Reset DB", { supervisor.resetDatabase() }),
                    onDismiss: { supervisor.dismissMigrationsBanner() }
                )
            }

            tabBar
            Divider()

            switch selectedTab {
            case .services:
                servicesContent
            case .stripe:
                ServiceConsoleView(
                    serviceID: "stripe",
                    logStore: supervisor.logStore
                )
                .frame(minHeight: 300, maxHeight: .infinity)
            case .booking:
                ServiceConsoleView(
                    serviceID: "travel-portal",
                    logStore: supervisor.logStore
                )
                .frame(minHeight: 300, maxHeight: .infinity)
            case .login:
                ServiceConsoleView(
                    serviceID: "universal-login",
                    logStore: supervisor.logStore
                )
                .frame(minHeight: 300, maxHeight: .infinity)
            }
        }
        .task {
            while !Task.isCancelled {
                if !supervisor.panelVisible {
                    try? await Task.sleep(for: .seconds(2))
                    continue
                }
                for tab in AppTab.allCases {
                    if let sid = tab.serviceID {
                        logCounts[sid] = await supervisor.logStore.counts(for: sid)
                    }
                }
                let dbVersion = await supervisor.logStore.version(for: "db-reset")
                if dbVersion > 0 {
                    dbResetHasLogs = true
                    dbResetEntries = await supervisor.logStore.entries(for: "db-reset")
                } else if !supervisor.dbResetRunning {
                    dbResetHasLogs = false
                }

                try? await Task.sleep(for: .milliseconds(1000))
            }
        }
        .task(id: selectedTab) {
            if let sid = selectedTab.serviceID,
               gitBranches[sid] == nil,
               let path = supervisor.serviceCwd(sid) {
                gitBranches[sid] = await fetchGitBranch(path)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(supervisor.health.color)
                .frame(width: 8, height: 8)

            ServiceDotMinimap(
                serviceStates: supervisor.serviceStates,
                sortedIDs: supervisor.sortedServiceIDs
            )

            if supervisor.dbMode == .remote {
                Text("DEV DB")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.purple, in: Capsule())
            }

            if supervisor.health == .starting, let began = supervisor.startupBeganAt {
                Text(began, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let sid = selectedTab.serviceID, let branch = gitBranches[sid] {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8))
                    Text(branch)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            Spacer()

            primaryActionButton

            overflowMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .clipped()
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        if supervisor.health == .stopped {
            Button(action: { supervisor.startAll() }) {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.small)
        } else if supervisor.health == .degraded && supervisor.currentPhase == .idle {
            Button("Retry") { supervisor.retryStartAll() }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
        } else if supervisor.health == .starting {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Button(action: { supervisor.stopAll() }) {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            Button(action: { supervisor.stopAll() }) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var overflowMenu: some View {
        Menu {
            if supervisor.networkMode, let ip = supervisor.localIP {
                Label(ip, systemImage: "wifi")
            }
            Button(action: { supervisor.toggleNetworkMode() }) {
                Label(
                    supervisor.networkMode ? "Disable LAN Mode" : "Enable LAN Mode",
                    systemImage: supervisor.networkMode ? "wifi" : "wifi.slash"
                )
            }

            Divider()

            Button(action: { supervisor.toggleDatabaseMode() }) {
                Label(
                    supervisor.dbMode == .local ? "Switch to Dev Database" : "Switch to Local Database",
                    systemImage: supervisor.dbMode == .local ? "cloud" : "externaldrive"
                )
            }

            Toggle("Auto-relink fb-travel-data", isOn: Binding(
                get: { supervisor.autoRelinkYalc },
                set: { supervisor.setAutoRelinkYalc($0) }
            ))

            if supervisor.yalcStale {
                Button("Relink fb-travel-data Now") {
                    supervisor.publishAndRetryYalc()
                }
            }

            Button("Clear Cache & Restart Portal") {
                supervisor.clearCacheAndRestart("travel-portal")
            }
            Button("Reset Database") {
                supervisor.resetDatabase()
            }

            Divider()

            Button(action: { Task { await copyDiagnosticBundle() } }) {
                Label(
                    diagnosticCopied ? "Copied!" : "Copy Diagnostics",
                    systemImage: diagnosticCopied ? "checkmark" : "doc.text.magnifyingglass"
                )
            }

            Button(action: { showSettings = true }) {
                Label("Settings...", systemImage: "gearshape")
            }

            Divider()

            if supervisor.debugTrackingEnabled {
                let count = supervisor.debugOpenIssueCount
                Label(
                    count > 0 ? "\(count) open debug issue\(count == 1 ? "" : "s")" : "Debug tracking active",
                    systemImage: "ant.fill"
                )
            }

            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
            Label("v\(version)", systemImage: "info.circle")

            Divider()

            Button("Quit Travel Runner") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(AppTab.allCases.enumerated()), id: \.element.rawValue) { index, tab in
                Button {
                    selectedTab = tab
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tabIcon(tab))
                            .font(.caption2)
                            .foregroundStyle(selectedTab == tab ? tabColor(tab) : .secondary)
                        Text(tab.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(selectedTab == tab ? .bold : .regular)

                        if let sid = tab.serviceID, let counts = logCounts[sid] {
                            if counts.error > 0 {
                                TabBadge(count: counts.error, color: .red)
                            }
                            if counts.warning > 0 {
                                TabBadge(count: counts.warning, color: .orange)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(selectedTab == tab ? tabColor(tab).opacity(0.12) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func tabIcon(_ tab: AppTab) -> String {
        switch tab {
        case .services: "square.grid.2x2"
        case .stripe: "bolt.fill"
        case .booking: "globe"
        case .login: "person.badge.key"
        }
    }

    private func tabColor(_ tab: AppTab) -> Color {
        switch tab {
        case .services: .accentColor
        case .stripe: .purple
        case .booking: .blue
        case .login: .green
        }
    }

    // MARK: - Alert Banner

    private func alertBanner(
        icon: String,
        color: Color,
        text: String,
        subtitle: String?,
        action: (label: String, handler: () -> Void),
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.caption)
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(action.label) { action.handler() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(color)
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(color.opacity(0.1))
    }

    // MARK: - Services Tab Content

    private var servicesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                // Triage zone — failed services auto-expand at top
                ForEach(failedServices) { state in
                    TriageCard(
                        state: state,
                        logStore: supervisor.logStore,
                        onRestart: { supervisor.restartService(state.id) },
                        onCascadeRestart: { supervisor.restartCascade(state.id) },
                        onClearCache: state.id == "travel-portal"
                            ? { supervisor.clearCacheAndRestart(state.id) } : nil,
                        onPublishRetry: state.id == "yalc-link"
                            ? { supervisor.publishAndRetryYalc() } : nil
                    )
                    .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.15), value: failedServices.map(\.id))

                // Preflight — only during startup, hidden once all pass
                if !supervisor.preflightChecks.isEmpty && !allPreflightsPassed {
                    preflightSection
                }

                // Timeline strip — startup only
                if supervisor.health == .starting {
                    TimelineStrip(
                        currentPhase: supervisor.currentPhase,
                        completedPhases: supervisor.completedPhases,
                        phaseTimings: supervisor.phaseTimings
                    )
                    .padding(.horizontal, 4)
                }

                // DB setup pipeline
                if let pipeline = supervisor.dbSetupPipeline,
                   pipeline.isRunning || pipeline.steps.contains(where: { $0.status != .pending }) {
                    DbSetupPipelineView(
                        pipeline: pipeline,
                        isRunning: supervisor.dbResetRunning,
                        onRetryFrom: { supervisor.runDbSetup(from: $0) },
                        onCancel: { supervisor.cancelDbSetup() },
                        onDismiss: { supervisor.dismissDbSetup() }
                    )
                } else if supervisor.dbResetRunning || dbResetHasLogs {
                    dbResetConsole
                }

                // Service list — phase sections with compact rows (failed filtered out)
                let failedIDs = Set(failedServices.map(\.id))
                let groups = supervisor.servicesByPhase()
                ForEach(groups, id: \.phase) { group in
                    let healthyServices = group.services.filter { !failedIDs.contains($0.id) }
                    if !healthyServices.isEmpty {
                        PhaseSection(
                            phase: group.phase,
                            services: healthyServices,
                            logStore: supervisor.logStore,
                            onRestart: { supervisor.restartService($0) },
                            onCascadeRestart: { supervisor.restartCascade($0) },
                            onPublishRetry: group.phase == "GATEWAY" ? { supervisor.publishAndRetryYalc() } : nil,
                            dbResetRunning: supervisor.dbResetRunning,
                            isServiceStale: { $0 == "yalc-link" && supervisor.yalcStale }
                        )
                    }
                }
            }
            .padding(10)
        }
        .frame(minHeight: 300, maxHeight: .infinity)
    }

    // MARK: - Preflight

    private var preflightSection: some View {
        DisclosureGroup("Preflight Checks", isExpanded: $preflightExpanded) {
            ForEach(supervisor.preflightChecks) { check in
                HStack(spacing: 8) {
                    Group {
                        switch check.result {
                        case .pending:
                            ProgressView().controlSize(.small)
                        case .passed:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case .warning:
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        case .failed:
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        }
                    }
                    .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(check.name)
                            .font(.caption)
                        if case .warning(let message) = check.result {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if case .failed(let message, let fix) = check.result {
                            Text(message)
                                .font(.caption2)
                                .foregroundStyle(.red)
                            if let fix {
                                Text("Fix: \(fix)")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    Spacer()

                    if case .passed(let detail) = check.result {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .background {
                    if case .failed = check.result {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.red.opacity(0.08))
                    }
                }
            }
        }
        .font(.caption)
    }

    // MARK: - DB Reset Console

    private var dbResetConsole: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if supervisor.dbResetRunning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption2)
                }
                Text("Database Reset")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                Spacer()
                if !supervisor.dbResetRunning && dbResetHasLogs {
                    Button {
                        Task { await supervisor.logStore.clear(serviceID: "db-reset") }
                        dbResetEntries = []
                        dbResetHasLogs = false
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
                }
            }

            TerminalTextView(
                entries: dbResetEntries,
                autoScroll: true,
                format: { entry in
                    let text = entry.text
                    let color: NSColor = if text.contains("error") || text.contains("ERROR") {
                        .systemRed
                    } else if text.contains("✓") || text.contains("done") || text.contains("complete") {
                        .systemGreen
                    } else {
                        .white
                    }
                    return (text, color)
                }
            )
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .padding(10)
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Diagnostic Bundle

    private func copyDiagnosticBundle() async {
        let secretPatterns = ["SECRET", "KEY", "TOKEN", "PASSWORD"]
        var bundle: [String: Any] = [
            "health": supervisor.health.rawValue,
            "currentPhase": supervisor.currentPhase.rawValue,
            "networkMode": supervisor.networkMode,
            "localIP": supervisor.localIP ?? "none",
            "generatedAt": ISO8601DateFormatter().string(from: .now),
        ]

        if let error = supervisor.lastError { bundle["lastError"] = error }
        if let rootCause = supervisor.rootCauseDescription { bundle["rootCause"] = rootCause }
        bundle["gitBranches"] = gitBranches

        var services: [String: [String: Any]] = [:]
        for (id, state) in supervisor.serviceStates {
            var info: [String: Any] = [
                "phase": state.phase.rawValue,
                "restartCount": state.restartCount,
            ]
            if let pid = state.pid { info["pid"] = pid }
            if let exitCode = state.exitCode { info["exitCode"] = exitCode }
            if let started = state.lastStarted { info["uptimeSeconds"] = Int(Date.now.timeIntervalSince(started)) }
            if state.isCircuitBroken { info["circuitBroken"] = true }
            services[id] = info
        }
        bundle["services"] = services

        var logs: [String: [String]] = [:]
        for id in supervisor.sortedServiceIDs {
            let entries = await supervisor.logStore.entries(for: id)
            logs[id] = entries.suffix(20).map { entry in
                let upper = entry.text.uppercased()
                for pat in secretPatterns where upper.contains(pat) {
                    return "[REDACTED]"
                }
                return entry.text
            }
        }
        bundle["recentLogs"] = logs

        if let data = try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
            diagnosticCopied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                diagnosticCopied = false
            }
        }
    }

    // MARK: - Helpers

    private func fetchGitBranch(_ path: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: branch?.isEmpty == false ? branch : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }
}

// MARK: - Tab Badge

struct TabBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color, in: Capsule())
    }
}
