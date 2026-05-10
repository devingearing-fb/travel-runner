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

    var isFirstRun: Bool {
        ConfigLoader.isFirstRun && supervisor.sortedServiceIDs.isEmpty
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
                errorBanner(error)
            }
            if supervisor.migrationsBannerVisible {
                migrationBanner
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

            Divider()
            controlSection
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
        HStack(spacing: 8) {
            Circle()
                .fill(supervisor.health.color)
                .frame(width: 10, height: 10)
            Text(supervisor.health.rawValue)
                .font(.system(.headline, design: .monospaced))
                .fontWeight(.bold)

            if supervisor.health == .starting, let began = supervisor.startupBeganAt {
                Text(began, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let sid = selectedTab.serviceID, let branch = gitBranches[sid] {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                        .font(.system(.caption2, design: .monospaced))
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }

            Spacer()

            if selectedTab == .booking {
                Button {
                    supervisor.clearCacheAndRestart("travel-portal")
                } label: {
                    Label("Clear Cache & Restart", systemImage: "arrow.clockwise")
                        .font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.orange)
            }

            if let ip = supervisor.localIP, supervisor.networkMode {
                Text(ip)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
            }

            Button(action: { supervisor.toggleNetworkMode() }) {
                Image(systemName: supervisor.networkMode ? "wifi" : "wifi.slash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(supervisor.networkMode ? .green : .secondary)
            .help(supervisor.networkMode ? "LAN mode ON — tap to disable" : "Enable LAN mode for mobile testing")

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Settings")

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Quit Travel Runner")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(error)
                    .font(.caption)
                    .lineLimit(3)
                if let rootCause = supervisor.rootCauseDescription {
                    Text(rootCause)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Button("Retry") {
                supervisor.retryStartAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.red.opacity(0.1))
    }

    // MARK: - Services Tab Content

    private var servicesContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !supervisor.preflightChecks.isEmpty {
                    preflightSection
                }

                if supervisor.health != .stopped {
                    TimelineStrip(
                        currentPhase: supervisor.currentPhase,
                        completedPhases: supervisor.completedPhases,
                        phaseTimings: supervisor.phaseTimings
                    )
                    .padding(.horizontal, 4)
                }

                let groups = supervisor.servicesByPhase()
                ForEach(groups, id: \.phase) { group in
                    PhaseSection(
                        phase: group.phase,
                        services: group.services,
                        logStore: supervisor.logStore,
                        onRestart: { supervisor.restartService($0) },
                        onCascadeRestart: { supervisor.restartCascade($0) },
                        onPublishRetry: group.phase == "GATEWAY" ? { supervisor.publishAndRetryYalc() } : nil,
                        onResetDb: group.phase == "GROUND" ? { supervisor.resetDatabase() } : nil,
                        dbResetRunning: supervisor.dbResetRunning
                    )
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 420)
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

    // MARK: - Migration Banner

    private var migrationBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text("Migrations changed since last db:reset")
                .font(.caption)
            Spacer()
            Button("Reset DB") { supervisor.resetDatabase() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.orange)
            Button {
                supervisor.dismissMigrationsBanner()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Controls

    private var controlSection: some View {
        HStack {
            if supervisor.health == .stopped {
                Button(action: { supervisor.startAll() }) {
                    Label("Start All", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.regular)
            } else if supervisor.health == .degraded && supervisor.currentPhase == .idle {
                Button("Retry") { supervisor.retryStartAll() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                Button("Start Anyway") { supervisor.startAll(skipPreflight: true) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button(action: { supervisor.stopAll() }) {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            Spacer()

            Button {
                Task { await copyDiagnosticBundle() }
            } label: {
                Image(systemName: diagnosticCopied ? "checkmark" : "doc.text.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(diagnosticCopied ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy diagnostic bundle")

            if supervisor.health == .starting {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
