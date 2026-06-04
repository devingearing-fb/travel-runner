import Foundation
import SwiftUI

@Observable
@MainActor
final class EnvironmentSupervisor {
    // MARK: - Published State

    var health: HealthStatus = .stopped
    var serviceStates: [String: ServiceState] = [:]
    var preflightChecks: [PreflightCheck] = []
    var currentPhase: StartupPhase = .idle
    var completedPhases: Set<String> = []
    var sortedServiceIDs: [String] = []
    var lastError: String? = nil
    var startupBeganAt: Date? = nil
    var migrationsBannerVisible = false
    var dbResetRunning = false
    var dbSetupPipeline: DbSetupPipeline? = nil
    var networkMode = false
    var localIP: String? = nil
    var panelVisible = false
    var rootCauseServiceID: String? = nil
    var phaseTimings: [String: TimeInterval] = [:]
    var onServiceCrash: (@MainActor (String, Int32) -> Void)? = nil
    var debugTrackingEnabled = false
    var debugOpenIssueCount = 0
    var gitBranches: [String: String] = [:]
    var yalcStale = false
    var autoRelinkYalc = UserDefaults.standard.bool(forKey: "autoRelinkYalc")
    var dbMode: DatabaseMode = .local
    var partnerPortalEnabled = UserDefaults.standard.bool(forKey: "partnerPortalEnabled")

    enum DatabaseMode: String, Sendable { case local, remote }

    var rootCauseDescription: String? {
        guard let rootID = rootCauseServiceID, let graph else { return nil }
        let name = serviceStates[rootID]?.definition.displayName ?? rootID
        let affected = graph.dependents(of: rootID).count
        if affected == 0 { return "Root cause: \(name)" }
        return "Root cause: \(name) — \(affected) dependent\(affected == 1 ? "" : "s") affected"
    }

    // MARK: - Internal Components

    private(set) var logStore = LogStore()
    private let secretStore = SecretStore()
    private var graph: ServiceGraph?
    private let processRunner = ProcessRunner()
    private let preflightRunner = PreflightRunner()
    private let migrationTracker = MigrationTracker()
    private var registry: LiveSecretRegistry?
    private var controlServer: ControlServer?
    private var envCompat: EnvCompatLayer?
    private var sleepWakeObserver: SleepWakeObserver?
    private var startTask: Task<Void, any Error>?
    private var config: ServiceConfig?
    private var isShuttingDown = false
    private var stdoutProbes: [String: StdoutProbe] = [:]
    private var observerRegistered = false
    private var phaseStartedAt: Date? = nil
    private var dbSetupRunner: DbSetupRunner?
    private var debugTracker: DebugTracker?
    private var yalcWatcher: YalcWatcher?
    private var gitBranchWatcher: GitBranchWatcher?
    private var yalcRelinkInProgress = false
    private var isTogglingNetwork = false
    private var stripeReconnectingSince: Date? = nil
    private var localSupabaseAnonKey: String?
    private var localSupabaseSigningKey: String?

    // MARK: - Types

    enum StartupPhase: String, Sendable, CaseIterable {
        case idle = "IDLE"
        case preflight = "PREFLIGHT"
        case ground = "GROUND"
        case gateway = "GATEWAY"
        case portal = "PORTAL"
        case running = "RUNNING"
    }

    enum ServiceError: Error, CustomStringConvertible {
        case oneshotFailed(String)
        case probeTimeout(String, seconds: Int)

        var description: String {
            switch self {
            case .oneshotFailed(let id): "'\(id)' exited with non-zero status"
            case .probeTimeout(let id, let s): "'\(id)' health probe timed out after \(s)s"
            }
        }
    }

    // MARK: - Lifecycle

    func loadConfig() {
        do {
            let config = try ConfigLoader.load()
            self.config = config
            self.serviceStates = [:]
            let graph = try ServiceGraph(services: config.services)
            self.graph = graph
            self.sortedServiceIDs = graph.sortedIDs

            for service in config.services {
                serviceStates[service.id] = ServiceState(definition: service)
            }

            // Derive .env.local paths from services that have artifact probes
            let portalService = config.services.first { $0.id == "travel-portal" }
            let envPath = portalService?.cwd.map { $0 + "/.env.local" }
                ?? "~/Documents/Codebases/TRAVEL BOOKING/travel-booking-portal/.env.local"
            envCompat = EnvCompatLayer(envFilePaths: [envPath])

            // Register secret observer once
            if !observerRegistered {
                observerRegistered = true
                let envCompat = self.envCompat
                Task {
                    await secretStore.onChange { key, value in
                        envCompat?.write(key: key, value: value)
                    }
                }
            }

            sleepWakeObserver = SleepWakeObserver { [weak self] in
                self?.handleWake()
            }
            sleepWakeObserver?.startObserving()

            // Always reset .env.local files to localhost on startup
            resetEnvToLocalhost()
            cacheLocalSupabaseKeys()

            // Start control API server
            startControlServer()

            // Initialize debug tracking (opt-in via ~/Desktop/debug-tracking/config.json)
            Task { await initDebugTracking() }

            // Initialize yalc staleness watcher
            if let travelDataPath = config.paths?.travelData, !travelDataPath.isEmpty {
                let watcher = YalcWatcher(travelDataDir: travelDataPath)
                yalcWatcher = watcher
                Task { await startYalcWatching(watcher: watcher) }
            }

            // Initialize git branch watcher for all repos with cwds
            var repoMap: [String: String] = [:]
            for service in config.services {
                if let cwd = service.resolvedCwd {
                    repoMap[service.id] = cwd
                }
            }
            if let dataPath = config.paths?.travelData, !dataPath.isEmpty {
                repoMap["fb-travel-data"] = NSString(string: dataPath).expandingTildeInPath as String
            }
            if !repoMap.isEmpty {
                let watcher = GitBranchWatcher(repos: repoMap)
                gitBranchWatcher = watcher
                Task { await startGitBranchWatching(watcher: watcher) }
            }
        } catch ConfigLoader.ConfigError.noConfig {
            // First run — setup wizard will handle this
        } catch {
            lastError = "Config load failed: \(error)"
            print("[Supervisor] \(lastError!)")
        }
    }

    // MARK: - Start / Stop

