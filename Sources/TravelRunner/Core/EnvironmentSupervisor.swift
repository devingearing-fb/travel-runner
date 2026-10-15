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
    var dbSeedScenarios: [DbSeedScenario] = []
    var selectedDbSeedScenarioID: String?
    var dbSeedScenarioLoadError: String?

    var selectedDbSeedScenario: DbSeedScenario? {
        guard let selectedDbSeedScenarioID else { return nil }
        return dbSeedScenarios.first { $0.id == selectedDbSeedScenarioID }
    }
    var networkMode = false
    var localIP: String? = nil
    var panelVisible = false
    var rootCauseServiceID: String? = nil
    var phaseTimings: [String: TimeInterval] = [:]
    var onServiceCrash: (@MainActor (String, Int32) -> Void)? = nil
    var debugTrackingEnabled = false
    var debugOpenIssueCount = 0
    var actionsInFlight: Set<String> = []
    var onActionFeedback: ((String, Bool) -> Void)?
    var gitBranches: [String: String] = [:]
    var gitBehindCounts: [String: Int] = [:]
    var behindBannerDismissed = false
    var npmStaleServices: Set<String> = []
    var dbMode: DatabaseMode = .local
    /// Which part of the graph start-all brings up (stored in services.json).
    var profile: RunProfile = .both
    private(set) var profileMembers: Set<String> = []

    func isInProfile(_ serviceID: String) -> Bool { profileMembers.contains(serviceID) }

    enum DatabaseMode: String, Sendable { case local, remote }

    var totalBehindCount: Int {
        var seen = Set<String>()
        var total = 0
        for (sid, count) in gitBehindCounts where count > 0 {
            // Count each repository once: in the monorepo several services share one.
            let path = gitRepoRoots[sid] ?? config?.services.first(where: { $0.id == sid })?.resolvedCwd ?? sid
            if seen.insert(path).inserted {
                total += count
            }
        }
        return total
    }

    func dismissBehindBanner() {
        behindBannerDismissed = true
    }

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
    private var sleepWakeObserver: SleepWakeObserver?
    private var startTask: Task<Void, any Error>?
    private var config: ServiceConfig?
    private var isShuttingDown = false
    private let userDefaults: UserDefaults
    private var stdoutProbes: [String: StdoutProbe] = [:]
    private var observerRegistered = false
    private var phaseStartedAt: Date? = nil
    private var dbSetupRunner: DbSetupRunner?
    private var debugTracker: DebugTracker?
    private var gitBranchWatcher: GitBranchWatcher?
    private var gitRepoRoots: [String: String] = [:]
    private var dependencyWatcher: DependencyWatcher?
    private var gitWatcherTask: Task<Void, Never>?
    private var depsWatcherTask: Task<Void, Never>?
    private var isTogglingNetwork = false
    private var stripeReconnectingSince: Date? = nil
    private var localSupabaseKeys: LocalSupabaseKeys?
    private var stripeWebhookSecret: String?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.selectedDbSeedScenarioID = userDefaults.string(forKey: "dbSeedScenarioID")
    }

    // MARK: - Types

    enum StartupPhase: String, Sendable, CaseIterable {
        case idle = "IDLE"
        case preflight = "PREFLIGHT"
        case ground = "GROUND"
        case gateway = "GATEWAY"
        case portal = "PORTAL"
        case stream = "STREAM"
        case verification = "VERIFICATION"
        case running = "RUNNING"

        init?(configPhase: String) {
            switch configPhase {
            case "ground": self = .ground
            case "gateway": self = .gateway
            case "portal": self = .portal
            case "stream": self = .stream
            case "verification": self = .verification
            default: return nil
            }
        }

        /// Position in the startup sequence; used to pick a level's phase when a
        /// DAG level mixes services from more than one phase.
        var sortOrder: Int {
            switch self {
            case .idle: 0
            case .preflight: 1
            case .ground: 2
            case .gateway: 3
            case .portal: 4
            case .stream: 5
            case .verification: 6
            case .running: 7
            }
        }
    }

    enum ServiceError: Error, CustomStringConvertible {
        case oneshotFailed(String)
        case probeTimeout(String, seconds: Int)
        case portHeldByOtherStack(port: Int, container: String)

        var description: String {
            switch self {
            case .oneshotFailed(let id): "'\(id)' exited with non-zero status"
            case .probeTimeout(let id, let s): "'\(id)' health probe timed out after \(s)s"
            case .portHeldByOtherStack(let port, let container):
                "Port \(port) is held by another Supabase stack (\(container)) — stop it, then start again"
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
            self.profile = config.resolvedProfile
            self.profileMembers = config.resolvedProfile.members(of: config.services)

            for service in config.services {
                serviceStates[service.id] = ServiceState(definition: service)
            }

            reloadDbSeedScenarios()

            // Register secret observer once. It resolves paths at write time, so a
            // config reload (new monorepo path) needs no new observer.
            if !observerRegistered {
                observerRegistered = true
                Task {
                    await secretStore.onChange { [weak self] key, value in
                        Task { @MainActor in self?.recordArtifact(key, value: value) }
                    }
                }
            }

            sleepWakeObserver = SleepWakeObserver { [weak self] in
                self?.handleWake()
            }
            sleepWakeObserver?.startObserving()

            // Always reset .env.local files to localhost on startup. Keys from the
            // last block first; the running stack's keys replace them after GROUND.
            cacheLocalSupabaseKeys()
            resetEnvToLocalhost()

            // Start control API server
            startControlServer()

            // Initialize debug tracking (opt-in via ~/Desktop/debug-tracking/config.json)
            Task { await initDebugTracking() }

            // Initialize git branch watcher for all repos with cwds
            var repoMap: [String: String] = [:]
            for service in config.services {
                if let cwd = service.resolvedCwd {
                    repoMap[service.id] = cwd
                }
            }
            if !repoMap.isEmpty {
                let watcher = GitBranchWatcher(repos: repoMap)
                gitBranchWatcher = watcher
                gitRepoRoots = watcher.repoRoots
                gitWatcherTask?.cancel()
                gitWatcherTask = Task { await startGitBranchWatching(watcher: watcher) }
            }

            // Initialize dependency (npm install) freshness watcher
            var depsMap: [String: String] = [:]
            for service in config.services {
                if let cwd = service.resolvedCwd, service.resolvedType == .daemon {
                    depsMap[service.id] = cwd
                }
            }
            if !depsMap.isEmpty {
                let depsWatcher = DependencyWatcher(repoPaths: depsMap)
                dependencyWatcher = depsWatcher
                depsWatcherTask?.cancel()
                depsWatcherTask = Task { await startDepsWatching(watcher: depsWatcher) }
            }
        } catch ConfigLoader.ConfigError.noConfig {
            // First run — setup wizard will handle this
        } catch ConfigLoader.ConfigError.monorepoNotFound {
            // Old three-repo config with no monorepo nearby — setup wizard will handle this
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
                let profileServices = config.services.filter { self.isInProfile($0.id) }
                let checks = self.preflightRunner.allChecks(for: profileServices)
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
                    // Supabase is up: write its keys before any portal starts.
                    await self.refreshLocalSupabaseKeys()
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
                        let profile = await MainActor.run { self.profile.rawValue }
                        let dbMode = await MainActor.run { self.dbMode.rawValue }
                        let branches = await MainActor.run { self.gitBranches }
                        let behind = await MainActor.run { self.gitBehindCounts }
                        let npmStale = await MainActor.run { Array(self.npmStaleServices) }
                        let dict: [String: Any] = [
                            "health": health, "services": states, "lan": lan, "ip": ip,
                            "profile": profile,
                            "db_mode": dbMode,
                            "branches": branches,
                            "gitBehind": behind,
                            "npmStale": npmStale
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
                    toggleDbMode: { [weak self] in
                        await MainActor.run { self?.toggleDatabaseMode() }
                    },
                    getProfile: { [weak self] in
                        guard let self else { return "{}" }
                        let (name, members) = await MainActor.run { (self.profile.rawValue, self.profileMembers.sorted()) }
                        let dict: [String: Any] = [
                            "profile": name,
                            "services": members,
                            "available": RunProfile.allCases.map(\.rawValue),
                        ]
                        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                           let str = String(data: data, encoding: .utf8) { return str }
                        return "{}"
                    },
                    setProfile: { [weak self] name in
                        guard let profile = RunProfile(rawValue: name) else { return false }
                        await MainActor.run { self?.setProfile(profile) }
                        return true
                    }
                ),
                logStore: logStore
            )
        }
    }

    func resetEnvToLocalhost() {
        dbMode = .local
        writeAppEnv()
    }

    /// Writes the runner block into both apps' `.env.local` and the universal-login
    /// env for the current database mode and network mode.
    func writeAppEnv() {
        let host = networkMode ? (localIP ?? "localhost") : "localhost"
        let mode: RunnerEnv.Mode = dbMode == .local ? .local : .remote
        var hostedLoginURL: String?
        if mode == .remote, let booking = sharedEnvPath("travel-portal"), let partner = sharedEnvPath("partner-portal") {
            hostedLoginURL = RunnerEnv.hostedLoginURL(bookingEnv: booking, partnerEnv: partner)
        }
        for (app, serviceID) in [(RunnerEnv.App.booking, "travel-portal"), (.partner, "partner-portal")] {
            guard let cwd = graph?.nodes[serviceID]?.resolvedCwd else { continue }
            let values = RunnerEnv.values(
                for: app, mode: mode, host: host, keys: localSupabaseKeys,
                stripeWebhookSecret: stripeWebhookSecret,
                hostedLoginURL: app == .booking ? hostedLoginURL : nil
            )
            RunnerEnv.apply(path: (cwd as NSString).appendingPathComponent(".env.local"), app: app, values: values)
        }
        writeLoginEnv(host: host)
    }

    /// universal-login is an external repo; its `.env.local` keeps the key-by-key writes.
    private func writeLoginEnv(host: String) {
        guard let loginCwd = graph?.nodes["universal-login"]?.resolvedCwd else { return }
        let env = EnvCompatLayer(envFilePaths: [loginCwd + "/.env.local"])
        env.write(key: "NEXT_PUBLIC_SITE_URL", value: "http://\(host):3000")
        env.write(key: "NEXT_PUBLIC_AMATEUR_LOCAL_UNIVERSAL_LOGIN_URL", value: "http://\(host):3000")

        if dbMode == .local {
            env.write(key: "NEXT_PUBLIC_SUPABASE_URL", value: "http://\(host):54321")
            env.write(key: "AMATEUR_SUPABASE_URL", value: "http://\(host):54321")
            if let keys = localSupabaseKeys {
                env.write(key: "AMATEUR_SUPABASE_ANON_KEY", value: keys.anonKey)
                env.write(key: "NEXT_PUBLIC_SUPABASE_ANON_KEY", value: keys.anonKey)
                env.write(key: "AMATEUR_SUPABASE_SIGNING_KEY", value: keys.jwtSecret)
            }
        } else if let shared = sharedEnvPath("travel-portal"),
                  let url = RunnerEnv.value(of: "AMATEUR_SUPABASE_URL", inFile: shared) {
            // Hosted dev: the same project the booking portal's shared .env uses.
            env.write(key: "NEXT_PUBLIC_SUPABASE_URL", value: url)
            env.write(key: "AMATEUR_SUPABASE_URL", value: url)
            if let anon = RunnerEnv.value(of: "AMATEUR_SUPABASE_ANON_KEY", inFile: shared) {
                env.write(key: "AMATEUR_SUPABASE_ANON_KEY", value: anon)
                env.write(key: "NEXT_PUBLIC_SUPABASE_ANON_KEY", value: anon)
            }
            if let signing = RunnerEnv.value(of: "AMATEUR_SUPABASE_SIGNING_KEY", inFile: shared) {
                env.write(key: "AMATEUR_SUPABASE_SIGNING_KEY", value: signing)
            }
        }
    }

    /// The app's shared dev values in the monolith (`apps/<app>/.env`), when the file exists.
    /// It is a teammate's copy or `pnpm env:pull` output; the runner only reads it.
    private func sharedEnvPath(_ serviceID: String) -> String? {
        guard let cwd = graph?.nodes[serviceID]?.resolvedCwd else { return nil }
        let path = (cwd as NSString).appendingPathComponent(".env")
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// A secret captured from a service's output (the Stripe webhook secret).
    private func recordArtifact(_ name: String, value: String) {
        if name == "STRIPE_WEBHOOK_SECRET" {
            guard stripeWebhookSecret != value else { return }
            stripeWebhookSecret = value
            writeAppEnv()
        } else if let cwd = graph?.nodes["travel-portal"]?.resolvedCwd {
            EnvCompatLayer(envFilePaths: [cwd + "/.env.local"]).write(key: name, value: value)
        }
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

    /// Keys from the last runner block, so the env is right before Supabase reports in.
    private func cacheLocalSupabaseKeys() {
        guard let portalCwd = graph?.nodes["travel-portal"]?.resolvedCwd else { return }
        let envPath = (portalCwd as NSString).appendingPathComponent(".env.local")
        guard let anon = RunnerEnv.value(of: "LOCAL_SUPABASE_ANON_KEY", inFile: envPath),
              let secret = RunnerEnv.value(of: "LOCAL_SUPABASE_SIGNING_KEY", inFile: envPath) else { return }
        let partnerEnv = graph?.nodes["partner-portal"]?.resolvedCwd.map { ($0 as NSString).appendingPathComponent(".env.local") }
        localSupabaseKeys = LocalSupabaseKeys(
            anonKey: anon,
            serviceRoleKey: RunnerEnv.value(of: "SUPABASE_SERVICE_ROLE_KEY", inFile: envPath) ?? "",
            jwtSecret: secret,
            publishableKey: partnerEnv.flatMap { RunnerEnv.value(of: "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY", inFile: $0) }
        )
        stripeWebhookSecret = RunnerEnv.value(of: "STRIPE_WEBHOOK_SECRET", inFile: envPath)
    }

    /// Reads the keys of the running local stack and rewrites the env when they changed.
    func refreshLocalSupabaseKeys() async {
        guard let root = graph?.nodes["supabase"]?.resolvedCwd else { return }
        let (output, ok) = await shellOutput("cd \(ShellQuote.quote(root)) && scripts/local-db.sh status -o env 2>/dev/null")
        guard ok, let keys = LocalSupabaseKeys.parse(statusEnv: output) else {
            await logStore.append(serviceID: "supabase", entry: LogEntry(
                stream: .stderr, text: "[travel-runner] Could not read local Supabase keys (scripts/local-db.sh status -o env)"
            ))
            return
        }
        if keys != localSupabaseKeys {
            localSupabaseKeys = keys
            writeAppEnv()
        }
    }

    func toggleDatabaseMode() {
        guard health == .healthy || health == .stopped else {
            lastError = "Cannot switch database while services are starting"
            return
        }

        if dbMode == .local {
            // Hosted dev comes from each app's shared .env; the runner block then stops
            // overriding Supabase.
            let apps = ["travel-portal"] + (isInProfile("partner-portal") ? ["partner-portal"] : [])
            let lacking = apps.filter { serviceID in
                guard let shared = sharedEnvPath(serviceID),
                      let url = RunnerEnv.value(of: "AMATEUR_SUPABASE_URL", inFile: shared) else { return true }
                return url.isEmpty
            }
            guard lacking.isEmpty else {
                let files = lacking.map { $0 == "travel-portal" ? "apps/booking-portal/.env" : "apps/partner-portal/.env" }
                lastError = "Hosted dev values are missing from \(files.joined(separator: " and ")) — import the shared file (Health → App env files), then switch again"
                return
            }
            dbMode = .remote
            writeAppEnv()
        } else {
            resetEnvToLocalhost()
        }

        guard health != .stopped else { return }

        var servicesToRestart = ["travel-portal", "universal-login"]
        if isInProfile("partner-portal") {
            servicesToRestart.append("partner-portal")
        }
        Task {
            actionsInFlight.insert("db-mode")
            defer { actionsInFlight.remove("db-mode") }
            var switchFailed = false
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
                    switchFailed = true
                }
            }
            recalculateHealth()
            if switchFailed {
                onActionFeedback?("Database mode switch hit errors — check Status", false)
            } else {
                onActionFeedback?("Database mode: \(dbMode == .local ? "local" : "dev")", true)
            }
        }
    }

    func toggleNetworkMode() {
        guard !isTogglingNetwork else { return }
        networkMode.toggle()
        applyNetworkMode()
    }

    /// Applies the current `networkMode` to env files and restarts LAN services.
    /// Re-detects the LAN IP on every call, so it is also used to recover when
    /// the machine moves networks (stale IP causes EADDRNOTAVAIL on restart).
    func applyNetworkMode() {
        guard !isTogglingNetwork else { return }
        isTogglingNetwork = true
        let mode = networkMode

        Task {
            actionsInFlight.insert("lan-mode")
            defer {
                isTogglingNetwork = false
                actionsInFlight.remove("lan-mode")
            }

            if mode {
                let (output, ok) = await shellOutput("ipconfig getifaddr en0")
                localIP = ok ? output.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            } else {
                localIP = nil
            }

            let ip = localIP ?? "127.0.0.1"
            writeAppEnv()

            var servicesToRestart = ["travel-portal", "universal-login"]
            if isInProfile("partner-portal") {
                servicesToRestart.append("partner-portal")
            }

            for serviceID in servicesToRestart {
                serviceStates[serviceID]?.phase = .stopping
            }

            var restartFailed = false
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
                    restartFailed = true
                }
            }

            recalculateHealth()
            if restartFailed {
                onActionFeedback?("LAN mode toggle hit errors — check Status", false)
            } else {
                onActionFeedback?(mode ? "LAN mode on — \(ip)" : "LAN mode off — localhost only", true)
            }
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
        let name = serviceStates[serviceID]?.definition.displayName ?? serviceID
        Task {
            actionsInFlight.insert(serviceID)
            defer { actionsInFlight.remove(serviceID) }
            serviceStates[serviceID]?.phase = .stopping
            await processRunner.stop(serviceID: serviceID)
            serviceStates[serviceID]?.phase = .pending
            serviceStates[serviceID]?.restartCount = 0
            serviceStates[serviceID]?.isCircuitBroken = false
            serviceStates[serviceID]?.failureTimestamps = []
            try? await Task.sleep(for: .seconds(1))
            do {
                try await startService(serviceID)
                onActionFeedback?("\(name) restarted", true)
            } catch {
                serviceStates[serviceID]?.phase = .failed
                lastError = "\(error)"
                recalculateHealth()
                onActionFeedback?("\(name) restart failed", false)
            }
        }
    }

    func restartCascade(_ serviceID: String) {
        guard let graph else { return }
        let dependents = graph.dependents(of: serviceID)
        let allAffected = dependents.union([serviceID])
        let topoOrder = graph.sortedIDs.filter { allAffected.contains($0) }
        let name = serviceStates[serviceID]?.definition.displayName ?? serviceID

        Task {
            for id in topoOrder { actionsInFlight.insert(id) }
            defer { for id in topoOrder { actionsInFlight.remove(id) } }
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
                    onActionFeedback?("Cascade restart failed at \(id)", false)
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
            onActionFeedback?("\(name) restarted with dependents", true)
        }
    }

    func retryStartAll() {
        preflightChecks = []
        completedPhases = []
        lastError = nil
        startAll()
    }

    /// Switches the profile and saves it to services.json. Running services outside the
    /// new profile keep running until the next stop; start-all uses the new profile.
    func setProfile(_ newProfile: RunProfile) {
        do {
            try ConfigLoader.saveProfile(newProfile)
        } catch {
            lastError = "Could not save profile: \(error)"
            return
        }
        profile = newProfile
        profileMembers = newProfile.members(of: config?.services ?? [])
        onActionFeedback?("Profile: \(newProfile.displayName)", true)
    }

    private func startDepsWatching(watcher: DependencyWatcher) async {
        while !Task.isCancelled {
            let stale = await watcher.check()
            await MainActor.run { self.npmStaleServices = stale }
            try? await Task.sleep(for: .seconds(30))
        }
    }

    private func startGitBranchWatching(watcher: GitBranchWatcher) async {
        _ = await watcher.check()
        await watcher.fetchAndCount(fetchInterval: 0)
        let initial = await watcher.branches
        let initialBehind = await watcher.behindCounts
        await MainActor.run {
            self.gitBranches = initial
            self.gitBehindCounts = initialBehind
        }

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            let changed = await watcher.check()
            await watcher.fetchAndCount()
            let allBranches = await watcher.branches
            let allBehind = await watcher.behindCounts
            let prevBehind = await MainActor.run { self.gitBehindCounts }
            await MainActor.run {
                self.gitBranches = allBranches
                if allBehind != prevBehind {
                    self.gitBehindCounts = allBehind
                    self.behindBannerDismissed = false
                }
            }

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

            await watcher.fetchAndCount(fetchInterval: 0)
            let freshBehind = await watcher.behindCounts
            await MainActor.run {
                self.gitBehindCounts = freshBehind
                self.behindBannerDismissed = false
            }

            let runningChanged = changed.filter { serviceStates[$0]?.phase == .running }
            for serviceID in runningChanged {
                restartService(serviceID)
            }
        }
    }

    func reloadDbSeedScenarios() {
        guard let cwd = config?.services.first(where: { $0.id == "supabase" })?.resolvedCwd else {
            dbSeedScenarios = []
            dbSeedScenarioLoadError = "Cannot load seed scenarios because the Supabase service directory is unavailable."
            return
        }

        let manifestPath = (cwd as NSString).appendingPathComponent("scripts/db/manifest.json")
        let savedID: String? = userDefaults.object(forKey: "dbSeedScenarioID") == nil
            ? nil
            : (userDefaults.string(forKey: "dbSeedScenarioID") ?? "")

        do {
            let catalog = try DbManifestLoader.loadSeedScenarios(from: manifestPath)
            dbSeedScenarios = catalog.items
            do {
                let resolvedID = try DbSeedScenarioSelection.resolve(
                    catalog: catalog,
                    savedID: savedID
                )
                selectedDbSeedScenarioID = resolvedID
                if savedID == nil {
                    userDefaults.set(resolvedID, forKey: "dbSeedScenarioID")
                }
                dbSeedScenarioLoadError = nil
            } catch {
                selectedDbSeedScenarioID = savedID
                dbSeedScenarioLoadError = error.localizedDescription
            }
        } catch {
            dbSeedScenarios = []
            selectedDbSeedScenarioID = savedID
            dbSeedScenarioLoadError = "Seed scenarios cannot be loaded: \(error.localizedDescription)"
        }
    }

    func selectDbSeedScenario(_ id: String) {
        guard !dbResetRunning, dbSetupPipeline?.isRunning != true else { return }
        guard dbSeedScenarios.contains(where: { $0.id == id }) else {
            dbSeedScenarioLoadError = "Seed scenario ‘\(id)’ is not available. Reload the current branch and choose an available scenario."
            return
        }
        selectedDbSeedScenarioID = id
        userDefaults.set(id, forKey: "dbSeedScenarioID")
        dbSeedScenarioLoadError = nil
    }

    func resetDatabase(profile: String = "reset") {
        runDbSetup(profile: profile)
    }

    func runDbSetup(from stepId: String? = nil, profile: String = "reset") {
        guard !dbResetRunning, dbSetupPipeline?.isRunning != true else { return }
        guard let cwd = config?.services.first(where: { $0.id == "supabase" })?.resolvedCwd else {
            lastError = "Cannot find supabase service cwd in config"
            return
        }

        let pipeline: DbSetupPipeline
        if stepId != nil, let existingPipeline = dbSetupPipeline {
            pipeline = existingPipeline
        } else {
            guard let newPipeline = makeDbSetupPipeline(cwd: cwd, profile: profile) else { return }
            dbSetupPipeline = newPipeline
            pipeline = newPipeline
        }

        dbResetRunning = true
        migrationsBannerVisible = false
        lastError = nil

        let runner = DbSetupRunner(
            portalCwd: cwd,
            logStore: logStore,
            seedScenarioID: pipeline.seedScenario.id
        )
        dbSetupRunner = runner

        Task {
            await runner.run(pipeline: pipeline, from: stepId)
            dbResetRunning = false
            if pipeline.allRequiredPassed {
                migrationTracker.recordCurrentHash(portalCwd: cwd)
                lastError = nil
                await refreshLocalSupabaseKeys()
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
        guard !dbResetRunning, dbSetupPipeline?.isRunning != true else { return }
        guard let cwd = config?.services.first(where: { $0.id == "supabase" })?.resolvedCwd else {
            lastError = "Cannot find supabase service cwd in config"
            return
        }

        if dbSetupPipeline == nil {
            guard let pipeline = makeDbSetupPipeline(cwd: cwd, profile: "full") else { return }
            dbSetupPipeline = pipeline
        }

        guard let pipeline = dbSetupPipeline,
              let step = pipeline.steps.first(where: { $0.id == stepId }) else { return }

        let runner = DbSetupRunner(
            portalCwd: cwd,
            logStore: logStore,
            seedScenarioID: pipeline.seedScenario.id
        )
        dbSetupRunner = runner
        dbResetRunning = true
        lastError = nil

        Task {
            let success = await runner.executeStepPublic(step)
            dbResetRunning = false
            if !success {
                lastError = "DB setup failed at \(step.name): \(step.errorMessage ?? "unknown error")"
            }
        }
    }

    func dbSetupStatusJSON() -> String {
        let pipeline = dbSetupPipeline
        var steps: [[String: Any]] = []
        for step in pipeline?.steps ?? [] {
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

        func scenarioMetadata(_ scenario: DbSeedScenario?) -> Any {
            guard let scenario else { return NSNull() }
            return [
                "id": scenario.id,
                "name": scenario.name,
                "description": scenario.description,
                "fileSummary": scenario.fileSummary,
            ]
        }

        let result: [String: Any] = [
            "running": pipeline?.isRunning ?? false,
            "profile": pipeline.map { $0.profile as Any } ?? NSNull(),
            "selectedSeedScenario": scenarioMetadata(selectedDbSeedScenario),
            "activeSeedScenario": scenarioMetadata(pipeline?.seedScenario),
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

    private func streamAwareDefinition(
        for definition: ServiceDefinition,
        serviceID: String
    ) -> ServiceDefinition {
        // The local CDC chain always runs against the local stack.
        guard serviceID == "stream-services", let keys = localSupabaseKeys else {
            return definition
        }
        var envOverrides = definition.env ?? [:]
        envOverrides["AMATEUR_SUPABASE_URL"] = "http://127.0.0.1:54321"
        envOverrides["AMATEUR_SUPABASE_ANON_KEY"] = keys.anonKey
        envOverrides["AMATEUR_SUPABASE_SIGNING_KEY"] = keys.jwtSecret
        return ServiceDefinition(
            id: definition.id,
            name: definition.name,
            cmd: definition.cmd,
            cwd: definition.cwd,
            probe: definition.probe,
            type: definition.type,
            restart: definition.restart,
            dependsOn: definition.dependsOn,
            env: envOverrides,
            phase: definition.phase,
            reuseIfRunning: definition.reuseIfRunning
        )
    }

    /// The service's own command with `--hostname <ip>` appended, so LAN mode keeps the
    /// configured package manager and port. `npm run` needs `--` before script flags;
    /// pnpm passes trailing flags to the script.
    nonisolated static func lanCommand(_ cmd: [String], ip: String) -> [String] {
        let needsSeparator = cmd.first == "npm" && cmd.dropFirst().first == "run" && !cmd.contains("--")
        return cmd + (needsSeparator ? ["--"] : []) + ["--hostname", ip]
    }

    private func lanAwareDefinition(for definition: ServiceDefinition, serviceID: String) -> ServiceDefinition {
        guard networkMode, let ip = localIP else { return definition }
        let lanServices: Set<String> = ["travel-portal", "universal-login", "partner-portal"]
        guard lanServices.contains(serviceID) else { return definition }

        let cmd = Self.lanCommand(definition.cmd, ip: ip)
        var envOverrides = definition.env ?? [:]

        // The portals get their LAN URLs from the runner block in .env.local
        // (applyNetworkMode rewrites it before the restart). universal-login is an
        // external repo, so it also gets them as process env.
        if serviceID == "universal-login" {
            envOverrides["NEXT_PUBLIC_SITE_URL"] = "http://\(ip):3000"
            envOverrides["NEXT_PUBLIC_AMATEUR_LOCAL_UNIVERSAL_LOGIN_URL"] = "http://\(ip):3000"
            if dbMode == .local {
                envOverrides["NEXT_PUBLIC_SUPABASE_URL"] = "http://\(ip):54321"
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
        } else if let probe = lanProbe, probe.type == .http, let url = probe.url {
            // In LAN mode the server binds only the LAN IP — a loopback probe
            // URL would refuse even though the service is up.
            let lanURL = url
                .replacingOccurrences(of: "127.0.0.1", with: ip)
                .replacingOccurrences(of: "localhost", with: ip)
            lanProbe = ProbeConfig(
                type: probe.type,
                port: probe.port,
                host: probe.host,
                url: lanURL,
                pattern: probe.pattern,
                artifact: probe.artifact,
                timeout: probe.timeout
            )
        }

        return ServiceDefinition(
            id: definition.id,
            name: definition.name,
            cmd: cmd,
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

        // Services outside the active profile are skipped. The verification
        // oneshots drive the local CDC evidence chain against the dev fixture, so
        // they run only in the full profile.
        if !isInProfile(serviceID) {
            await MainActor.run { state.phase = .skipped }
            return
        }

        // Reuse-if-running: Docker-managed services (Supabase) persist between sessions.
        // If the port is already bound, skip starting and mark as running.
        if definition.shouldReuseIfRunning, let port = definition.probe?.port {
            if isPortBound(port) {
                // Only reuse the monorepo's own database. Another checkout's stack (the
                // old travel-booking-portal one, say) on the same port is a different DB.
                if serviceID == "supabase", let root = definition.resolvedCwd {
                    let expected = SupabaseProject.dbContainerName(root: root)
                    if let occupant = await Self.containerPublishing(port: port), occupant != expected {
                        await logStore.append(serviceID: serviceID, entry: LogEntry(
                            stream: .stderr,
                            text: "[travel-runner] Port \(port) is held by \(occupant), not \(expected). Stop that stack (npx supabase stop in its checkout, or: docker stop $(docker ps -q --filter name=_\(occupant.replacingOccurrences(of: "supabase_db_", with: ""))$)) and start again."
                        ))
                        throw ServiceError.portHeldByOtherStack(port: port, container: occupant)
                    }
                }
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
        let streamDefinition = streamAwareDefinition(for: definition, serviceID: serviceID)
        let effectiveDefinition = lanAwareDefinition(for: streamDefinition, serviceID: serviceID)

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
                await MainActor.run {
                    recordArtifact(name, value: value)
                    state.capturedArtifact = value
                }
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

        // Stripe is an optional local gateway. A stale/expired CLI session must
        // degrade to "skipped", not enter the daemon crash loop (and emit a
        // notification on every retry). The next manual/full start re-runs the
        // credential probe and will enable Stripe again once `stripe login`
        // succeeds.
        if serviceID == "stripe", exitCode != 0 {
            state.phase = .skipped
            state.exitCode = exitCode
            state.pid = nil
            state.lastStopped = .now
            state.failureTimestamps.removeAll()
            recalculateHealth()
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
                guard networkReady else {
                    // Network still down — count the attempt and reschedule with
                    // backoff instead of abandoning the restart permanently.
                    state.restartCount += 1
                    scheduleRestart(serviceID: serviceID)
                    return
                }
            }

            // LAN services: if the machine moved networks, restarting with the
            // stale IP fails with EADDRNOTAVAIL. Re-detect and re-apply instead.
            if networkMode,
               ["travel-portal", "universal-login", "partner-portal"].contains(serviceID) {
                let (output, ok) = await shellOutput("ipconfig getifaddr en0")
                let currentIP = ok ? output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                if !currentIP.isEmpty, currentIP != localIP {
                    await logStore.append(
                        serviceID: serviceID,
                        entry: LogEntry(stream: .stdout, text: "[travel-runner] LAN IP changed (\(localIP ?? "?") → \(currentIP)) — re-applying network mode")
                    )
                    applyNetworkMode()
                    return
                }
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

            // LAN mode: the network may have changed during sleep. Probing or
            // restarting against a stale IP causes false probe failures and
            // EADDRNOTAVAIL crash loops — re-detect before doing anything.
            if networkMode {
                // Wi-Fi can take 10-20s to associate after wake. A single check
                // at +3s falsely concludes "no network" and drops to localhost
                // while the user expects LAN mode to survive the commute.
                var currentIP = ""
                for _ in 0..<7 {
                    let (output, ok) = await shellOutput("ipconfig getifaddr en0")
                    currentIP = ok ? output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    if !currentIP.isEmpty { break }
                    try? await Task.sleep(for: .seconds(3))
                }
                if currentIP.isEmpty {
                    await logStore.append(
                        serviceID: "travel-portal",
                        entry: LogEntry(stream: .stdout, text: "[travel-runner] No LAN IP ~20s after wake — switching back to localhost mode")
                    )
                    await killWebServicePorts()
                    toggleNetworkMode()
                    return
                }
                if currentIP != localIP {
                    await logStore.append(
                        serviceID: "travel-portal",
                        entry: LogEntry(stream: .stdout, text: "[travel-runner] LAN IP changed after wake (\(localIP ?? "?") → \(currentIP)) — re-applying network mode")
                    )
                    await killWebServicePorts()
                    applyNetworkMode()
                    return
                }
            }

            for (serviceID, state) in serviceStates where state.phase == .running {
                guard let probeConfig = state.definition.probe,
                      probeConfig.type != .stdoutRegex else { continue }
                // Use the LAN-aware probe so we check the host the service is
                // actually bound to, and allow a grace window — a single 2s
                // check right after wake produces false failures.
                let effectiveProbe = lanAwareDefinition(for: state.definition, serviceID: serviceID).probe ?? probeConfig
                let probe = ProbeFactory.makeProbe(for: effectiveProbe)
                let ok = (try? await waitForProbe(probe, timeout: .seconds(15), interval: .seconds(3))) ?? false
                if !ok {
                    state.phase = .failed
                    recalculateHealth()
                    scheduleRestart(serviceID: serviceID)
                    Task { await self.captureDebugIssue(
                        trigger: "probe_timeout",
                        serviceID: serviceID,
                        summary: "\(state.definition.displayName) failed wake probe"
                    )}
                } else if let healthPath = Self.wakeHealthPaths[serviceID],
                          let port = probeConfig.port {
                    // TCP answering isn't proof of health: an orphaned dev server
                    // (parent killed during sleep) can hold the port and serve
                    // 404s for every route while looking "running". Verify with
                    // a real HTTP request against a route that must exist.
                    let host = (networkMode ? localIP : nil) ?? "localhost"
                    let healthy = await httpServesPages(host: host, port: port, path: healthPath)
                    if !healthy {
                        await logStore.append(
                            serviceID: serviceID,
                            entry: LogEntry(stream: .stderr, text: "[travel-runner] \(state.definition.displayName) answers TCP but fails HTTP check after wake — killing port \(port) and restarting")
                        )
                        state.phase = .failed
                        recalculateHealth()
                        await processRunner.stop(serviceID: serviceID)
                        await killPortOccupants(port)
                        scheduleRestart(serviceID: serviceID)
                        Task { await self.captureDebugIssue(
                            trigger: "probe_timeout",
                            serviceID: serviceID,
                            summary: "\(state.definition.displayName) served HTTP errors after wake (zombie server) — restarted"
                        )}
                    }
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
                    // Network still down — mark failed and let scheduleRestart
                    // keep retrying with backoff instead of abandoning.
                    stripeState.phase = .failed
                    lastError = "Stripe: network not available after wake — will retry"
                    recalculateHealth()
                    scheduleRestart(serviceID: "stripe")
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

    func listDebugIssues(status: String = "open") async -> [DebugTracker.Issue] {
        guard let tracker = debugTracker else { return [] }
        return await tracker.listIssues(status: status)
    }

    func debugIssueLogs(id: String, status: String = "open") async -> [String: String] {
        guard let tracker = debugTracker else { return [:] }
        return await tracker.issueLogContents(id: id, status: status)
    }

    func debugIssueSnapshot(id: String, status: String = "open") async -> String? {
        guard let tracker = debugTracker else { return nil }
        return await tracker.issueStateSnapshot(id: id, status: status)
    }

    func debugIssueFolder(id: String, status: String = "open") async -> String? {
        guard let tracker = debugTracker else { return nil }
        return await tracker.issueFolderPath(id: id, status: status)
    }

    func closeDebugIssue(id: String, resolution: String) async -> Bool {
        guard let tracker = debugTracker else { return false }
        let ok = await tracker.closeIssue(id: id, resolution: resolution)
        if ok {
            debugOpenIssueCount = await tracker.openIssueCount()
        }
        return ok
    }

    // MARK: - Private: Helpers

    /// The config phase a service belongs to, from graph metadata with an ID-based
    /// fallback for services whose node carries no phase string.
    private func phaseForService(_ id: String) -> String? {
        if let phase = graph?.nodes[id]?.phase { return phase }
        if id == "supabase" || id == "db-reset" { return "ground" }
        if id == "universal-login" || id == "stripe" { return "gateway" }
        if id == "travel-portal" || id == "partner-portal" { return "portal" }
        if id.hasPrefix("stream-") { return "stream" }
        if id.hasPrefix("cache-") || id.hasPrefix("capacity-") { return "verification" }
        return nil
    }

    private func resolvePhase(for serviceIDs: [String]) -> StartupPhase {
        // A DAG level can mix phases (e.g. stream-qstash starts at the same level as
        // the gateway services); the earliest phase in startup order wins so the
        // timeline reflects the leading edge of the level.
        var earliest: StartupPhase? = nil
        for id in serviceIDs {
            guard let phaseName = phaseForService(id),
                  let candidate = StartupPhase(configPhase: phaseName) else { continue }
            if candidate.sortOrder < (earliest?.sortOrder ?? .max) {
                earliest = candidate
            }
        }
        return earliest ?? .running
    }

    func serviceCwd(_ serviceID: String) -> String? {
        graph?.nodes[serviceID]?.resolvedCwd
    }

    /// Grouped services by phase for the UI
    func servicesByPhase() -> [(phase: String, services: [ServiceState])] {
        let phases = ["ground", "gateway", "portal", "stream", "verification"]
        var groups: [(phase: String, services: [ServiceState])] = []
        var matchedIDs = Set<String>()

        for phase in phases {
            let ids = sortedServiceIDs.filter { phaseForService($0) == phase }
            matchedIDs.formUnion(ids)
            let states = ids.compactMap { serviceStates[$0] }
            if !states.isEmpty {
                groups.append((phase: phase.uppercased(), services: states))
            }
        }

        // Never silently drop a service whose phase is unrecognized.
        let otherStates = sortedServiceIDs
            .filter { !matchedIDs.contains($0) }
            .compactMap { serviceStates[$0] }
        if !otherStates.isEmpty {
            groups.append((phase: "OTHER", services: otherStates))
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
        // `stripe config --list` only proves that a credential is stored; it
        // still exits zero for expired API keys. Exercise the authenticated API
        // so invalid sessions are skipped before `stripe listen` can crash.
        await runShellCommand("which stripe >/dev/null 2>&1 && stripe balance retrieve >/dev/null 2>&1")
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

    /// Whether the local database has the travel tables. A fresh Docker volume has
    /// none, and then the startup check runs a reset.
    private func databaseHasAppTables(portalCwd: String) async -> Bool {
        let container = SupabaseProject.dbContainerName(root: portalCwd)
        let query = "SELECT count(*) FROM pg_tables WHERE schemaname = 'fb_travel'"
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

    /// Automatic reset (first run, changed migrations, empty database, branch switch):
    /// the manifest's `reset` profile with the selected seed scenario, shown in the
    /// DB setup panel like a manual reset.
    private func runDbReset(cwd: String) async -> Bool {
        guard let pipeline = makeDbSetupPipeline(cwd: cwd, profile: "reset") else { return false }
        dbSetupPipeline = pipeline
        let runner = DbSetupRunner(portalCwd: cwd, logStore: logStore, seedScenarioID: pipeline.seedScenario.id)
        dbSetupRunner = runner
        await runner.run(pipeline: pipeline, from: nil)
        if pipeline.allRequiredPassed { await refreshLocalSupabaseKeys() }
        if let failed = pipeline.firstFailed {
            lastError = "DB reset failed at \(failed.name): \(failed.errorMessage ?? "unknown error")"
        }
        return pipeline.allRequiredPassed
    }

    /// A pipeline for the manifest profile with the selected seed scenario, or nil (and
    /// `lastError` set) when no valid scenario is selected.
    private func makeDbSetupPipeline(cwd: String, profile: String) -> DbSetupPipeline? {
        reloadDbSeedScenarios()
        guard let seedScenario = selectedDbSeedScenario else {
            lastError = dbSeedScenarioLoadError
                ?? "Choose a valid seed scenario before resetting the database."
            return nil
        }
        let manifestPath = (cwd as NSString).appendingPathComponent("scripts/db/manifest.json")
        let steps = FileManager.default.fileExists(atPath: manifestPath)
            ? DbManifestLoader.load(from: manifestPath, profile: profile)
            : DbSetupPipeline.buildDefault()
        let pipeline = DbSetupPipeline(profile: profile, seedScenario: seedScenario)
        pipeline.steps = steps
        return pipeline
    }

    /// Name of the Docker container that publishes this host port, if any.
    nonisolated static func containerPublishing(port: Int) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "docker ps --filter publish=\(port) --format '{{.Names}}'"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let name = output.split(separator: "\n").first.map(String.init)
                continuation.resume(returning: proc.terminationStatus == 0 ? name : nil)
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
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

    /// Routes that must respond on a healthy server. "/" is wrong for
    /// universal-login, which legitimately 404s at root (app lives at /frontdoor).
    static let wakeHealthPaths: [String: String] = [
        "travel-portal": "/",
        "universal-login": "/frontdoor",
        "partner-portal": "/",
    ]

    /// True when the service returns a non-404, non-5xx response. Generous
    /// timeout + one retry: Next dev servers compile routes on first request
    /// after wake, which can take >10s and must not count as failure.
    private func httpServesPages(host: String, port: Int, path: String) async -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
            let (output, ok) = await shellOutput(
                "curl -s -o /dev/null -w '%{http_code}' --max-time 20 http://\(host):\(port)\(path)"
            )
            guard ok, let code = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            if code >= 200 && code < 500 && code != 404 { return true }
        }
        return false
    }

    /// Kill anything holding the web service ports — including orphaned dev
    /// servers whose npm parent died during sleep. Without this, the replacement
    /// server silently binds port+1 while the zombie serves 404s on the real port.
    private func killWebServicePorts() async {
        for serviceID in Self.wakeHealthPaths.keys {
            guard let port = serviceStates[serviceID]?.definition.probe?.port else { continue }
            await processRunner.stop(serviceID: serviceID)
            await killPortOccupants(port)
        }
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