    func startAll(skipPreflight: Bool = false) {
        guard startTask == nil, let graph, let config else { return }
        health = .starting
        lastError = nil
        startupBeganAt = .now
        phaseTimings = [:]

        startTask = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor in
                    self.startTask = nil
                }
            }

            // Preflight
            if !skipPreflight {
                self.currentPhase = .preflight
                let checks = self.preflightRunner.allChecks(for: config.services)
                await MainActor.run { self.preflightChecks = checks }

                var allPassed = true
                var failedDetails: [String] = []
                for check in checks {
                    let result = await self.preflightRunner.run(check: check)
                    await MainActor.run { check.result = result }
                    if case .failed(let message, _) = result {
                        allPassed = false
                        failedDetails.append("\(check.name): \(message)")
                    }
                }

                _ = await MainActor.run { self.completedPhases.insert("PREFLIGHT") }

                if !allPassed {
                    let summary = failedDetails.joined(separator: " · ")
                    await MainActor.run {
                        self.health = .degraded
                        self.lastError = "Preflight failed — \(summary)"
                        self.currentPhase = .idle
                    }
                    await self.captureDebugIssue(
                        trigger: "preflight_failure",
                        serviceID: nil,
                        summary: "Preflight failed — \(summary)"
                    )
                    return
                }
            }

            // Cleanup stale processes from previous sessions
            await self.cleanupStaleProcesses()

            // Start registry
            self.registry = LiveSecretRegistry(secretStore: self.secretStore)
            do {
                try await self.registry?.start()
            } catch {
                await MainActor.run {
                    self.lastError = "Secret registry failed to start: \(error)"
                }
            }

            // Execute DAG with migration check after GROUND phase
            let levels = graph.startOrder()
            var didMigrationCheck = false

            for level in levels {
                if Task.isCancelled { break }

                let phase = self.resolvePhase(for: level)
                await MainActor.run {
                    self.currentPhase = phase
                    self.phaseStartedAt = .now
                }

                await withTaskGroup(of: Void.self) { group in
                    for serviceID in level {
                        group.addTask { [self] in
                            do {
                                try await self.startService(serviceID)
                            } catch {
                                await MainActor.run {
                                    self.serviceStates[serviceID]?.phase = .failed
                                    self.lastError = "\(error)"
                                    self.recalculateHealth()
                                }
                            }
                        }
                    }
                }

                _ = await MainActor.run {
                    if let started = self.phaseStartedAt {
                        self.phaseTimings[phase.rawValue] = Date.now.timeIntervalSince(started)
                    }
                    self.completedPhases.insert(phase.rawValue)
                }

                // After GROUND phase completes (Supabase is up), check migrations
                // AND verify the database actually has application tables.
                // Triggers db:reset when: first run, migrations changed, or DB is empty
                // (e.g. fresh Docker volume with no tables applied).
                if phase == .ground && !didMigrationCheck {
                    didMigrationCheck = true
                    let portalCwd = config.services.first(where: { $0.id == "supabase" })?.resolvedCwd
                    if let cwd = portalCwd {
                        let migrationsChanged = !self.migrationTracker.hasEverRun()
                            || self.migrationTracker.migrationsChanged(portalCwd: cwd)
                        var dbEmpty = false
                        if !migrationsChanged {
                            let hasTables = await self.databaseHasAppTables(portalCwd: cwd)
                            dbEmpty = !hasTables
                        }
                        let needsReset = migrationsChanged || dbEmpty
                        if needsReset {
                            let reason = dbEmpty
                                ? "Empty database detected — running db:reset..."
                                : "New migrations detected — running db:reset..."
                            await MainActor.run {
                                self.lastError = reason
                                self.dbResetRunning = true
                            }
                            let ok = await self.runDbReset(cwd: cwd)
                            await MainActor.run {
                                self.dbResetRunning = false
                                if ok {
                                    self.lastError = nil
                                    self.migrationTracker.recordCurrentHash(portalCwd: cwd)
                                } else {
                                    self.lastError = "db:reset failed — expand logs or click Reset DB to retry"
                                    self.migrationsBannerVisible = true
                                }
                            }
                        }
                    }
                }
            }

            await MainActor.run {
                self.recalculateHealth()
                if self.health == .healthy {
                    self.currentPhase = .running
                }
                self.startupBeganAt = nil
            }
        }
    }

    func stopAll() {
        isShuttingDown = true
        startTask?.cancel()
        startTask = nil
        Task {
            for serviceID in sortedServiceIDs {
                serviceStates[serviceID]?.phase = .stopping
            }

            await processRunner.stopAll()

            // Kill any orphaned processes still bound to service ports
            if let config {
                for service in config.services where !service.shouldReuseIfRunning {
                    if let port = service.probe?.port, isPortBound(port) {
                        await killPortOccupants(port)
                    }
                }
            }

            for serviceID in sortedServiceIDs {
                serviceStates[serviceID]?.phase = .stopped
            }

            await registry?.stop()
            health = .stopped
            currentPhase = .idle
            completedPhases = []
            phaseTimings = [:]
            lastError = nil
            startupBeganAt = nil
            isShuttingDown = false
            networkMode = false
            localIP = nil
            resetEnvToLocalhost()
        }
    }

    private func startControlServer() {
        let logStore = self.logStore
        controlServer = ControlServer()
        Task {
            try await controlServer?.start(
                actions: ControlServer.Actions(
                    getStatus: { [weak self] in
                        guard let self else { return "{}" }
                        let states = await MainActor.run {
                            self.serviceStates.mapValues { s in
                                ["phase": s.phase.rawValue, "pid": s.pid.map(String.init) ?? "nil"]
                            }
                        }
                        let health = await MainActor.run { self.health.rawValue }
                        let lan = await MainActor.run { self.networkMode }
                        let ip = await MainActor.run { self.localIP ?? "none" }
                        let yalcStale = await MainActor.run { self.yalcStale }
                        let yalcAuto = await MainActor.run { self.autoRelinkYalc }
                        let dbMode = await MainActor.run { self.dbMode.rawValue }
                        let branches = await MainActor.run { self.gitBranches }
                        let dict: [String: Any] = [
                            "health": health, "services": states, "lan": lan, "ip": ip,
                            "yalc": ["stale": yalcStale, "auto_relink": yalcAuto] as [String: Any],
                            "db_mode": dbMode,
                            "branches": branches
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                           let str = String(data: data, encoding: .utf8) { return str }
                        return "{}"
                    },
                    getLogs: { [weak self] serviceId, lines in
                        guard let self else { return "[]" }
                        let entries = await self.logStore.entries(for: serviceId)
                        let tail = entries.suffix(lines)
                        let lines = tail.map { ["stream": $0.stream == .stdout ? "stdout" : "stderr", "text": $0.text] }
                        if let data = try? JSONSerialization.data(withJSONObject: lines, options: []),
                           let str = String(data: data, encoding: .utf8) { return str }
                        return "[]"
                    },
                    restartService: { [weak self] serviceId in
                        await MainActor.run { self?.restartService(serviceId) }
                    },
                    clearCacheRestart: { [weak self] serviceId in
                        await MainActor.run { self?.clearCacheAndRestart(serviceId) }
                    },
                    startAll: { [weak self] in
                        await MainActor.run { self?.startAll() }
                    },
                    stopAll: { [weak self] in
                        await MainActor.run { self?.stopAll() }
                    },
                    toggleLan: { [weak self] in
                        await MainActor.run { self?.toggleNetworkMode() }
                    },
                    restartCascade: { [weak self] serviceId in
                        await MainActor.run { self?.restartCascade(serviceId) }
                    },
                    dbReset: { [weak self] in
                        await MainActor.run { self?.resetDatabase() }
                    },
                    dbSetupRun: { [weak self] profile in
                        await MainActor.run { self?.runDbSetup(profile: profile) }
                    },
                    dbSetupRetry: { [weak self] stepId in
                        await MainActor.run { self?.runDbSetup(from: stepId) }
                    },
                    dbSetupCancel: { [weak self] in
                        await MainActor.run { self?.cancelDbSetup() }
                    },
                    dbSetupStatus: { [weak self] in
                        await MainActor.run { self?.dbSetupStatusJSON() ?? "{}" }
                    },
                    dbSetupRunStep: { [weak self] stepId in
                        await MainActor.run { self?.runDbSetupStep(stepId) }
                    },
                    debugListIssues: { [weak self] in
                        guard let self, let tracker = await MainActor.run(body: { self.debugTracker }) else { return "[]" }
                        let issues: [[String: String]] = await tracker.listOpenIssues()
                        if let data = try? JSONSerialization.data(withJSONObject: issues, options: [.sortedKeys]),
                           let str = String(data: data, encoding: .utf8) { return str }
                        return "[]"
                    },
                    debugCapture: { [weak self] description in
                        guard let self else { return "{\"ok\":false}" }
                        await MainActor.run {
                            Task { await self.captureDebugIssue(
                                trigger: "manual",
                                serviceID: nil,
                                summary: description
                            )}
                        }
                        return "{\"ok\":true}"
                    },
                    debugCloseIssue: { [weak self] id, resolution in
                        guard let self, let tracker = await MainActor.run(body: { self.debugTracker }) else {
                            return "{\"ok\":false,\"error\":\"debug tracking not enabled\"}"
                        }
                        let ok = await tracker.closeIssue(id: id, resolution: resolution ?? "Closed via API")
                        if ok {
                            let count = await tracker.openIssueCount()
                            await MainActor.run { self.debugOpenIssueCount = count }
                        }
                        return ok ? "{\"ok\":true}" : "{\"ok\":false,\"error\":\"issue not found\"}"
                    },
                    yalcRelink: { [weak self] in
                        await MainActor.run { self?.publishAndRetryYalc() }
                    },
                    yalcToggleAuto: { [weak self] in
                        await MainActor.run {
                            guard let self else { return }
                            self.setAutoRelinkYalc(!self.autoRelinkYalc)
                        }
                    },
                    yalcStatus: { [weak self] in
                        guard let self else { return "{}" }
                        return await self.yalcStatusJSON()
                    },
                    toggleDbMode: { [weak self] in
                        await MainActor.run { self?.toggleDatabaseMode() }
                    }
                ),
                logStore: logStore
            )
        }
    }

    func resetEnvToLocalhost() {
        let portalCwd = graph?.nodes["travel-portal"]?.resolvedCwd
        let loginCwd = graph?.nodes["universal-login"]?.resolvedCwd

        if let cwd = portalCwd {
            let env = EnvCompatLayer(envFilePaths: [cwd + "/.env.local"])
            env.write(key: "NEXT_PUBLIC_SUPABASE_URL", value: "http://localhost:54321")
            env.write(key: "LOCAL_SUPABASE_URL", value: "http://localhost:54321")
            env.write(key: "NEXT_PUBLIC_WEBAPP_URL", value: "http://localhost:3002")
            env.write(key: "LOGIN_URL", value: "http://localhost:3000/login/init")
            env.write(key: "NEXT_PUBLIC_LOCAL_DEV", value: "true")
            if let anonKey = localSupabaseAnonKey {
                env.write(key: "LOCAL_SUPABASE_ANON_KEY", value: anonKey)
            }
            if let signingKey = localSupabaseSigningKey {
                env.write(key: "LOCAL_SUPABASE_SIGNING_KEY", value: signingKey)
            }
        }
        if let cwd = loginCwd {
            let env = EnvCompatLayer(envFilePaths: [cwd + "/.env.local"])
            env.write(key: "NEXT_PUBLIC_SUPABASE_URL", value: "http://localhost:54321")
            env.write(key: "AMATEUR_SUPABASE_URL", value: "http://localhost:54321")
            env.write(key: "NEXT_PUBLIC_SITE_URL", value: "http://localhost:3000")
            env.write(key: "NEXT_PUBLIC_AMATEUR_LOCAL_UNIVERSAL_LOGIN_URL", value: "http://localhost:3000")
            if let anonKey = localSupabaseAnonKey {
                env.write(key: "AMATEUR_SUPABASE_ANON_KEY", value: anonKey)
            }
            if let signingKey = localSupabaseSigningKey {
                env.write(key: "AMATEUR_SUPABASE_SIGNING_KEY", value: signingKey)
            }
        }
        if let rawPartner = config?.paths?.partnerPortal, !rawPartner.isEmpty {
            let partnerPath = NSString(string: rawPartner).expandingTildeInPath
            let localEnvPath = (partnerPath as NSString).appendingPathComponent(".env.local.runner")
            if FileManager.default.fileExists(atPath: localEnvPath) {
                let source = readEnvFile(localEnvPath)
                let env = EnvCompatLayer(envFilePaths: [partnerPath + "/.env.local"])
                for (key, value) in source {
                    env.write(key: key, value: value)
                }
            }
        }
        dbMode = .local
    }

    func clearCacheAndRestart(_ serviceID: String) {
        guard let cwd = config?.services.first(where: { $0.id == serviceID })?.resolvedCwd else {
            lastError = "No cwd found for \(serviceID)"
            return
        }
        Task {
            serviceStates[serviceID]?.phase = .stopping
            await processRunner.stop(serviceID: serviceID)
            serviceStates[serviceID]?.phase = .starting

            let nextCachePath = (cwd as NSString).appendingPathComponent(".next")
            try? FileManager.default.removeItem(atPath: nextCachePath)
            await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stdout, text: "[travel-runner] Cleared .next cache"))

            try? await Task.sleep(for: .seconds(1))
            do {
                try await startService(serviceID)
            } catch {
                serviceStates[serviceID]?.phase = .failed
                lastError = "\(error)"
                recalculateHealth()
            }
        }
    }

    // MARK: - Database Mode Toggle

    private func cacheLocalSupabaseKeys() {
        guard let portalCwd = graph?.nodes["travel-portal"]?.resolvedCwd else { return }
        let envPath = (portalCwd as NSString).appendingPathComponent(".env.local")
        guard let content = try? String(contentsOfFile: envPath, encoding: .utf8) else { return }
        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("LOCAL_SUPABASE_ANON_KEY=") {
                localSupabaseAnonKey = String(line.dropFirst("LOCAL_SUPABASE_ANON_KEY=".count))
            }
            if line.hasPrefix("LOCAL_SUPABASE_SIGNING_KEY=") {
                localSupabaseSigningKey = String(line.dropFirst("LOCAL_SUPABASE_SIGNING_KEY=".count))
            }
        }
    }

    private func readEnvFile(_ path: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var vars: [String: String] = [:]
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eqIdx])
            let value = String(trimmed[trimmed.index(after: eqIdx)...])
            vars[key] = value
        }
        return vars
    }

    func toggleDatabaseMode() {
        guard health == .healthy || health == .stopped else {
            lastError = "Cannot switch database while services are starting"
            return
        }

        let portalCwd = graph?.nodes["travel-portal"]?.resolvedCwd
        let loginCwd = graph?.nodes["universal-login"]?.resolvedCwd

        if dbMode == .local {
            guard let cwd = portalCwd else { return }
            let remotePath = (cwd as NSString).appendingPathComponent(".env.remote")
            let remote = readEnvFile(remotePath)
            guard let remoteUrl = remote["NEXT_PUBLIC_SUPABASE_URL"], !remoteUrl.isEmpty else {
                lastError = ".env.remote not found or missing NEXT_PUBLIC_SUPABASE_URL — create it in the booking portal"
                return
            }

            let env = EnvCompatLayer(envFilePaths: [cwd + "/.env.local"])
            for (key, value) in remote {
                env.write(key: key, value: value)
            }

            if let loginCwd {
                let loginEnv = EnvCompatLayer(envFilePaths: [loginCwd + "/.env.local"])
                loginEnv.write(key: "NEXT_PUBLIC_SUPABASE_URL", value: remoteUrl)
                loginEnv.write(key: "AMATEUR_SUPABASE_URL", value: remoteUrl)
                if let anonKey = remote["LOCAL_SUPABASE_ANON_KEY"] {
                    loginEnv.write(key: "AMATEUR_SUPABASE_ANON_KEY", value: anonKey)
                }
                if let signingKey = remote["LOCAL_SUPABASE_SIGNING_KEY"] {
                    loginEnv.write(key: "AMATEUR_SUPABASE_SIGNING_KEY", value: signingKey)
                }
            }

            if let rawPartner2 = config?.paths?.partnerPortal, !rawPartner2.isEmpty {
                let partnerPath = NSString(string: rawPartner2).expandingTildeInPath
                let partnerEnv = EnvCompatLayer(envFilePaths: [partnerPath + "/.env.local"])
                partnerEnv.write(key: "NEXT_PUBLIC_SUPABASE_URL", value: remoteUrl)
                partnerEnv.write(key: "SUPABASE_URL", value: remoteUrl)
                partnerEnv.write(key: "AMATEUR_SUPABASE_URL_DEV", value: remoteUrl)
                if let anonKey = remote["LOCAL_SUPABASE_ANON_KEY"] {
                    partnerEnv.write(key: "AMATEUR_SUPABASE_ANON_KEY_DEV", value: anonKey)
                }
                if let signingKey = remote["LOCAL_SUPABASE_SIGNING_KEY"] {
                    partnerEnv.write(key: "AMATEUR_SUPABASE_SIGNING_KEY_DEV", value: signingKey)
                }
                partnerEnv.write(key: "LOGIN_URL", value: "http://localhost:3000/login/init")
                partnerEnv.write(key: "NEXT_PUBLIC_WEBAPP_URL", value: "http://localhost:3001")
            }

            dbMode = .remote
        } else {
            resetEnvToLocalhost()
            dbMode = .local
        }

        guard health != .stopped else { return }

        var servicesToRestart = ["travel-portal", "universal-login"]
        if partnerPortalEnabled && serviceStates["partner-portal"] != nil {
            servicesToRestart.append("partner-portal")
        }
        Task {
            for serviceID in servicesToRestart {
                serviceStates[serviceID]?.phase = .stopping
            }
            for serviceID in servicesToRestart {
                await processRunner.stop(serviceID: serviceID)
                serviceStates[serviceID]?.phase = .starting
                do {
                    try await startService(serviceID)
                } catch {
                    serviceStates[serviceID]?.phase = .failed
                    lastError = "DB mode switch failed for \(serviceID): \(error)"
                }
            }
            recalculateHealth()
        }
    }

    func toggleNetworkMode() {
        guard !isTogglingNetwork else { return }
        isTogglingNetwork = true
        networkMode.toggle()
        let mode = networkMode

        Task {
            defer { isTogglingNetwork = false }

            if mode {
                let (output, ok) = await shellOutput("ipconfig getifaddr en0")
                localIP = ok ? output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            } else {
                localIP = nil
            }

            let ip = localIP ?? "127.0.0.1"

            let portalCwd = graph?.nodes["travel-portal"]?.resolvedCwd
            let loginCwd = graph?.nodes["universal-login"]?.resolvedCwd

            let host = mode ? ip : "localhost"

            if let cwd = portalCwd {
                let env = EnvCompatLayer(envFilePaths: [cwd + "/.env.local"])
                env.write(key: "NEXT_PUBLIC_SUPABASE_URL", value: "http://\(host):54321")
                env.write(key: "LOCAL_SUPABASE_URL", value: "http://\(host):54321")
                env.write(key: "NEXT_PUBLIC_WEBAPP_URL", value: "http://\(host):3002")
                env.write(key: "LOGIN_URL", value: "http://\(host):3000/login/init")
            }
            if let cwd = loginCwd {
                let env = EnvCompatLayer(envFilePaths: [cwd + "/.env.local"])
                env.write(key: "NEXT_PUBLIC_SUPABASE_URL", value: "http://\(host):54321")
                env.write(key: "AMATEUR_SUPABASE_URL", value: "http://\(host):54321")
                env.write(key: "NEXT_PUBLIC_SITE_URL", value: "http://\(host):3000")
                env.write(key: "NEXT_PUBLIC_AMATEUR_LOCAL_UNIVERSAL_LOGIN_URL", value: "http://\(host):3000")
            }
            if let rawPartner = config?.paths?.partnerPortal, !rawPartner.isEmpty {
                let partnerPath = NSString(string: rawPartner).expandingTildeInPath
                let baselinePath = (partnerPath as NSString).appendingPathComponent(".env.local.runner")
                let source = readEnvFile(baselinePath)
                let env = EnvCompatLayer(envFilePaths: [partnerPath + "/.env.local"])
                for (key, value) in source {
                    env.write(key: key, value: value.replacingOccurrences(of: "localhost", with: host))
                }
            }

            var servicesToRestart = ["travel-portal", "universal-login"]
            if partnerPortalEnabled && serviceStates["partner-portal"] != nil {
                servicesToRestart.append("partner-portal")
            }

            for serviceID in servicesToRestart {
                serviceStates[serviceID]?.phase = .stopping
            }

            for serviceID in servicesToRestart {
                await processRunner.stop(serviceID: serviceID)
                await logStore.append(
                    serviceID: serviceID,
                    entry: LogEntry(stream: .stdout, text: "[travel-runner] Network mode \(mode ? "ON — http://\(ip)" : "OFF — localhost only")")
                )
                serviceStates[serviceID]?.phase = .starting
                do {
                    try await startService(serviceID)
                } catch {
                    serviceStates[serviceID]?.phase = .failed
                    lastError = "Network mode restart failed for \(serviceID): \(error)"
                }
            }

            recalculateHealth()
        }
    }

    private func shellOutput(_ command: String) async -> (String, Bool) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: (output, p.terminationStatus == 0))
            }
            do { try process.run() } catch { continuation.resume(returning: ("", false)) }
        }
    }

    func restartService(_ serviceID: String) {
        if serviceID == "stripe" { stripeReconnectingSince = nil }
        Task {
            serviceStates[serviceID]?.phase = .stopping
            await processRunner.stop(serviceID: serviceID)
            serviceStates[serviceID]?.phase = .pending
            serviceStates[serviceID]?.restartCount = 0
            serviceStates[serviceID]?.isCircuitBroken = false
            serviceStates[serviceID]?.failureTimestamps = []
            try? await Task.sleep(for: .seconds(1))
            do {
                try await startService(serviceID)
            } catch {
                serviceStates[serviceID]?.phase = .failed
                lastError = "\(error)"
                recalculateHealth()
            }
        }
    }

    func restartCascade(_ serviceID: String) {
        guard let graph else { return }
        let dependents = graph.dependents(of: serviceID)
        let allAffected = dependents.union([serviceID])
        let topoOrder = graph.sortedIDs.filter { allAffected.contains($0) }

        Task {
            for id in topoOrder.reversed() {
                serviceStates[id]?.phase = .stopping
                await processRunner.stop(serviceID: id)
                serviceStates[id]?.phase = .stopped
            }

            for id in topoOrder {
                serviceStates[id]?.phase = .starting
                serviceStates[id]?.restartCount = 0
                serviceStates[id]?.isCircuitBroken = false
                serviceStates[id]?.failureTimestamps = []
                do {
                    try await startService(id)
                } catch {
                    serviceStates[id]?.phase = .failed
                    lastError = "Cascade restart failed at \(id): \(error)"
                    recalculateHealth()
                    return
                }

                // After Supabase comes back, check if DB is empty and auto-reset
                if id == "supabase", let cwd = config?.services.first(where: { $0.id == "supabase" })?.resolvedCwd {
                    let hasTables = await databaseHasAppTables(portalCwd: cwd)
                    if !hasTables {
                        dbResetRunning = true
                        lastError = "Empty database detected — running db:reset..."
                        let ok = await runDbReset(cwd: cwd)
                        dbResetRunning = false
                        if ok {
                            lastError = nil
                            migrationTracker.recordCurrentHash(portalCwd: cwd)
                        } else {
                            lastError = "db:reset failed — check logs"
                        }
                    }
                }
            }
            recalculateHealth()
        }
    }

    func retryStartAll() {
        preflightChecks = []
        completedPhases = []
        lastError = nil
        startAll()
    }

    func publishAndRetryYalc() {
        guard let travelDataDir = config?.paths?.travelData.map({ NSString(string: $0).expandingTildeInPath }) else {
            lastError = "fb-travel-data path not configured — open Settings"
            return
        }

        serviceStates["yalc-link"]?.phase = .starting
        Task {
            let ok = await runShellCommand("cd \"\(travelDataDir)\" && npm run build && yalc publish")
            if ok {
                restartService("yalc-link")
            } else {
                serviceStates["yalc-link"]?.phase = .failed
                lastError = "yalc publish failed — check fb-travel-data build"
            }
        }
    }

    func setAutoRelinkYalc(_ enabled: Bool) {
        autoRelinkYalc = enabled
        UserDefaults.standard.set(enabled, forKey: "autoRelinkYalc")
    }

    func setPartnerPortalEnabled(_ enabled: Bool) {
        partnerPortalEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "partnerPortalEnabled")
        if enabled {
            setupPartnerPortalEnv()
        }
    }

    private func setupPartnerPortalEnv() {
        guard let rawPartnerCwd = config?.paths?.partnerPortal, !rawPartnerCwd.isEmpty else { return }
        let partnerCwd = NSString(string: rawPartnerCwd).expandingTildeInPath

        let localEnvPath = (partnerCwd as NSString).appendingPathComponent(".env.local.runner")
        guard FileManager.default.fileExists(atPath: localEnvPath) else { return }

        if dbMode == .local {
            let source = readEnvFile(localEnvPath)
            let env = EnvCompatLayer(envFilePaths: [partnerCwd + "/.env.local"])
            for (key, value) in source {
                env.write(key: key, value: value)
            }
        }
    }

    func yalcStatusJSON() async -> String {
        guard let watcher = yalcWatcher else { return "{\"configured\":false}" }
        let stale = await watcher.isStale
        let autoRelink = autoRelinkYalc
        let srcMtime = await watcher.sourceModifiedAt
        let distMtime = await watcher.lastBuiltAt

        var dict: [String: Any] = [
            "configured": true,
            "stale": stale,
            "auto_relink": autoRelink,
        ]
        if let src = srcMtime { dict["source_modified"] = ISO8601DateFormatter().string(from: src) }
        if let dist = distMtime { dict["last_built"] = ISO8601DateFormatter().string(from: dist) }

        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) { return str }
        return "{}"
    }

    private func startYalcWatching(watcher: YalcWatcher) async {
        while !Task.isCancelled {
            let stale = await watcher.check()
            await MainActor.run { self.yalcStale = stale }

            if stale && autoRelinkYalc && !yalcRelinkInProgress && health == .healthy {
                let settled = await watcher.sourceSettled
                if settled {
                    await MainActor.run {
                        self.yalcRelinkInProgress = true
                        self.publishAndRetryYalc()
                    }
                    try? await Task.sleep(for: .seconds(10))
                    await MainActor.run { self.yalcRelinkInProgress = false }
                }
            }

            try? await Task.sleep(for: .seconds(5))
        }
    }

    private func startGitBranchWatching(watcher: GitBranchWatcher) async {
        _ = await watcher.check()
        let initial = await watcher.branches
        await MainActor.run { self.gitBranches = initial }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            let changed = await watcher.check()
            let allBranches = await watcher.branches
            await MainActor.run { self.gitBranches = allBranches }

            guard !changed.isEmpty, health == .healthy else { continue }

            for serviceID in changed {
                let branchName = allBranches[serviceID] ?? "unknown"
                let displayName = serviceStates[serviceID]?.definition.displayName ?? serviceID
                await logStore.append(
                    serviceID: serviceID,
                    entry: LogEntry(stream: .stdout,
                        text: "[travel-runner] Branch changed to '\(branchName)' — restarting \(displayName)")
                )
            }

            if changed.contains("supabase") || changed.contains("travel-portal") {
                if let cwd = serviceCwd("supabase") ?? serviceCwd("travel-portal") {
                    if migrationTracker.migrationsChanged(portalCwd: cwd) {
                        await MainActor.run {
                            self.lastError = "Branch switch: new migrations detected — running db:reset..."
                            self.dbResetRunning = true
                        }
                        let ok = await runDbReset(cwd: cwd)
                        await MainActor.run {
                            self.dbResetRunning = false
                            if ok {
                                self.lastError = nil
                                self.migrationTracker.recordCurrentHash(portalCwd: cwd)
                            } else {
                                self.lastError = "db:reset failed after branch switch"
                                self.migrationsBannerVisible = true
                            }
                        }
                    }
                }
            }

            if changed.contains("fb-travel-data") {
                await MainActor.run { self.publishAndRetryYalc() }
            }

            let runningChanged = changed.filter { serviceStates[$0]?.phase == .running }
            for serviceID in runningChanged {
                restartService(serviceID)
            }
        }
    }

    func resetDatabase(profile: String = "reset") {
        runDbSetup(profile: profile)
    }

    func runDbSetup(from stepId: String? = nil, profile: String = "reset") {
        guard dbSetupPipeline?.isRunning != true else { return }
        guard let cwd = config?.services.first(where: { $0.id == "supabase" })?.resolvedCwd else {
            lastError = "Cannot find supabase service cwd in config"
            return
        }

        let manifestPath = (cwd as NSString).appendingPathComponent("scripts/db/manifest.json")
        let steps: [DbSetupStep]
        if FileManager.default.fileExists(atPath: manifestPath) {
            steps = DbManifestLoader.load(from: manifestPath, profile: profile)
        } else {
            steps = DbSetupPipeline.buildDefault()
        }

        let pipeline = DbSetupPipeline()
        pipeline.steps = steps
        dbSetupPipeline = pipeline
        dbResetRunning = true
        migrationsBannerVisible = false
        lastError = nil

        let runner = DbSetupRunner(portalCwd: cwd, logStore: logStore)
        dbSetupRunner = runner

        Task {
            await runner.run(pipeline: pipeline, from: stepId)
            dbResetRunning = false
            if pipeline.allRequiredPassed {
                migrationTracker.recordCurrentHash(portalCwd: cwd)
                lastError = nil
            } else if let failed = pipeline.firstFailed {
                lastError = "DB setup failed at \(failed.name): \(failed.errorMessage ?? "unknown error")"
                Task { await captureDebugIssue(
                    trigger: "db_setup_failure",
                    serviceID: nil,
                    summary: "DB setup failed at \(failed.name)",
                    errorMessage: failed.errorMessage,
                    recoveryGuidance: failed.recoveryGuidance
                )}
            }
        }
    }

    func runDbSetupStep(_ stepId: String) {
        guard let cwd = config?.services.first(where: { $0.id == "supabase" })?.resolvedCwd else { return }
        if dbSetupPipeline == nil {
            let manifestPath = (cwd as NSString).appendingPathComponent("scripts/db/manifest.json")
            let steps: [DbSetupStep]
            if FileManager.default.fileExists(atPath: manifestPath) {
                steps = DbManifestLoader.load(from: manifestPath, profile: "full")
            } else {
                steps = DbSetupPipeline.buildDefault()
            }
            let pipeline = DbSetupPipeline()
            pipeline.steps = steps
            dbSetupPipeline = pipeline
        }

        guard let pipeline = dbSetupPipeline,
              let step = pipeline.steps.first(where: { $0.id == stepId }) else { return }

        let runner = DbSetupRunner(portalCwd: cwd, logStore: logStore)
        dbSetupRunner = runner

        Task {
            dbResetRunning = true
            let _ = await runner.executeStepPublic(step)
            dbResetRunning = false
        }
    }

    func dbSetupStatusJSON() -> String {
        guard let pipeline = dbSetupPipeline else { return "{\"running\":false,\"steps\":[]}" }
        var steps: [[String: Any]] = []
        for step in pipeline.steps {
            var dict: [String: Any] = [
                "id": step.id,
                "name": step.name,
                "status": step.status.rawValue,
                "optional": step.isOptional,
            ]
            if let elapsed = step.elapsed { dict["elapsed_seconds"] = Int(elapsed) }
            if let msg = step.errorMessage { dict["error"] = msg }
            if let guidance = step.recoveryGuidance { dict["recovery"] = guidance }
            if let health = step.healthResult { dict["health_result"] = health }
            if let progress = step.progress { dict["progress"] = progress }
            if let label = step.progressLabel { dict["progress_label"] = label }
            steps.append(dict)
        }
        let result: [String: Any] = [
            "running": pipeline.isRunning,
            "steps": steps,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) { return str }
        return "{}"
    }

    func cancelDbSetup() {
        Task { await dbSetupRunner?.cancel() }
        dbResetRunning = false
    }

    func dismissDbSetup() {
        dbSetupPipeline = nil
    }

    func dismissMigrationsBanner() {
        migrationsBannerVisible = false
    }

    // MARK: - Private: LAN-Aware Definition

    private func lanAwareDefinition(for definition: ServiceDefinition, serviceID: String) -> ServiceDefinition {
        guard networkMode, let ip = localIP else { return definition }
        let lanServices: Set<String> = ["travel-portal", "universal-login", "partner-portal"]
        guard lanServices.contains(serviceID) else { return definition }

        let cmd: String
        if serviceID == "partner-portal" {
            cmd = "npm run dev -- -p 3001 --hostname \(ip)"
        } else {
            cmd = "npm run dev -- --hostname \(ip)"
        }
        var envOverrides = definition.env ?? [:]

        if serviceID == "universal-login" {
            envOverrides["NEXT_PUBLIC_SITE_URL"] = "http://\(ip):3000"
            envOverrides["NEXT_PUBLIC_AMATEUR_LOCAL_UNIVERSAL_LOGIN_URL"] = "http://\(ip):3000"
            envOverrides["NEXT_PUBLIC_SUPABASE_URL"] = "http://\(ip):54321"
        }
        if serviceID == "travel-portal" {
            envOverrides["LOGIN_URL"] = "http://\(ip):3000/login/init"
            envOverrides["NEXT_PUBLIC_WEBAPP_URL"] = "http://\(ip):3002"
            envOverrides["NEXT_PUBLIC_SUPABASE_URL"] = "http://\(ip):54321"
        }
        if serviceID == "partner-portal",
           let rawPartner = config?.paths?.partnerPortal, !rawPartner.isEmpty {
            let partnerPath = NSString(string: rawPartner).expandingTildeInPath
            let baselinePath = (partnerPath as NSString).appendingPathComponent(".env.local.runner")
            let source = readEnvFile(baselinePath)
            for (key, value) in source where value.contains("localhost") {
                envOverrides[key] = value.replacingOccurrences(of: "localhost", with: ip)
            }
        }

        var lanProbe = definition.probe
        if let probe = lanProbe, probe.type == .tcp {
            lanProbe = ProbeConfig(
                type: probe.type,
                port: probe.port,
                host: ip,
                url: probe.url,
                pattern: probe.pattern,
                artifact: probe.artifact,
                timeout: probe.timeout
            )
        }

        return ServiceDefinition(
            id: definition.id,
            name: definition.name,
            cmd: cmd.components(separatedBy: " "),
            cwd: definition.cwd,
            probe: lanProbe,
            type: definition.type,
            restart: definition.restart,
            dependsOn: definition.dependsOn,
            env: envOverrides,
            phase: definition.phase,
            reuseIfRunning: definition.reuseIfRunning
        )
    }

    // MARK: - Private: Service Lifecycle

    private func startService(_ serviceID: String) async throws {
        guard !isShuttingDown, health != .stopped else { return }
        guard let state = serviceStates[serviceID],
              let definition = graph?.nodes[serviceID] else { return }

        if serviceID == "partner-portal" && !partnerPortalEnabled {
            await MainActor.run { state.phase = .skipped }
            return
        }

        // Reuse-if-running: Docker-managed services (Supabase) persist between sessions.
        // If the port is already bound, skip starting and mark as running.
        if definition.shouldReuseIfRunning, let port = definition.probe?.port {
            if isPortBound(port) {
                await MainActor.run {
                    state.phase = .running
                    state.lastStarted = .now
                }
                return
            }
        }

        // Skip Stripe if the CLI isn't installed or authenticated
        if serviceID == "stripe" {
            let available = await isStripeAvailable()
            if !available {
                await MainActor.run {
                    state.phase = .skipped
                }
                await logStore.append(
                    serviceID: serviceID,
                    entry: LogEntry(stream: .stdout, text: "[travel-runner] Stripe CLI not available — skipping")
                )
                return
            }
        }

        // For non-reuse services, kill any stale occupant on the port
        if !definition.shouldReuseIfRunning, let port = definition.probe?.port, definition.resolvedType == .daemon {
            if isPortBound(port) {
                await killPortOccupants(port)
                for _ in 0..<10 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if !isPortBound(port) { break }
                }
            }
        }

        // If this is the portal and Stripe is configured + available, wait for the
        // Stripe secret before starting. This ensures .env.local has the correct
        // STRIPE_WEBHOOK_SECRET when Node boots. Skip if Stripe isn't set up.
        if serviceID == "travel-portal",
           let stripeService = graph?.nodes["stripe"],
           stripeService.probe?.artifact != nil {
            let stripeAvailable = await isStripeAvailable()
            if stripeAvailable {
                await MainActor.run {
                    state.phase = .starting
                    state.lastStarted = .now
                }
                // Wait up to 30s for Stripe to capture its secret
                for _ in 0..<60 {
                    if let _ = await secretStore.get("STRIPE_WEBHOOK_SECRET") { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }

        await MainActor.run {
            state.phase = .starting
            state.lastStarted = .now
            state.exitCode = nil
        }

        var stdoutProbe: StdoutProbe?
        if case .stdoutRegex = definition.probe?.type {
            stdoutProbe = StdoutProbe(pattern: definition.probe!.pattern!)
            stdoutProbes[serviceID] = stdoutProbe
        }

        let logStore = self.logStore
        let secretStore = self.secretStore
        let artifactName = definition.probe?.artifact
        let capturedProbe = stdoutProbe
        let effectiveDefinition = lanAwareDefinition(for: definition, serviceID: serviceID)

        let sid = serviceID
        let pid = try await processRunner.start(
            service: effectiveDefinition,
            onStdout: { [weak self] lines in
                Task {
                    let entries = lines.map { LogEntry(stream: .stdout, text: $0) }
                    await logStore.appendBatch(serviceID: sid, entries: entries)
                    if let probe = capturedProbe {
                        for line in lines {
                            if let captured = probe.feed(line: line), let name = artifactName {
                                await secretStore.set(name, value: captured)
                            }
                        }
                    }
                    if sid == "stripe" {
                        for line in lines {
                            if line.contains("Session expired, reconnecting") {
                                await MainActor.run {
                                    if self?.stripeReconnectingSince == nil {
                                        self?.stripeReconnectingSince = .now
                                    }
                                    if let since = self?.stripeReconnectingSince,
                                       Date.now.timeIntervalSince(since) > 120 {
                                        self?.stripeReconnectingSince = nil
                                        self?.restartService("stripe")
                                    }
                                }
                            } else if line.contains("-->") {
                                await MainActor.run { self?.stripeReconnectingSince = nil }
                            }
                        }
                    }
                }
            },
            onStderr: { lines in
                Task {
                    let entries = lines.map { LogEntry(stream: .stderr, text: $0) }
                    await logStore.appendBatch(serviceID: sid, entries: entries)
                    if let probe = capturedProbe {
                        for line in lines {
                            if let captured = probe.feed(line: line), let name = artifactName {
                                await secretStore.set(name, value: captured)
                            }
                        }
                    }
                }
            },
            onTermination: { [weak self] exitCode in
                Task { @MainActor in self?.handleTermination(serviceID: sid, exitCode: exitCode) }
            }
        )

        await MainActor.run { state.pid = pid }

        // Oneshots: wait for exit
        if definition.resolvedType == .oneshot {
            while true {
                let phase = await MainActor.run { state.phase }
                if phase == .completed { return }
                if phase == .failed {
                    throw ServiceError.oneshotFailed(serviceID)
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }

        // Daemons: wait for probe (use effectiveDefinition for LAN-aware host)
        if let probeConfig = effectiveDefinition.probe {
            let probe: Probe = if let sp = capturedProbe { sp } else { ProbeFactory.makeProbe(for: probeConfig) }
            let timeout = probeConfig.resolvedTimeout
            let ready = try await waitForProbe(probe, timeout: timeout)
            if !ready {
                throw ServiceError.probeTimeout(serviceID, seconds: probeConfig.timeout ?? 120)
            }
        }

        // If this service produces an artifact (e.g. Stripe secret), ensure it's
        // written to .env.local BEFORE we mark the service as running and unblock
        // dependents. The onChange observer fires async, so we do a direct write here.
        if let name = artifactName {
            // Brief wait for the async secretStore.set() Task to complete
            try? await Task.sleep(for: .milliseconds(200))
            if let value = await secretStore.get(name) {
                envCompat?.write(key: name, value: value)
                await MainActor.run { state.capturedArtifact = value }
            }
        }

        await MainActor.run {
            state.phase = .running
        }
    }

    private func handleTermination(serviceID: String, exitCode: Int32) {
        guard let state = serviceStates[serviceID] else { return }

        // During shutdown, don't overwrite the .stopped/.stopping state
        if isShuttingDown || state.phase == .stopping || state.phase == .stopped {
            return
        }

        if state.definition.resolvedType == .oneshot {
            state.phase = exitCode == 0 ? .completed : .failed
            state.exitCode = exitCode
        } else {
            state.phase = exitCode == 0 ? .stopped : .failed
            state.exitCode = exitCode
            state.lastStopped = .now

            if exitCode != 0 {
                state.failureTimestamps.append(.now)
                if !isShuttingDown && !state.isCircuitBroken {
                    onServiceCrash?(state.definition.displayName, exitCode)
                    Task { await captureDebugIssue(
                        trigger: "service_crash",
                        serviceID: serviceID,
                        summary: "\(state.definition.displayName) exited with code \(exitCode)"
                    )}
                }
            }

            if state.definition.resolvedRestart == .onFailure && exitCode != 0 {
                let earlyExit = state.lastStarted.map { Date.now.timeIntervalSince($0) < 10 } ?? false
                scheduleRestart(serviceID: serviceID, wasEarlyExit: earlyExit)
            }
            recalculateHealth()
        }
    }

    private func scheduleRestart(serviceID: String, wasEarlyExit: Bool = false) {
        guard let state = serviceStates[serviceID] else { return }

        let cutoff = Date.now.addingTimeInterval(-60)
        state.failureTimestamps.removeAll { $0 < cutoff }
        if state.failureTimestamps.count >= 3 {
            state.isCircuitBroken = true
            lastError = "\(state.definition.displayName) is crash-looping — auto-restart stopped"
            Task { await captureDebugIssue(
                trigger: "circuit_breaker",
                serviceID: serviceID,
                summary: "\(state.definition.displayName) crash-looping — circuit breaker tripped"
            )}
            return
        }

        guard state.restartCount < 5 else { return }

        let baseDelay = min(2.0 * pow(2.0, Double(state.restartCount)), 60.0)
        let delay = (serviceID == "stripe" && wasEarlyExit) ? max(baseDelay, 15.0) : baseDelay
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard serviceStates[serviceID]?.phase == .failed else { return }

            if serviceID == "stripe" {
                let networkReady = await waitForNetwork(timeout: .seconds(15))
                guard networkReady else { return }
            }

            state.restartCount += 1
            restartService(serviceID)
        }
    }

    // MARK: - Private: Health

    func recalculateHealth() {
        let daemonStates = serviceStates.values
            .filter { $0.definition.resolvedType != .oneshot }
            .map(\.phase)

        if daemonStates.allSatisfy({ $0 == .stopped || $0 == .pending }) {
            health = .stopped
        } else if daemonStates.contains(.failed) {
            health = .degraded
        } else if daemonStates.allSatisfy({ $0 == .running || $0 == .completed || $0 == .skipped }) {
            health = .healthy
        } else {
            health = .starting
        }

        if health == .degraded {
            let failedIDs = serviceStates.filter { $0.value.phase == .failed }.map(\.key)
            rootCauseServiceID = failedIDs.first { serviceID in
                let deps = graph?.nodes[serviceID]?.dependsOn ?? []
                return deps.allSatisfy { depID in
                    serviceStates[depID]?.phase != .failed
                }
            }
        } else {
            rootCauseServiceID = nil
        }
    }

    private func handleWake() {
        guard health == .healthy || health == .degraded else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            for (serviceID, state) in serviceStates where state.phase == .running {
                guard let probeConfig = state.definition.probe,
                      probeConfig.type != .stdoutRegex else { continue }
                let probe = ProbeFactory.makeProbe(for: probeConfig)
                let ok = await probe.check()
                if !ok {
                    state.phase = .failed
                    recalculateHealth()
                    scheduleRestart(serviceID: serviceID)
                    Task { await self.captureDebugIssue(
                        trigger: "probe_timeout",
                        serviceID: serviceID,
                        summary: "\(state.definition.displayName) failed wake probe"
                    )}
                }
            }

            // Stripe's WebSocket is guaranteed stale after sleep — proactively restart
            // rather than waiting for the CLI to detect the failure and crash.
            if let stripeState = serviceStates["stripe"],
               stripeState.phase == .running || stripeState.phase == .failed {
                await logStore.append(
                    serviceID: "stripe",
                    entry: LogEntry(stream: .stdout, text: "[travel-runner] Restarting Stripe after wake — waiting for network...")
                )

                let networkReady = await waitForNetwork(timeout: .seconds(30))
                if networkReady {
                    stripeState.restartCount = 0
                    stripeState.isCircuitBroken = false
                    stripeState.failureTimestamps = []
                    restartService("stripe")
                } else {
                    stripeState.phase = .failed
                    lastError = "Stripe: network not available after wake"
                    recalculateHealth()
                    Task { await self.captureDebugIssue(
                        trigger: "probe_timeout",
                        serviceID: "stripe",
                        summary: "Network not available 30s after wake — Stripe restart deferred"
                    )}
                }
            }
        }
    }

    // MARK: - Debug Tracking

    private func initDebugTracking() async {
        let tracker = DebugTracker()
        let enabled = await tracker.isEnabled()
        debugTracker = enabled ? tracker : nil
        debugTrackingEnabled = enabled
        debugOpenIssueCount = enabled ? await tracker.openIssueCount() : 0

        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                let tracker = DebugTracker()
                let enabled = await tracker.isEnabled()
                let count = enabled ? await tracker.openIssueCount() : 0
                await MainActor.run {
                    self.debugTrackingEnabled = enabled
                    self.debugOpenIssueCount = count
                    self.debugTracker = enabled ? tracker : nil
                }
            }
        }
    }

    func captureDebugIssue(
        trigger: String,
        serviceID: String?,
        summary: String,
        errorMessage: String? = nil,
        recoveryGuidance: String? = nil
    ) async {
        guard let tracker = debugTracker else { return }

        let snapshots = serviceStates.values.map { state in
            ServiceStateSnapshot(
                id: state.id,
                phase: state.phase.rawValue,
                pid: state.pid,
                exitCode: state.exitCode,
                restartCount: state.restartCount,
                isCircuitBroken: state.isCircuitBroken,
                uptimeSeconds: state.lastStarted.map { Int(Date.now.timeIntervalSince($0)) }
            )
        }

        var logEntries: [DebugTracker.LogEntry] = []
        if let sid = serviceID {
            let raw = await logStore.entries(for: sid)
            logEntries = raw.map { DebugTracker.LogEntry(timestamp: $0.timestamp, serviceId: sid, line: $0.text) }
        }

        let _ = await tracker.captureIssue(
            trigger: trigger,
            serviceId: serviceID,
            errorMessage: errorMessage ?? summary,
            logEntries: logEntries,
            stateSnapshots: snapshots
        )

        debugOpenIssueCount = await tracker.openIssueCount()
    }

    // MARK: - Private: Helpers

    private func resolvePhase(for serviceIDs: [String]) -> StartupPhase {
        for id in serviceIDs {
            if let phase = graph?.nodes[id]?.phase {
                switch phase {
                case "ground": return .ground
                case "gateway": return .gateway
                case "portal": return .portal
                default: break
                }
            }
        }
        // Fallback heuristic
        let ids = Set(serviceIDs)
        if ids.contains("supabase") || ids.contains("db-reset") { return .ground }
        if ids.contains("yalc-link") || ids.contains("universal-login") || ids.contains("stripe") { return .gateway }
        if ids.contains("travel-portal") { return .portal }
        return .running
    }

    func serviceCwd(_ serviceID: String) -> String? {
        graph?.nodes[serviceID]?.resolvedCwd
    }

    /// Grouped services by phase for the UI
    func servicesByPhase() -> [(phase: String, services: [ServiceState])] {
        let phases = ["ground", "gateway", "portal"]
        var groups: [(phase: String, services: [ServiceState])] = []

        for phase in phases {
            let ids = sortedServiceIDs.filter { id in
                if let p = graph?.nodes[id]?.phase { return p == phase }
                // Fallback
                switch phase {
                case "ground": return id == "supabase" || id == "db-reset"
                case "gateway": return id == "yalc-link" || id == "universal-login" || id == "stripe"
                case "portal": return id == "travel-portal" || id == "partner-portal"
                default: return false
                }
            }
            let states = ids.compactMap { serviceStates[$0] }
            if !states.isEmpty {
                groups.append((phase: phase.uppercased(), services: states))
            }
        }

        return groups
    }

    private func runShellCommand(_ command: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    private func isStripeAvailable() async -> Bool {
        await runShellCommand("which stripe >/dev/null 2>&1 && stripe config --list >/dev/null 2>&1")
    }

    private func canReachHost(_ host: String) async -> Bool {
        await runShellCommand("nc -z -w 2 \(host) 443 >/dev/null 2>&1")
    }

    private func waitForNetwork(timeout: Duration = .seconds(30)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await canReachHost("api.stripe.com") { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    private func databaseHasAppTables(portalCwd: String) async -> Bool {
        let projectId = URL(fileURLWithPath: portalCwd).lastPathComponent
        let container = "supabase_db_\(projectId)"
        let query = "SELECT count(*) FROM pg_tables WHERE schemaname = 'public'"
        let command = "docker exec \(container) psql -U postgres -d postgres -tAc \"\(query)\" 2>/dev/null"
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                guard proc.terminationStatus == 0 else {
                    continuation.resume(returning: false)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                let count = Int(output) ?? 0
                continuation.resume(returning: count > 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    private func runDbReset(cwd: String) async -> Bool {
        let logStore = self.logStore
        // Use db:setup --reset-only which runs migrations + seed + reloads cached hotel data.
        // Plain `npx supabase db reset` only does migrations + seed, skipping the hotel dump.
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "npm run db:setup -- --reset-only"]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let lineBuffer = TerminalLineBuffer()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in lineBuffer.feed(text) {
                    Task {
                        await logStore.append(serviceID: "db-reset", entry: LogEntry(stream: .stdout, text: line))
                    }
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let remaining = lineBuffer.flush() {
                    Task { await logStore.append(serviceID: "db-reset", entry: LogEntry(stream: .stdout, text: remaining)) }
                }
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }

    private func isPortBound(_ port: Int) -> Bool {
        if isPortBoundOnAddress(port, address: UInt32(INADDR_LOOPBACK).bigEndian) { return true }
        if let ip = localIP {
            var lanAddr = in_addr()
            if inet_pton(AF_INET, ip, &lanAddr) == 1 {
                if isPortBoundOnAddress(port, address: lanAddr.s_addr) { return true }
            }
        }
        return false
    }

    private func isPortBoundOnAddress(_ port: Int, address: UInt32) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = address

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    private func killPortOccupants(_ port: Int) async {
        _ = await runShellCommand("lsof -ti :\(port) | xargs kill -9 2>/dev/null")
    }

    /// Kill any stale processes from a previous session before starting the DAG.
    /// Skips ports belonging to reuse_if_running services (e.g. Docker-managed Supabase).
    private func cleanupStaleProcesses() async {
        guard let config else { return }

        // Kill by port — only non-reuse services (skip Docker-managed ports)
        let killablePorts = config.services
            .filter { !$0.shouldReuseIfRunning }
            .compactMap { $0.probe?.port }

        var didKill = false
        for port in killablePorts {
            if isPortBound(port) {
                await killPortOccupants(port)
                didKill = true
            }
        }

        // Kill known command patterns that shouldn't be running outside of us
        let patterns = ["stripe listen"]
        for pattern in patterns {
            _ = await runShellCommand("pkill -f '\(pattern)' 2>/dev/null")
        }

        if didKill {
            try? await Task.sleep(for: .milliseconds(500))
        }
    }
}
