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
    /// Set when the control API could not listen on a loopback address.
    var controlAPIError: String? = nil
    /// One line for each service of services.json that the last load left out.
    var configIssues: [String] = []
    /// Set when a release copy runs outside an Applications folder, until the person closes it.
    var misplacedCopyNotice: InstanceGuard.MisplacedNotice? = nil
    /// Set while the checkout needs a newer runner. No reset and no DB step runs
    /// while it is set; the services still start.
    var compatibilityNotice: Compatibility.Notice? = nil
    var startupBeganAt: Date? = nil
    /// Migrations the local database has not applied (from the last check).
    var pendingMigrations: [String] = []
    /// The banner while the database differs from the checkout (from the last check).
    var migrationNotice: DbResetPolicy.Notice? = nil
    var migrationsBannerDismissed = false
    var migrationsBannerVisible: Bool { migrationNotice != nil && !migrationsBannerDismissed }
    /// The error of the last "Apply migrations" that failed, until the next run.
    var migrationApplyError: String? = nil
    /// Set after "Apply migrations" passed, until the person closes it.
    var migrationsAppliedNotice: String? = nil
    /// Set when a DB setup or "Load hotels" stopped because the hotels cannot be
    /// downloaded, until the next setup or a dismiss.
    var hotelSourceNotice: HotelCatalog.SourceNotice? = nil
    /// Set after Start when the hotel catalog is empty and no reset left the hotels
    /// out on purpose.
    var hotelCatalogNotice: HotelCatalog.EmptyNotice? = nil
    var hotelCatalogBannerDismissed = false
    var hotelCatalogBannerVisible: Bool { hotelCatalogNotice != nil && !hotelCatalogBannerDismissed }
    /// Off: the runner asks before a reset for changed migrations. On: it resets a
    /// database that this checkout built by itself. Saved in UserDefaults.
    var autoResetOnMigrations = false {
        didSet { userDefaults.set(autoResetOnMigrations, forKey: DbResetPolicy.autoResetSettingKey) }
    }
    /// The setup of an empty database failed during Start All. The start stopped
    /// before the portals, and the health stays degraded until the next start.
    private(set) var dbSetupFailedAtStart = false
    var dbResetRunning = false
    var dbSetupPipeline: DbSetupPipeline? = nil
    var dbSeedScenarios: [DbSeedScenario] = []
    var selectedDbSeedScenarioID: String?
    var dbSeedScenarioLoadError: String?
    /// Set when the saved scenario is not on this branch and the default one is used.
    var dbSeedScenarioNotice: String?
    /// The reset that waits for the person to confirm it, or nil.
    var resetConfirmation: DbResetPolicy.ResetRequest? = nil
    /// The cached hotel dump, as `fetch-hotels.mjs --verify` sees it.
    var hotelDump: HotelCatalog.DumpState = .unknown
    /// Set after a reset passed while portals ran, until a restart or a dismiss.
    var portalRestartNotice: String? = nil

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
    /// True when Settings saved new paths while the stack ran. They load at the
    /// next launch, or at the next reconfigure with the stack stopped.
    private(set) var reconfigurePending = false

    func isInProfile(_ serviceID: String) -> Bool { profileMembers.contains(serviceID) }

    /// The row shows Start for a daemon with no process while the environment runs:
    /// skipped (Stripe without its CLI or its session) or stopped. A service outside
    /// the profile cannot start.
    func canStartFromRow(_ state: ServiceState) -> Bool {
        state.definition.resolvedType != .oneshot
            && (state.phase == .skipped || state.phase == .stopped)
            && health != .stopped
            && isInProfile(state.id)
    }

    /// The fb-travel-monolith checkout that the runner runs, or nil before setup.
    var monorepoPath: String? {
        guard let path = config?.paths?.monorepo, !path.isEmpty else { return nil }
        return ServiceCatalog.expand(path)
    }

    /// The services of the loaded graph, in start order.
    private var loadedServices: [ServiceDefinition] {
        guard let graph else { return [] }
        return sortedServiceIDs.compactMap { graph.nodes[$0] }
    }

    /// The folder of the Supabase service: the checkout that the DB scripts run in.
    private var supabaseCwd: String? { graph?.nodes["supabase"]?.resolvedCwd }

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

    /// The banner does not come back for this place.
    func dismissMisplacedCopyNotice() {
        guard let notice = misplacedCopyNotice else { return }
        InstanceGuard.dismiss(notice, defaults: userDefaults)
        misplacedCopyNotice = nil
    }

    var rootCauseDescription: String? {
        guard let rootID = rootCauseServiceID, let graph else { return nil }
        let name = serviceStates[rootID]?.definition.displayName ?? rootID
        let affected = graph.dependents(of: rootID).count
        if affected == 0 { return "Root cause: \(name)" }
        return "Root cause: \(name) — \(affected) dependent\(affected == 1 ? "" : "s") affected"
    }

    // MARK: - Internal Components

    /// The app gives it a file sink. Without one the logs stay in memory.
    let logStore: LogStore
    /// The reader for the Rooms tab. It is not a service of the graph.
    let holdsViewer: HoldsViewerHost
    private let secretStore = SecretStore()
    private var graph: ServiceGraph?
    private let processRunner: ProcessRunner
    /// The PATH of the services and of every helper command.
    @ObservationIgnored let tools: ToolEnvironment
    /// Runs the helper commands of the supervisor. Tests can replace it.
    @ObservationIgnored var shell: any CommandRunning
    /// The port cleanup reads listeners and kills through these tools.
    @ObservationIgnored var portTools = PortTools.live
    /// The check that the Stripe CLI is installed and logged in. Tests set it; nil
    /// runs the CLI.
    @ObservationIgnored var stripeAvailability: (@Sendable () async -> Bool)?
    /// The time of every wait, deadline and time stamp of the supervisor. Tests
    /// set a fake.
    @ObservationIgnored var clock = RunnerClock.live
    /// The services that the other runner app runs now. The config load and Start
    /// All ask it. Tests set a fake, so no test asks the other app.
    @ObservationIgnored var siblingActiveServices: @Sendable () async -> [String] = { await SiblingRunner.activeServices() }
    /// The ports that the secret registry tries. Tests give port 0, so the
    /// system picks a free one.
    @ObservationIgnored var secretRegistryPorts: ClosedRange<UInt16> = LiveSecretRegistry.defaultPorts
    /// Where the config and the control server come from.
    @ObservationIgnored var configHost = ConfigHost()
    /// The preflight checks run their commands in the shell of the supervisor and
    /// wait on its clock.
    private var preflightRunner: PreflightRunner { PreflightRunner(shell: shell, clock: clock) }
    private var registry: LiveSecretRegistry?
    private var controlServer: ControlServer?
    private var sleepWakeObserver: SleepWakeObserver?
    private var startTask: Task<Void, any Error>?
    private var config: ServiceConfig?
    private var isShuttingDown = false
    private let userDefaults: UserDefaults
    private var stdoutProbes: [String: StdoutProbe] = [:]
    private var didBootstrap = false
    /// The env reset of the last config load, which first asks the other runner
    /// app. Nil before the first load.
    private(set) var envResetAfterLoad: Task<Void, Never>?
    private var phaseStartedAt: Date? = nil
    private var dbSetupRunner: DbSetupRunner?
    /// Nil while issue capture is off. Tests set a tracker with a temporary folder.
    var debugTracker: DebugTracker?
    /// The tracker of this app, also while capture is off. One instance for the
    /// whole run: it holds the rate limit.
    private var issueTracker: DebugTracker?
    /// Makes the tracker of this app. Tests give one with a temporary folder.
    var makeIssueTracker: () -> DebugTracker = { DebugTracker() }
    /// How often the switch and the open count are read from the issue folder.
    var issueCapturePollInterval: Duration = .seconds(30)
    private var issueCapturePollStarted = false
    private var issueLaunchPruneDone = false
    private var gitBranchWatcher: GitBranchWatcher?
    private var gitRepoRoots: [String: String] = [:]
    private var dependencyWatcher: DependencyWatcher?
    private var gitWatcherTask: Task<Void, Never>?
    private var depsWatcherTask: Task<Void, Never>?
    private var isTogglingNetwork = false
    private var stripeReconnectingSince: Date? = nil
    private var localSupabaseKeys: LocalSupabaseKeys?
    private var stripeWebhookSecret: String?
    /// The stop and start of one service run one at a time (see `KeyedLock`).
    private let lifecycle = KeyedLock()
    /// Services with a manual restart (or a cache clear) that waits for its turn.
    /// A second request of the same kind adds nothing while one waits.
    private var queuedRestarts: Set<String> = []
    private var queuedCacheClears: Set<String> = []
    private var actionCounts: [String: Int] = [:]
    /// The last exit 127 of each service and what it means. The wait for the
    /// start and the end of the process both ask, and they must get one answer.
    private var missingToolDiagnoses: [String: (pid: Int32, task: Task<ToolEnvironment.MissingTool?, Never>)] = [:]
    private var isHandlingWake = false
    private var networkReapplyPending = false
    private var wakePassStartedAt: Date?
    private var wakePending = false
    /// Tests replace the database query and the reset with fakes.
    var databaseQuery: ((_ cwd: String, _ sql: String) async -> DbQueryResult)?
    /// How long the automatic reset waits for a database that does not answer yet.
    /// The port of Supabase opens before Postgres takes queries.
    var databaseProbeRetry: (interval: Duration, timeout: Duration) = (.seconds(2), .seconds(60))
    var dbResetAction: ((_ cwd: String) async -> Bool)?
    /// Tests give the pipeline of a DB setup, so no manifest and no seed scenario
    /// is read. Nil from the closure starts nothing and sets `lastError`, like a
    /// missing scenario.
    var dbPipelineFactory: ((_ cwd: String, _ profile: String) -> DbSetupPipeline?)?
    /// How a DB step command starts. Tests give a shell that reads no startup files.
    var dbStepLauncher: StepLauncher = .loginShell
    /// Where the app keeps the hotel dump. Tests give their own folder.
    @ObservationIgnored var hotelDumpPath = DbSetupRunner.hotelDumpPath()
    /// The version that the checkout's `runner.minVersion` is compared with. Nil is
    /// never blocked. Tests set it.
    @ObservationIgnored var runnerVersion: String? = Compatibility.comparableVersion(of: .current)

    init(
        userDefaults: UserDefaults = .standard, holdsViewer: HoldsViewerHost? = nil,
        tools: ToolEnvironment = .shared, logSink: LogFileSink? = nil
    ) {
        self.tools = tools
        self.processRunner = ProcessRunner(tools: tools)
        self.shell = LoginShell(tools: tools)
        self.logStore = LogStore(sink: logSink)
        self.holdsViewer = holdsViewer ?? HoldsViewerHost()
        self.holdsViewer.logStore = logStore
        self.userDefaults = userDefaults
        self.selectedDbSeedScenarioID = userDefaults.string(forKey: "dbSeedScenarioID")
        self.autoResetOnMigrations = userDefaults.bool(forKey: DbResetPolicy.autoResetSettingKey)
        if holdsViewer == nil {
            self.holdsViewer.monorepo = { [weak self] in self?.monorepoPath }
        }
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
        case exitedDuringStartup(String)
        /// The supervisor stopped the automatic restarts; the text says why.
        case autoRestartStopped(String)
        /// `tool` says what exit 127 means when the command is a tool that the
        /// PATH of the launch did not have.
        case commandNotRunnable(name: String, command: String, code: Int32, tool: ToolEnvironment.MissingTool? = nil)
        case localKeysMissing(name: String, envFile: String)
        case portHeldByOtherStack(port: Int, container: String)
        /// `owner` is the process name of the container runtime that listens on the port.
        case portHeldByContainer(name: String, port: Int, owner: String)
        /// `reason` is `ProbeConfig.problem`.
        case badProbe(name: String, reason: String)

        var description: String {
            switch self {
            case .oneshotFailed(let id): "'\(id)' exited with non-zero status"
            case .probeTimeout(let id, let s): "'\(id)' health probe timed out after \(s)s"
            case .exitedDuringStartup(let id): "'\(id)' exited before it was ready — see its log"
            case .autoRestartStopped(let reason): reason
            case .commandNotRunnable(let name, let command, _, .notFound(let searchedPath)):
                "\(name) cannot start: \(ToolEnvironment.notFoundText(tool: command, searchedPath: searchedPath))"
            case .commandNotRunnable(let name, let command, _, .foundNow(let path)):
                ToolEnvironment.foundNowText(name: name, tool: command, path: path)
            case .commandNotRunnable(let name, let command, let code, nil):
                "\(name) cannot start: the shell could not run \(command) (exit \(code)). Does the current branch have it? Restart \(name) after the fix."
            case .localKeysMissing(let name, let envFile):
                "\(name) was not started: the keys of the local Supabase stack could not be read (scripts/local-db.sh status -o env). Without them it would use the hosted dev values in \(envFile). Restart Supabase, then restart \(name)."
            case .portHeldByOtherStack(let port, let container):
                "Port \(port) is held by another Supabase stack (\(container)) — stop it, then start again"
            case .badProbe(let name, let reason):
                "\(name) cannot start: \(reason). Correct its probe in services.json, then quit \(Flavor.current.displayName) and open it again."
            case .portHeldByContainer(let name, let port, let owner):
                "\(name) cannot start: port \(port) is published by a container (\(owner)) — stop that container, then restart \(name)"
            }
        }
    }

    // MARK: - Lifecycle

    /// What the config load takes from the app and from this Mac. Tests give fakes,
    /// so no test reads services.json or binds the control port.
    struct ConfigHost {
        var load: () throws -> ServiceConfig = { try ConfigLoader.load() }
        var controlServer: () -> ControlServer = { ControlServer() }
        /// False: the load starts no git and no npm watcher on the service folders.
        /// Tests set it, so no test runs the git of this Mac.
        var startsWatchers = true
    }

    /// The answer of `reconfigure()`.
    enum ReconfigureResult: Equatable, Sendable {
        /// The new config is loaded.
        case applied
        /// The stack runs. Nothing changed; the new config waits in services.json.
        case needsStop
        /// The new config could not be loaded. The old one stays.
        case failed(String)
    }

    /// The launch of the app: starts what lives as long as the app does, then
    /// loads the config. The control API and issue capture do not wait for a
    /// config: a first run has none.
    func loadConfig() {
        bootstrapOnce()
        do {
            try applyConfig()
        } catch ConfigLoader.ConfigError.noConfig {
            // First run — setup wizard will handle this
        } catch ConfigLoader.ConfigError.monorepoNotFound {
            // Old three-repo config with no monorepo nearby — setup wizard will handle this
        } catch {
            lastError = "Config load failed: \(error)"
            print("[Supervisor] \(lastError!)")
        }
    }

    /// Loads the config that Settings saved. While the stack runs it changes
    /// nothing and answers `.needsStop`: a new service state knows no process, so
    /// a load now would lose the processes that run.
    func reconfigure() async -> ReconfigureResult {
        guard await !holdsLiveStack() else {
            reconfigurePending = true
            return .needsStop
        }
        do {
            try applyConfig()
            lastError = nil
            onActionFeedback?("Paths updated", true)
            return .applied
        } catch {
            let message = "Paths not applied: \(error)"
            lastError = message
            onActionFeedback?(message, false)
            return .failed(message)
        }
    }

    /// "Stop and apply": stops the stack, then loads the config that Settings saved.
    @discardableResult
    func stopAndReconfigure() -> Task<ReconfigureResult, Never> {
        let stop = beginStopAll()
        return Task {
            await stop.value
            let result = await reconfigure()
            if result == .needsStop {
                onActionFeedback?("Paths not applied: the stack did not stop. Stop it, then save the paths again.", false)
            }
            return result
        }
    }

    /// True while the runner starts, stops or holds a process of the stack, or
    /// runs a database step.
    private func holdsLiveStack() async -> Bool {
        // A failed service can still have a process, and `pid` of a state stays
        // after its process ends. The process runner knows what runs. It answers
        // first: the other checks then see the state of this moment.
        if await processRunner.hasRunningProcess() { return true }
        if startTask != nil || isShuttingDown || !actionsInFlight.isEmpty { return true }
        if dbResetRunning || dbSetupPipeline?.isRunning == true { return true }
        let livePhases: Set<ServicePhase> = [.starting, .running, .stopping]
        return serviceStates.values.contains { livePhases.contains($0.phase) }
    }

    /// Runs once for the app: the secret observer, the wake observer, the control
    /// API and issue capture. A second control server would fail on the port, and
    /// a second wake observer would run each recovery twice.
    private func bootstrapOnce() {
        guard !didBootstrap else { return }
        didBootstrap = true

        // Issue capture is on unless the config in the issue folder says no.
        Task { await initDebugTracking() }

        // The observer resolves paths at write time, so a new monorepo path needs
        // no new observer.
        Task {
            await secretStore.onChange { [weak self] key, value in
                Task { @MainActor in self?.recordArtifact(key, value: value) }
            }
        }

        sleepWakeObserver = SleepWakeObserver { [weak self] in
            self?.handleWake()
        }
        sleepWakeObserver?.startObserving()

        // Start control API server
        startControlServer()
    }

    /// Reads services.json and replaces the graph, the service states, the env
    /// blocks and the watchers. It runs at launch and at each reconfigure. The
    /// caller makes sure that no service runs. When the read fails, nothing changes.
    private func applyConfig() throws {
        let config = try configHost.load()
        let graph = try ServiceGraph(services: config.services)
        self.config = config
        configIssues = config.skippedServices.map(\.message)
        for issue in configIssues { print("[Config] \(issue)") }
        self.graph = graph
        let redactor = makeRedactor()
        Task { [logStore] in await logStore.setRunnerRedactor(redactor) }
        self.sortedServiceIDs = graph.sortedIDs
        self.profile = config.resolvedProfile
        self.profileMembers = config.resolvedProfile.members(of: config.services)
        self.serviceStates = [:]
        for service in config.services {
            serviceStates[service.id] = ServiceState(definition: service)
        }
        reconfigurePending = false

        reloadDbSeedScenarios()
        // Another checkout can name another minimum runner version.
        if let cwd = serviceCwd("supabase") {
            refreshCompatibility(cwd: cwd)
        } else if compatibilityNotice != nil {
            compatibilityNotice = nil
        }

        // Always reset .env.local files to localhost on startup. Keys from the
        // last block first; the running stack's keys replace them after GROUND.
        // Not while the other runner app runs a stack: the login's env file is
        // the same file for the two apps.
        localSupabaseKeys = nil
        stripeWebhookSecret = nil
        cacheLocalSupabaseKeys()
        resetEnvAfterLoad()

        // The watchers of the last config stop; their answers are for other folders.
        gitWatcherTask?.cancel()
        gitWatcherTask = nil
        gitBranchWatcher = nil
        gitRepoRoots = [:]
        gitBranches = [:]
        gitBehindCounts = [:]
        depsWatcherTask?.cancel()
        depsWatcherTask = nil
        dependencyWatcher = nil
        npmStaleServices = []

        // Initialize git branch watcher for all repos with cwds
        var repoMap: [String: String] = [:]
        for service in config.services {
            if let cwd = service.resolvedCwd {
                repoMap[service.id] = cwd
            }
        }
        if configHost.startsWatchers, !repoMap.isEmpty {
            let watcher = GitBranchWatcher(repos: repoMap)
            gitBranchWatcher = watcher
            gitRepoRoots = watcher.repoRoots
            gitWatcherTask = Task { await startGitBranchWatching(watcher: watcher) }
        }

        // Initialize dependency (npm install) freshness watcher
        var depsMap: [String: String] = [:]
        for service in config.services {
            if let cwd = service.resolvedCwd, service.resolvedType == .daemon {
                depsMap[service.id] = cwd
            }
        }
        if configHost.startsWatchers, !depsMap.isEmpty {
            let depsWatcher = DependencyWatcher(repoPaths: depsMap)
            dependencyWatcher = depsWatcher
            depsWatcherTask = Task { await startDepsWatching(watcher: depsWatcher) }
        }
    }

    /// Asks the other runner app what it runs, then resets the env files when it
    /// runs nothing. The ask runs in a task, so the launch does not wait for an
    /// app that answers late. Each action that starts a process waits for the task
    /// (`waitForEnvResetOfLoad`); a newer load replaces it.
    private func resetEnvAfterLoad() {
        envResetAfterLoad?.cancel()
        let siblingServices = siblingActiveServices
        envResetAfterLoad = Task { [weak self] in
            let services = await siblingServices()
            // A newer load, or a database mode that the person chose, replaced this reset.
            guard !Task.isCancelled, services.isEmpty else { return }
            self?.resetEnvToLocalhost()
        }
    }

    /// The env files of the last load must be written before a service or a
    /// database step reads them.
    private func waitForEnvResetOfLoad() async {
        await envResetAfterLoad?.value
    }

    /// Loads a service graph without the app's side effects: no config file, control
    /// server, env files, or watchers. The lifecycle tests use it with small services.
    func loadServices(_ services: [ServiceDefinition], profile: RunProfile = .full) throws {
        let graph = try ServiceGraph(services: services)
        self.graph = graph
        self.sortedServiceIDs = graph.sortedIDs
        self.profile = profile
        self.profileMembers = profile.members(of: services)
        self.serviceStates = [:]
        for service in services {
            serviceStates[service.id] = ServiceState(definition: service)
        }
    }

    // MARK: - Start / Stop

    func startAll(skipPreflight: Bool = false) {
        guard startTask == nil, let graph else { return }
        // A start that a person asks for begins a new failure series for each service.
        for serviceID in serviceStates.keys { clearFailureHistory(serviceID) }
        health = .starting
        lastError = nil
        dbSetupFailedAtStart = false
        startupBeganAt = clock.date()
        phaseTimings = [:]

        startTask = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor in
                    self.startTask = nil
                }
            }

            await self.waitForEnvResetOfLoad()

            // The other runner app uses the same ports, and this start stops what it
            // finds on them.
            let siblingServices = await self.siblingActiveServices()
            if !siblingServices.isEmpty {
                await MainActor.run {
                    self.health = .degraded
                    self.lastError = SiblingRunner.refusal(activeServices: siblingServices)
                    self.currentPhase = .idle
                }
                return
            }

            // Preflight
            if !skipPreflight {
                self.currentPhase = .preflight
                let profileServices = self.loadedServices.filter { self.isInProfile($0.id) }
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
            self.registry = LiveSecretRegistry(secretStore: self.secretStore, portRange: self.secretRegistryPorts)
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
                    self.phaseStartedAt = self.clock.date()
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
                        self.phaseTimings[phase.rawValue] = self.clock.date().timeIntervalSince(started)
                    }
                    self.completedPhases.insert(phase.rawValue)
                }

                // After the GROUND phase (Supabase is up), the reset policy looks at the
                // database. An empty database is set up; changed migrations only show
                // the banner, unless the opt-in setting is on.
                if phase == .ground && !didMigrationCheck {
                    didMigrationCheck = true
                    // Supabase is up: write its keys before any portal starts.
                    await self.refreshLocalSupabaseKeys()
                    if let cwd = self.supabaseCwd {
                        let outcome = await self.applyDbResetPolicy(cwd: cwd, checkMigrations: true, atStart: true)
                        await self.refreshPendingMigrations(cwd: cwd)
                        // The portals need the tables. A failed setup ends the start here.
                        if outcome == .failed {
                            self.dbSetupFailedAtStart = true
                            break
                        }
                        // An empty catalog only shows the banner: nothing loads by itself.
                        await self.refreshHotelCatalog(cwd: cwd)
                    }
                }

            }

            await MainActor.run {
                self.recalculateHealth()
                if self.dbSetupFailedAtStart {
                    self.currentPhase = .idle
                } else if self.health == .healthy {
                    self.currentPhase = .running
                }
                self.startupBeganAt = nil
            }
        }
    }

    func stopAll() {
        beginStopAll()
    }

    /// Starts the stop of the stack. The task ends when the stack is stopped.
    @discardableResult
    private func beginStopAll() -> Task<Void, Never> {
        isShuttingDown = true
        startTask?.cancel()
        startTask = nil
        return Task {
            for serviceID in sortedServiceIDs {
                serviceStates[serviceID]?.phase = .stopping
            }

            // A DB step is part of the stack: Stop All ends it and its child processes.
            if dbResetRunning || dbSetupPipeline?.isRunning == true {
                await dbSetupRunner?.cancel()
            }

            // Read before the stop: the ports of the services that this session started.
            let ports = sweepPorts
            await processRunner.stopAll()

            // Kill any orphaned processes still bound to those ports
            for port in ports where isPortBound(port) {
                await killPortOccupants(port)
            }

            for serviceID in sortedServiceIDs {
                serviceStates[serviceID]?.phase = .stopped
            }

            await registry?.stop()
            dbSetupFailedAtStart = false
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

    /// The answer of `/api/status`.
    func statusJSON(buildInfo: BuildInfo = .current) -> String {
        let states = serviceStates.mapValues { s in
            ["phase": s.phase.rawValue, "pid": s.pid.map(String.init) ?? "nil"]
        }
        var dict: [String: Any] = [
            "app": Flavor.current.rawValue,
            // False until a services.json loads: a first run, or a config that needs setup.
            "configured": config != nil,
            "health": health.rawValue, "services": states, "lan": networkMode, "ip": localIP ?? "none",
            "profile": profile.rawValue,
            "db_mode": dbMode.rawValue,
            "branches": gitBranches,
            "gitBehind": gitBehindCounts,
            "npmStale": Array(npmStaleServices)
        ]
        // Present only while this runner is too old to reset the checkout.
        if let compatibilityNotice { dict["reset_blocked"] = compatibilityNotice.text }
        // version, build, commit, build_kind
        dict.merge(buildInfo.statusFields) { current, _ in current }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) { return str }
        return "{}"
    }

    /// The answer of `/api/preflight`: the checks of a start that change nothing
    /// (Node, the ports, the folders), run now. Each check has a time limit, so
    /// the answer always comes. Without a config only the Node check runs.
    func preflightJSON() async -> String {
        let runner = preflightRunner
        var rows: [[String: String]] = []
        for check in runner.readOnlyChecks(for: loadedServices) {
            var row = ["id": check.id, "name": check.name]
            switch await runner.run(check: check) {
            case .pending: row["status"] = "pending"
            case .passed(let detail):
                row["status"] = "passed"
                row["detail"] = detail
            case .warning(let message):
                row["status"] = "warning"
                row["detail"] = message
            case .failed(let message, let fix):
                row["status"] = "failed"
                row["detail"] = message
                if let fix { row["fix"] = fix }
            }
            rows.append(row)
        }
        let body: [String: Any] = ["configured": config != nil, "checks": rows]
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "{}"
    }

    private func startControlServer() {
        let logStore = self.logStore
        controlServer = configHost.controlServer()
        Task {
            let failures = await controlServer?.start(
                actions: ControlServer.Actions(
                    getStatus: { [weak self] in
                        guard let self else { return "{}" }
                        return await MainActor.run { self.statusJSON() }
                    },
                    getPreflight: { [weak self] in
                        guard let self else { return "{}" }
                        return await self.preflightJSON()
                    },
                    getLogs: { [weak self] serviceId, lines in
                        guard let self else { return "[]" }
                        let entries = await self.logStore.entries(for: serviceId)
                        let tail = entries.suffix(lines)
                        let redactor = await MainActor.run { self.makeRedactor() }
                        let lines = tail.map {
                            ["stream": $0.stream == .stdout ? "stdout" : "stderr", "text": redactor.redact($0.text)]
                        }
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
                    dbResetBlock: { [weak self] in
                        await MainActor.run { self?.resetBlockJSON() }
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
            ) ?? []
            controlAPIError = ControlServer.BindFailure.summary(failures)
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
        guard let cwd = serviceCwd(serviceID) else {
            lastError = "No cwd found for \(serviceID)"
            return
        }
        guard queuedCacheClears.insert(serviceID).inserted else { return }
        Task {
            beginAction(serviceID)
            defer { endAction(serviceID) }
            do {
                try await replaceProcess(serviceID, prepare: {
                    self.queuedCacheClears.remove(serviceID)
                    let nextCachePath = (cwd as NSString).appendingPathComponent(".next")
                    try? FileManager.default.removeItem(atPath: nextCachePath)
                    await self.logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stdout, text: "[travel-runner] Cleared .next cache"))
                    try? await self.clock.sleep(for: .seconds(1))
                })
                clearCleanExitError(serviceID)
            } catch {
                serviceStates[serviceID]?.phase = .failed
                lastError = "\(error)"
            }
            recalculateHealth()
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
                lastError = "Hosted dev values are missing from \(files.joined(separator: " and ")) — import the shared file (Settings → Reconfigure Repos… → Environment Check), then switch again"
                return
            }
            // The reset of a config load that still waits must not undo this choice.
            envResetAfterLoad?.cancel()
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
            beginAction("db-mode")
            defer { endAction("db-mode") }
            var switchFailed = false
            for serviceID in servicesToRestart {
                serviceStates[serviceID]?.phase = .stopping
            }
            for serviceID in servicesToRestart {
                do {
                    try await replaceProcess(serviceID)
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
        guard !isTogglingNetwork else {
            // Wake recovery stops the web services and then asks for this. If the
            // request were dropped, they would stay down. Run it after the current one.
            networkReapplyPending = true
            return
        }
        isTogglingNetwork = true
        let mode = networkMode

        Task {
            beginAction("lan-mode")
            defer {
                isTogglingNetwork = false
                endAction("lan-mode")
                if networkReapplyPending {
                    networkReapplyPending = false
                    applyNetworkMode()
                }
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
                do {
                    try await replaceProcess(serviceID, prepare: {
                        await self.logStore.append(
                            serviceID: serviceID,
                            entry: LogEntry(stream: .stdout, text: "[travel-runner] Network mode \(mode ? "ON — http://\(ip)" : "OFF — localhost only")")
                        )
                    })
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

    private func shellOutput(_ command: String, cwd: String? = nil) async -> (String, Bool) {
        let result = await shell.run(command, cwd: cwd)
        return (result.stdout, result.succeeded)
    }

    /// A restart that a person or the API asks for. It clears the failure history:
    /// the circuit breaker and the backoff start again.
    func restartService(_ serviceID: String) {
        if serviceID == "stripe" { stripeReconnectingSince = nil }
        guard queuedRestarts.insert(serviceID).inserted else { return }
        let name = serviceStates[serviceID]?.definition.displayName ?? serviceID
        Task {
            beginAction(serviceID)
            defer { endAction(serviceID) }
            await waitForEnvResetOfLoad()
            do {
                try await replaceProcess(serviceID, stoppedPhase: .pending, prepare: {
                    self.queuedRestarts.remove(serviceID)
                    try? await self.clock.sleep(for: .seconds(1))
                })
                clearCleanExitError(serviceID)
                if serviceStates[serviceID]?.phase == .skipped {
                    onActionFeedback?("\(name) skipped — see its log", false)
                } else {
                    onActionFeedback?("\(name) restarted", true)
                }
            } catch {
                serviceStates[serviceID]?.phase = .failed
                lastError = "\(error)"
                onActionFeedback?("\(name) restart failed", false)
            }
            recalculateHealth()
        }
    }

    /// A restart that the supervisor starts by itself after a failure. It keeps the
    /// failure history, so the circuit breaker and the backoff see the whole series.
    private func autoRestart(_ serviceID: String) async {
        do {
            try await replaceProcess(serviceID, stoppedPhase: .pending, keepsFailureHistory: true, onlyIf: {
                // A manual restart or a mode switch can bring the service back first.
                guard let state = self.serviceStates[serviceID],
                      state.phase == .failed, !state.isCircuitBroken else { return false }
                state.restartCount += 1
                return true
            })
        } catch {
            serviceStates[serviceID]?.phase = .failed
            lastError = "\(error)"
        }
        recalculateHealth()
    }

    /// The banner text for a daemon that ended with code 0.
    nonisolated static func cleanExitMessage(_ name: String) -> String {
        "\(name) exited (code 0) and was not restarted — restart it from its row"
    }

    /// The person restarted the service, as the banner asked. A newer error stays.
    private func clearCleanExitError(_ serviceID: String) {
        guard let name = serviceStates[serviceID]?.definition.displayName else { return }
        if lastError == Self.cleanExitMessage(name) { lastError = nil }
    }

    private func clearFailureHistory(_ serviceID: String) {
        serviceStates[serviceID]?.restartCount = 0
        serviceStates[serviceID]?.isCircuitBroken = false
        serviceStates[serviceID]?.failureTimestamps = []
    }

    /// Stops the service's process and starts a new one. The stop and the start hold
    /// the service's lock, so two requests cannot start two processes that fight for
    /// the port. `prepare` runs between them. The wait for readiness holds no lock: a
    /// process that fails while it starts can be restarted at once.
    /// Returns false when `onlyIf` said no.
    @discardableResult
    private func replaceProcess(
        _ serviceID: String,
        stoppedPhase: ServicePhase = .starting,
        keepsFailureHistory: Bool = false,
        onlyIf condition: (@MainActor () -> Bool)? = nil,
        prepare: (@MainActor () async -> Void)? = nil
    ) async throws -> Bool {
        var replaced = false
        let launch = try await lifecycle.withLock(serviceID) { () -> ServiceLaunch? in
            if let condition, !condition() { return nil }
            replaced = true
            // Only the automatic restart keeps the history. Each deliberate restart
            // (manual, cache clear, mode switch) starts a new series; if it did not,
            // a tripped breaker would block the automatic restart from then on.
            if !keepsFailureHistory { clearFailureHistory(serviceID) }
            serviceStates[serviceID]?.phase = .stopping
            await processRunner.stop(serviceID: serviceID)
            serviceStates[serviceID]?.phase = stoppedPhase
            await prepare?()
            return try await spawnService(serviceID)
        }
        if let launch { try await awaitReady(serviceID, launch) }
        return replaced
    }

    private func beginAction(_ key: String) {
        actionCounts[key, default: 0] += 1
        actionsInFlight.insert(key)
    }

    private func endAction(_ key: String) {
        let remaining = (actionCounts[key] ?? 1) - 1
        if remaining <= 0 {
            actionCounts.removeValue(forKey: key)
            actionsInFlight.remove(key)
        } else {
            actionCounts[key] = remaining
        }
    }

    func restartCascade(_ serviceID: String) {
        guard let graph else { return }
        let dependents = graph.dependents(of: serviceID)
        let allAffected = dependents.union([serviceID])
        let topoOrder = graph.sortedIDs.filter { allAffected.contains($0) }
        let name = serviceStates[serviceID]?.definition.displayName ?? serviceID

        Task {
            for id in topoOrder { beginAction(id) }
            defer { for id in topoOrder { endAction(id) } }
            for id in topoOrder.reversed() {
                await lifecycle.withLock(id) {
                    serviceStates[id]?.phase = .stopping
                    await processRunner.stop(serviceID: id)
                    serviceStates[id]?.phase = .stopped
                }
            }

            for id in topoOrder {
                serviceStates[id]?.phase = .starting
                clearFailureHistory(id)
                do {
                    try await startService(id)
                } catch {
                    serviceStates[id]?.phase = .failed
                    lastError = "Cascade restart failed at \(id): \(error)"
                    recalculateHealth()
                    onActionFeedback?("Cascade restart failed at \(id)", false)
                    return
                }
                clearCleanExitError(id)

                // After Supabase comes back, the reset policy sets up an empty
                // database. Changed migrations only refresh the banner.
                if id == "supabase", let cwd = supabaseCwd {
                    await resetDatabaseIfNeeded(cwd: cwd, checkMigrations: false)
                    await refreshPendingMigrations(cwd: cwd)
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
        profileMembers = newProfile.members(of: loadedServices)
        onActionFeedback?("Profile: \(newProfile.displayName)", true)
    }

    private func startDepsWatching(watcher: DependencyWatcher) async {
        while !Task.isCancelled {
            let stale = await watcher.check()
            // A reconfigure replaced this watcher during the check.
            if Task.isCancelled { break }
            await MainActor.run { self.npmStaleServices = stale }
            try? await clock.sleep(for: .seconds(30))
        }
    }

    private func startGitBranchWatching(watcher: GitBranchWatcher) async {
        _ = await watcher.check()
        await watcher.fetchAndCount(fetchInterval: 0)
        let initial = await watcher.branches
        let initialBehind = await watcher.behindCounts
        // A reconfigure replaced this watcher: its answers are for other folders.
        if Task.isCancelled { return }
        await MainActor.run {
            self.gitBranches = initial
            self.gitBehindCounts = initialBehind
        }

        while !Task.isCancelled {
            try? await clock.sleep(for: .seconds(5))
            if Task.isCancelled { break }
            let changed = await watcher.check()
            await watcher.fetchAndCount()
            let allBranches = await watcher.branches
            let allBehind = await watcher.behindCounts
            if Task.isCancelled { break }
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
                    // The new branch can name another minimum runner version.
                    refreshCompatibility(cwd: cwd)
                    // The same policy as Start All: new migrations show the banner,
                    // and reset only with the opt-in setting.
                    await resetDatabaseIfNeeded(cwd: cwd, checkMigrations: true)
                    await refreshPendingMigrations(cwd: cwd)
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
        guard let cwd = supabaseCwd else {
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
            let resolution = DbSeedScenarioSelection.resolve(catalog: catalog, savedID: savedID)
            selectedDbSeedScenarioID = resolution.id
            // A saved scenario that this branch lacks stays saved: it comes back on a
            // branch that has it. Until then the reset uses the default one.
            if savedID == nil {
                userDefaults.set(resolution.id, forKey: "dbSeedScenarioID")
            }
            dbSeedScenarioNotice = resolution.staleID.map {
                DbSeedScenarioSelection.staleNotice(id: $0, using: catalog.defaultScenario?.name ?? resolution.id)
            }
            dbSeedScenarioLoadError = nil
        } catch {
            dbSeedScenarios = []
            selectedDbSeedScenarioID = savedID
            dbSeedScenarioNotice = nil
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
        dbSeedScenarioNotice = nil
    }

    func resetDatabase(profile: String = "reset") {
        runDbSetup(profile: profile)
    }

    /// A DB setup that a person asked for: a button, a retry, or the control API.
    func runDbSetup(from stepId: String? = nil, profile: String = "reset") {
        let origin: DbSetupOrigin = profile == DbResetPolicy.migrateProfile
            ? .applyMigrations : (stepId == nil ? .manual : .retry)
        guard let run = beginDbSetup(cwd: supabaseCwd, profile: profile, reason: nil, origin: origin, from: stepId) else {
            return
        }
        Task { await completeDbSetup(run) }
    }

    /// "Apply migrations": the manifest's `migrate` profile. It never resets. A failed
    /// apply leaves the banner with "Reset and reseed…"; nothing resets by itself.
    func applyMigrations() {
        runDbSetup(profile: DbResetPolicy.migrateProfile)
    }

    func dismissMigrationsAppliedNotice() {
        migrationsAppliedNotice = nil
    }

    // MARK: - Hotels

    /// "Load hotels": the load step on its own. It downloads the dump first when no
    /// valid one is cached, and never resets.
    func loadHotels() {
        guard let run = beginDbSetup(
            cwd: supabaseCwd, profile: "reset", reason: nil, origin: .singleStep, from: "load-hotels",
            singleStep: true, reusePipeline: false
        ) else { return }
        Task { await completeDbSetup(run) }
    }

    /// "Reset without hotels": the manifest profile without the hotel steps.
    func resetWithoutHotels() {
        runDbSetup(profile: HotelCatalog.withoutHotelsProfile)
    }

    /// "Import shared .env…": the import of the Environment Check, for the booking
    /// portal. The hotel download reads its dev keys.
    func importSharedEnvForHotels() {
        guard let monorepo = supabaseCwd ?? monorepoPath else { return }
        let checker = EnvironmentChecker(
            monorepoPath: monorepo, loginPath: "", streamServicesPath: "", shell: shell, tools: tools
        )
        Task {
            guard await checker.importSharedEnv(.booking) == true else { return }
            let wasLoad = hotelSourceNotice?.beforeReset == false
            hotelSourceNotice = nil
            onActionFeedback?("Shared .env imported — \(wasLoad ? "load the hotels" : "run the reset") again", true)
        }
    }

    /// True when the checkout's manifest has this DB profile. A banner hides a button
    /// whose profile the branch does not have.
    func manifestHasProfile(_ name: String) -> Bool {
        guard let cwd = supabaseCwd else { return false }
        let manifest = (cwd as NSString).appendingPathComponent("scripts/db/manifest.json")
        return DbManifestLoader.profileNames(from: manifest)?.contains(name) == true
    }

    func dismissHotelSourceNotice() {
        hotelSourceNotice = nil
    }

    func dismissHotelCatalogBanner() {
        hotelCatalogBannerDismissed = true
    }

    /// Reads the size of the hotel catalog, for the banner. A query that fails shows
    /// no banner. A new banner shows again after a dismiss.
    func refreshHotelCatalog(cwd: String) async {
        let count = HotelCatalog.count(await queryDatabase(cwd: cwd, sql: HotelCatalog.countSQL))
        var skipped: Bool?
        if let count, count < HotelCatalog.minimumHotels {
            skipped = await readBuiltFrom(cwd: cwd)?.hotelsSkipped
        }
        let notice = HotelCatalog.emptyNotice(count: count, hotelsSkipped: skipped)
        if notice != hotelCatalogNotice { hotelCatalogBannerDismissed = false }
        hotelCatalogNotice = notice
    }

    /// Why a DB setup ran. Each one is a `db_reset` event in `events.jsonl`.
    enum DbSetupOrigin: String, Sendable {
        case manual
        case retry
        /// One step from DB Tools, on its own.
        case singleStep = "single-step"
        case applyMigrations = "apply-migrations"
        /// An empty database during Start All. A failure stops the start.
        case emptyDatabaseAtStart = "empty-database-at-start"
        /// An empty database after a restart of Supabase or a branch switch.
        case emptyDatabase = "empty-database"
        /// Changed migrations, with the opt-in setting on.
        case autoResetSetting = "auto-reset-setting"

        var isAutomatic: Bool {
            switch self {
            case .manual, .retry, .singleStep, .applyMigrations: false
            case .emptyDatabaseAtStart, .emptyDatabase, .autoResetSetting: true
            }
        }
    }

    /// One DB setup between its start and its end.
    private struct DbSetupRun {
        let cwd: String
        let profile: String
        let reason: String?
        let origin: DbSetupOrigin
        let stepId: String?
        /// Runs only the step `stepId`, not the steps after it.
        let singleStep: Bool
        /// Nil when a test replaces the run with `dbResetAction`.
        let pipeline: DbSetupPipeline?
        let runner: DbSetupRunner?
    }

    /// The single entry point of every DB setup and reset. It holds the guard, files
    /// an issue for a failed step whatever the origin, and sets the error itself.
    /// `reason` is the text shown while it runs. True when every required step passed.
    @discardableResult
    func performDbSetup(
        cwd: String? = nil, profile: String, reason: String?, origin: DbSetupOrigin, from stepId: String? = nil
    ) async -> Bool {
        guard let run = beginDbSetup(cwd: cwd ?? supabaseCwd, profile: profile, reason: reason, origin: origin, from: stepId) else {
            // Start All stops before the portals: the header says so.
            if origin == .emptyDatabaseAtStart {
                let message = (lastError ?? "the setup did not start")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                lastError = DbResetPolicy.emptySetupFailedText(step: "setup", message: message)
            }
            return false
        }
        return await completeDbSetup(run)
    }

    /// The checks and the guard. Nil when nothing may start; the reason is then in
    /// `lastError`, or another setup runs.
    /// `reusePipeline` false builds a new pipeline for a step, also when one is shown.
    /// A single step gets a pipeline of that step alone, so its Retry and Run All
    /// never reach a reset. `stepArguments` go after the command of the step `stepId`
    /// ("Re-download hotels": `--force`); only that one-step pipeline holds them.
    private func beginDbSetup(
        cwd: String?, profile: String, reason: String?, origin: DbSetupOrigin, from stepId: String?,
        singleStep: Bool = false, reusePipeline: Bool = true, stepArguments: String? = nil
    ) -> DbSetupRun? {
        guard !dbResetRunning, dbSetupPipeline?.isRunning != true else { return nil }
        guard let cwd else {
            lastError = "Cannot find supabase service cwd in config"
            return nil
        }
        guard !refreshCompatibility(cwd: cwd) else { return nil }

        var pipeline: DbSetupPipeline?
        var runner: DbSetupRunner?
        var singleStep = singleStep
        if dbResetAction == nil {
            // A Retry or Run All of a shown pipeline reuses it. A step from DB Tools
            // does not reuse a one-step pipeline: that holds the arguments of its action.
            if reusePipeline, let stepId, let existingPipeline = dbSetupPipeline,
               existingPipeline.steps.contains(where: { $0.id == stepId }),
               !(singleStep && existingPipeline.isSingleStep) {
                pipeline = existingPipeline
                singleStep = singleStep || existingPipeline.isSingleStep
            } else {
                guard let newPipeline = makeDbSetupPipeline(cwd: cwd, profile: profile) else { return nil }
                if singleStep {
                    guard let step = newPipeline.steps.first(where: { $0.id == stepId }) else { return nil }
                    newPipeline.steps = [stepArguments.map { step.appending(arguments: $0) } ?? step]
                    newPipeline.isSingleStep = true
                }
                dbSetupPipeline = newPipeline
                pipeline = newPipeline
            }
            if let pipeline {
                runner = makeDbSetupRunner(cwd: cwd, pipeline: pipeline)
                dbSetupRunner = runner
            }
        }

        dbResetRunning = true
        lastError = reason
        migrationApplyError = nil
        migrationsAppliedNotice = nil
        hotelSourceNotice = nil
        portalRestartNotice = nil
        resetConfirmation = nil
        return DbSetupRun(
            cwd: cwd, profile: pipeline?.profile ?? profile, reason: reason, origin: origin,
            stepId: stepId, singleStep: singleStep, pipeline: pipeline, runner: runner
        )
    }

    private func completeDbSetup(_ run: DbSetupRun) async -> Bool {
        await waitForEnvResetOfLoad()
        let stepNote = run.singleStep ? ", step: \(run.stepId ?? "")" : ""
        await recordDebugEvent(
            kind: "db_reset", serviceID: nil,
            message: "origin: \(run.origin.rawValue), profile: \(run.profile)\(stepNote)"
        )
        let ok: Bool
        var failed: DbSetupStep?
        if let pipeline = run.pipeline, let runner = run.runner {
            if run.singleStep, let step = pipeline.steps.first(where: { $0.id == run.stepId }) {
                ok = await runner.executeStepPublic(step)
                if !ok, step.status != .cancelled { failed = step }
            } else {
                await runner.run(pipeline: pipeline, from: run.stepId)
                ok = pipeline.allRequiredPassed
                failed = pipeline.firstFailed
            }
        } else if let dbResetAction {
            ok = await dbResetAction(run.cwd)
        } else {
            ok = false
        }
        // A cancel unlocks the controls itself, and a new setup may run by now.
        if run.runner == nil || dbSetupRunner === run.runner { dbResetRunning = false }

        let isApply = !run.singleStep && run.profile == DbResetPolicy.migrateProfile
        if ok {
            lastError = nil
            if run.pipeline != nil { await refreshLocalSupabaseKeys() }
            if isApply {
                migrationsAppliedNotice = DbResetPolicy.appliedText
                onActionFeedback?("Migrations applied", true)
            } else if dbSetupFailedAtStart, !run.singleStep {
                // The start stays halted until Retry, so the header says what to do.
                lastError = DbResetPolicy.setUpAfterHaltText
            } else if Self.isReset(run.pipeline), !runningPortalIDs.isEmpty {
                // The portals still hold the old data (sessions, caches).
                portalRestartNotice = Self.portalRestartText
            }
        } else if let failed {
            let message = failed.errorMessage ?? "unknown error"
            lastError = run.origin == .emptyDatabaseAtStart
                ? DbResetPolicy.emptySetupFailedText(step: failed.name, message: message)
                : "DB setup failed at \(failed.name): \(message)"
            if isApply { migrationApplyError = message }
            // A stop because the hotels cannot be had: the banner offers the way out.
            var notice = HotelCatalog.sourceFailure(
                stepID: failed.id, exitCode: failed.exitCode, message: failed.errorMessage,
                resetRan: run.pipeline?.steps.contains { $0.id == "reset-database" && $0.status == .passed } == true
            )
            if notice?.beforeReset == true {
                // The reset it offers asks first, and names another checkout's data.
                let other = DbResetPolicy.otherCheckoutLine(
                    await readBuiltFrom(cwd: run.cwd),
                    current: DbResetPolicy.Checkout(path: run.cwd, branch: gitBranches["supabase"]),
                    project: SupabaseProject.projectName(root: run.cwd)
                )
                notice?.resetConfirmation = HotelCatalog.withoutHotelsConfirmation(otherCheckout: other)
            }
            hotelSourceNotice = notice
            await captureDbSetupFailure(failed, runner: run.runner)
        } else if let reason = run.reason, lastError == reason {
            // The run ended with no failed step: it was cancelled between two steps.
            lastError = Self.dbResetCancelledMessage
        }
        // The automatic callers read the database again themselves.
        if !run.origin.isAutomatic {
            await refreshPendingMigrations(cwd: run.cwd)
            if ok { await refreshHotelCatalog(cwd: run.cwd) }
        }
        // A fetch, or a load that found a stale dump, can have written a new dump.
        let dumpSteps: Set<String> = [HotelCatalog.fetchStepID, HotelCatalog.loadStepID]
        if run.pipeline?.steps.contains(where: { dumpSteps.contains($0.id) && $0.status != .pending }) == true {
            await refreshHotelDump()
        }
        return ok
    }

    // MARK: - After a reset

    nonisolated static let portalRestartText = "Database reset — restart portals to pick up fresh data"
    nonisolated static let restartPortalsTitle = "Restart portals"

    /// True when the pipeline reset the database: its reset step passed.
    private static func isReset(_ pipeline: DbSetupPipeline?) -> Bool {
        pipeline?.steps.contains { $0.id == "reset-database" && $0.status == .passed } == true
    }

    /// The portal services that run now.
    var runningPortalIDs: [String] {
        sortedServiceIDs.filter { id in
            guard let state = serviceStates[id] else { return false }
            return state.definition.phase == "portal" && (state.phase == .running || state.phase == .starting)
        }
    }

    /// "Restart portals": each portal that runs restarts on the fresh data.
    func restartPortals() {
        portalRestartNotice = nil
        for id in runningPortalIDs { restartService(id) }
    }

    func dismissPortalRestartNotice() {
        portalRestartNotice = nil
    }

    // MARK: - Reset confirmation

    /// Every reset button asks first. The confirmation names the scenario, what
    /// happens to the hotels, and another checkout that built the database.
    func askToResetDatabase() {
        guard !dbResetRunning, dbSetupPipeline?.isRunning != true else { return }
        let scenario = selectedDbSeedScenario?.name ?? "none selected"
        let cwd = supabaseCwd
        Task {
            var other: String?
            if let cwd {
                other = DbResetPolicy.otherCheckoutLine(
                    await readBuiltFrom(cwd: cwd),
                    current: DbResetPolicy.Checkout(path: cwd, branch: gitBranches["supabase"]),
                    project: SupabaseProject.projectName(root: cwd)
                )
            }
            resetConfirmation = DbResetPolicy.ResetRequest(
                message: DbResetPolicy.resetRequestText(scenario: scenario, hotels: hotelDump, otherCheckout: other),
                offersWithoutHotels: manifestHasProfile(HotelCatalog.withoutHotelsProfile)
            )
        }
    }

    func cancelResetConfirmation() {
        resetConfirmation = nil
    }

    // MARK: - Hotel dump

    /// Reads the cached hotel dump again, for DB Tools and the reset confirmation.
    func refreshHotelDump() async {
        guard let cwd = supabaseCwd else {
            hotelDump = .unknown
            return
        }
        let detail = await HotelCatalog.readCachedDump(
            monorepo: cwd, dumpPath: hotelDumpPath, shell: shell, cwd: cwd
        )
        hotelDump = detail.map { .cached($0) } ?? .missing
    }

    /// "Re-download hotels": the fetch step alone, with `--force`. It never resets.
    func redownloadHotels() {
        guard let run = beginDbSetup(
            cwd: supabaseCwd, profile: "reset", reason: nil, origin: .singleStep, from: HotelCatalog.fetchStepID,
            singleStep: true, reusePipeline: false, stepArguments: HotelCatalog.forceArgument
        ) else { return }
        Task { await completeDbSetup(run) }
    }

    /// True when the profile of the checkout's manifest has the step. A button for one
    /// step is hidden when the branch lacks it.
    func manifestProfileHasStep(_ profile: String, _ stepID: String) -> Bool {
        guard let cwd = supabaseCwd else { return false }
        let manifest = (cwd as NSString).appendingPathComponent("scripts/db/manifest.json")
        return DbManifestLoader.profiles(from: manifest)?[profile]?.contains(stepID) == true
    }

    // MARK: - Copy error + log

    /// "Copy error + log": the error, what to do and the whole log of the step,
    /// redacted, on the clipboard.
    func copyDbStepReport(_ step: DbSetupStep) {
        let report = DbSetupDiagnostics.report(
            stepName: step.name, stepID: step.id, status: step.status.rawValue, exitCode: step.exitCode,
            error: step.errorMessage, guidance: step.recoveryGuidance, log: step.logEntries.map(\.text)
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(makeRedactor().redact(report), forType: .string)
        onActionFeedback?("Copied the error and log of \(step.name)", true)
    }

    /// One step from DB Tools, on its own. It goes through the same guard, event and
    /// failure issue as every other setup.
    func runDbSetupStep(_ stepId: String) {
        guard let run = beginDbSetup(
            cwd: supabaseCwd, profile: singleStepProfile(stepId), reason: nil, origin: .singleStep, from: stepId,
            singleStep: true
        ) else { return }
        Task { await completeDbSetup(run) }
    }

    /// The profile that a single step is read from. The runner picks it, not the
    /// person, so a branch without `full` uses another profile that has the step.
    private func singleStepProfile(_ stepId: String) -> String {
        guard let cwd = supabaseCwd else { return "full" }
        let manifest = (cwd as NSString).appendingPathComponent("scripts/db/manifest.json")
        guard let profiles = DbManifestLoader.profiles(from: manifest) else { return "full" }
        let preferred = ["full", "reset"] + profiles.keys.sorted()
        return preferred.first { profiles[$0]?.contains(stepId) == true } ?? "full"
    }

    /// The issue of a failed DB step. It names the step and holds the step's log.
    /// A run that the developer cancelled files no issue.
    func captureDbSetupFailure(_ step: DbSetupStep, runner: DbSetupRunner? = nil) async {
        if let runner, await runner.wasCancelled { return }
        // The runner sends lines to the log store from detached tasks, so the last
        // lines can still be on their way. The step's own list is complete by now.
        let stored = await logStore.entries(for: step.logKey)
        let log = step.logEntries.count > stored.count ? step.logEntries : stored
        await captureDebugIssue(
            trigger: "db_setup_failure",
            serviceID: step.logKey,
            summary: "\(step.name) (\(step.id)): \(step.errorMessage ?? "unknown error")",
            log: log
        )
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
            // Same 0–1 scale as the view.
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

    /// Stops the DB step that runs and its process tree. The DB controls stay
    /// locked until the processes are gone.
    func cancelDbSetup() {
        guard let runner = dbSetupRunner else {
            dbResetRunning = false
            return
        }
        Task {
            await runner.cancel()
            if dbSetupRunner === runner { dbResetRunning = false }
        }
    }

    /// The pid of the DB step process that runs now. The app stops its tree as it quits.
    var dbStepProcessID: pid_t? { dbSetupRunner?.runningProcessID }

    func dismissDbSetup() {
        dbSetupPipeline = nil
    }

    func dismissMigrationsBanner() {
        migrationsBannerDismissed = true
    }

    /// Reads the checkout's `runner.minVersion` again, and sets or clears the banner.
    /// True when this runner is too old for the checkout: the caller must not reset
    /// the database or run a DB step.
    @discardableResult
    func refreshCompatibility(cwd: String) -> Bool {
        let notice = Compatibility.notice(for: Compatibility.check(root: cwd, runnerVersion: runnerVersion))
        if notice != compatibilityNotice { compatibilityNotice = notice }
        return notice != nil
    }

    /// The answer of the control API to a reset or a DB step while the runner is too
    /// old, or nil when the request may run.
    func resetBlockJSON() -> String? {
        guard let cwd = serviceCwd("supabase"), refreshCompatibility(cwd: cwd),
              let notice = compatibilityNotice else { return nil }
        let body: [String: Any] = [
            "ok": false,
            "error": "runner_too_old",
            "message": notice.text,
            "download_url": notice.downloadURL.absoluteString,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads how the database differs from the checkout, for the banner. A new
    /// banner shows again after a dismiss.
    func refreshPendingMigrations(cwd: String) async {
        let status = await migrationStatus(cwd: cwd)
        var notice: DbResetPolicy.Notice?
        if let status, !status.isCurrent {
            let builtFrom = await readBuiltFrom(cwd: cwd)
            let manifest = (cwd as NSString).appendingPathComponent("scripts/db/manifest.json")
            notice = DbResetPolicy.notice(
                status: status,
                baseline: await baselineLabel(cwd: cwd),
                builtFrom: builtFrom,
                current: DbResetPolicy.Checkout(path: cwd, branch: gitBranches["supabase"]),
                project: SupabaseProject.projectName(root: cwd),
                hasMigrateProfile: DbManifestLoader.profileNames(from: manifest)?.contains(DbResetPolicy.migrateProfile) == true
            )
        }
        if notice != migrationNotice { migrationsBannerDismissed = false }
        pendingMigrations = status?.missing ?? []
        migrationNotice = notice
        // An error of an apply belongs to the banner it came from.
        if notice == nil { migrationApplyError = nil }
    }

    /// "<backend checkout> @ <short sha>": what the expected migrations come from.
    private func baselineLabel(cwd: String) async -> String? {
        guard let dir = MigrationTracker.backendBaselineDir(root: cwd) else { return nil }
        let path = (dir as NSString).abbreviatingWithTildeInPath
        let result = await shell.run(
            ShellQuote.join(["git", "-C", dir, "rev-parse", "--short", "HEAD"]), cwd: cwd, timeout: .seconds(10)
        )
        let sha = result.exitCode == 0 ? DbQueryResult.lastLine(of: result.stdout) : nil
        return sha.map { "\(path) @ \($0)" } ?? path
    }

    /// Who built the database, from `travel_runner.seed_state`. Nil when no reset
    /// recorded it or the table cannot be read.
    private func readBuiltFrom(cwd: String) async -> DbResetPolicy.BuiltFrom? {
        let result = await queryDatabase(
            cwd: cwd, sql: "SELECT row_to_json(s) FROM travel_runner.seed_state s WHERE singleton"
        )
        guard result.exitCode == 0 else { return nil }
        return DbResetPolicy.BuiltFrom.parse(result.stdout)
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

    /// Looks at what the agent needs on this Mac: its packages, a Node that is new
    /// enough, and its env.
    private func prepareAgent(_ definition: ServiceDefinition) async -> AgentLauncher.Decision {
        guard let cwd = definition.resolvedCwd else { return .skip("The service has no folder.") }
        let hasPackages = FileManager.default.isExecutableFile(
            atPath: (cwd as NSString).appendingPathComponent("node_modules/.bin/eve")
        )
        // In the folder of the agent, so the answer is the Node that its start gets.
        let (output, ok) = await shellOutput("node --version", cwd: cwd)
        let installs = await Task.detached { NodeLocator.installs() }.value
        let sharedEnv = sharedEnvPath("travel-portal") ?? ""
        var plan = AgentEnv.plan(agentDirectory: cwd, sharedEnvFile: sharedEnv)
        if let eventDirectory = serviceStates[ServiceCatalog.eventDirectoryID]?.definition.resolvedCwd {
            let current = plan
            plan = await Task.detached {
                AgentEnv.withEventDirectoryValues(
                    current,
                    own: AgentEnv.ownValues(directory: cwd),
                    event: EventDirectoryEnv.values(directory: eventDirectory)
                )
            }.value
        }
        if hasPackages, !plan.ownsProjectToken, let eventDirectory = await linkedEventDirectory() {
            let (token, _) = await shellOutput(AgentEnv.projectTokenCommand(eventDirectory: eventDirectory))
            plan = AgentEnv.withProjectToken(plan, commandOutput: token)
        }
        return AgentLauncher.decide(
            hasPackages: hasPackages,
            defaultNodeMajor: ok ? NodeLocator.major(ofVersionOutput: output) : nil,
            installs: installs,
            env: plan
        )
    }

    /// The folder of the event directory, when it has its packages and the link to
    /// its Vercel project. Writes the link when the env file names the project: the
    /// agent can start before the event directory does.
    private func linkedEventDirectory() async -> String? {
        guard let directory = serviceStates[ServiceCatalog.eventDirectoryID]?.definition.resolvedCwd else { return nil }
        return await Task.detached {
            let library = (directory as NSString).appendingPathComponent("node_modules/@vercel/oidc")
            guard FileManager.default.fileExists(atPath: library) else { return nil }
            EventDirectoryEnv.linkFromEnv(directory: directory)
            return EventDirectoryEnv.isLinked(directory: directory) ? directory : nil
        }.value
    }

    /// Looks at what platform core needs on this Mac: its folder with the script of the
    /// fork, its packages and its env.
    private func preparePlatformCore(_ definition: ServiceDefinition) async -> PlatformCoreLauncher.Decision {
        guard let cwd = definition.resolvedCwd else { return .skip("The service has no folder.") }
        let runnerPort = definition.probe?.port
        return await Task.detached {
            let launch = PlatformCoreApp.launch(directory: cwd)
            return PlatformCoreLauncher.decide(
                launch: launch,
                runnerPort: runnerPort,
                hasPackages: FileManager.default.isExecutableFile(
                    atPath: (cwd as NSString).appendingPathComponent("node_modules/.bin/next")
                ),
                missingKeys: PlatformCoreEnv.missingKeys(
                    PlatformCoreEnv.values(directory: cwd, envFiles: launch?.envFiles ?? [])
                )
            )
        }.value
    }

    /// Looks at what the event directory needs on this Mac: its folder, its packages
    /// and its env. Writes the Vercel project link when the env file names the project.
    private func prepareEventDirectory(_ definition: ServiceDefinition) async -> EventDirectoryLauncher.Decision {
        guard let cwd = definition.resolvedCwd,
              FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent("package.json")) else {
            return .skip("This checkout does not have \(RepoDetector.eventDirectory). Pull the fork, then restart the event directory.")
        }
        return await Task.detached {
            let values = EventDirectoryEnv.values(directory: cwd)
            let missing = EventDirectoryEnv.missingKeys(values)
            let claims = EventDirectoryEnv.claims(ofToken: values[EventDirectoryEnv.tokenKey])
            let wroteLink = EventDirectoryEnv.linkFromEnv(directory: cwd)
            return EventDirectoryLauncher.decide(
                hasPackages: FileManager.default.isExecutableFile(
                    atPath: (cwd as NSString).appendingPathComponent("node_modules/.bin/next")
                ),
                missingKeys: missing,
                access: EventDirectoryEnv.access(
                    claims: claims,
                    linked: EventDirectoryEnv.isLinked(directory: cwd),
                    hasLogin: EventDirectoryEnv.hasVercelLogin()
                ),
                wroteLink: wroteLink,
                env: EventDirectoryEnv.processEnv(values)
            )
        }.value
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

    /// The apps whose `.env.local` gets the local stack's keys, with their shared env file.
    private static let localKeyApps: [String: String] = [
        "travel-portal": "apps/booking-portal/.env",
        "partner-portal": "apps/partner-portal/.env",
    ]

    /// What `awaitReady` needs to know about the process that `spawnService` started.
    private struct ServiceLaunch {
        let pid: Int32
        let definition: ServiceDefinition
        let stdoutProbe: StdoutProbe?
        let artifactName: String?
    }

    /// Starts one service and waits until it is ready.
    private func startService(_ serviceID: String) async throws {
        let launch = try await lifecycle.withLock(serviceID) { try await spawnService(serviceID) }
        if let launch { try await awaitReady(serviceID, launch) }
    }

    /// Starts the service's process. The caller holds the service's lock. Returns nil
    /// when there is no process to wait for: the service is skipped or reused, or a
    /// stop-all is in progress.
    private func spawnService(_ serviceID: String) async throws -> ServiceLaunch? {
        guard let state = serviceStates[serviceID],
              let definition = graph?.nodes[serviceID] else { return nil }

        guard !isShuttingDown, health != .stopped else {
            // Stop-all won. Do not leave the service marked as on its way up.
            if state.phase == .starting || state.phase == .pending { state.phase = .stopped }
            return nil
        }

        // Services outside the active profile are skipped. The verification
        // oneshots drive the local CDC evidence chain against the dev fixture, so
        // they run only in the full profile.
        if !isInProfile(serviceID) {
            state.phase = .skipped
            return nil
        }

        // A probe with a missing or wrong field: say so, and start nothing.
        if let problem = definition.probe?.problem {
            throw ServiceError.badProbe(name: definition.displayName, reason: problem)
        }

        // Reuse-if-running: Docker-managed services (Supabase) persist between sessions.
        // If the port is already bound, skip starting and mark as running.
        if definition.shouldReuseIfRunning, let port = definition.probe?.port {
            if isPortBound(port) {
                // Only reuse the monorepo's own database. Another checkout's stack (the
                // old travel-booking-portal one, say) on the same port is a different DB.
                if serviceID == "supabase", let root = definition.resolvedCwd {
                    let expected = SupabaseProject.dbContainerName(root: root)
                    if let occupant = await Self.containerPublishing(port: port, shell: shell), occupant != expected {
                        await logStore.append(serviceID: serviceID, entry: LogEntry(
                            stream: .stderr,
                            text: "[travel-runner] Port \(port) is held by \(occupant), not \(expected). Stop that stack (npx supabase stop in its checkout, or: docker stop $(docker ps -q --filter name=_\(occupant.replacingOccurrences(of: "supabase_db_", with: ""))$)) and start again."
                        ))
                        throw ServiceError.portHeldByOtherStack(port: port, container: occupant)
                    }
                }
                state.phase = .running
                state.lastStarted = clock.date()
                state.readyAt = clock.date()
                return nil
            }
        }

        // Skip Stripe if the CLI isn't installed or authenticated
        if serviceID == "stripe" {
            let available = await isStripeAvailable()
            if !available {
                state.phase = .skipped
                let cause = "the Stripe CLI is not installed or not logged in — run: stripe login, then start it from its row"
                await logStore.append(
                    serviceID: serviceID,
                    entry: LogEntry(stream: .stderr, text: Self.stripeStoppedLine(cause))
                )
                await recordDebugEvent(kind: "stripe_skip", serviceID: serviceID, message: cause)
                return nil
            }
        }

        // The agent needs its packages and Node 24 or later. Without them it is
        // skipped, as Stripe is: the portals do not need the agent.
        var agentLaunch: AgentLauncher.Launch?
        if serviceID == ServiceCatalog.agentID {
            switch await prepareAgent(definition) {
            case .skip(let reason):
                state.phase = .skipped
                await logStore.append(
                    serviceID: serviceID,
                    entry: LogEntry(stream: .stderr, text: "[travel-runner] The agent is skipped. \(reason)")
                )
                return nil
            case .run(let launch):
                agentLaunch = launch
                for note in launch.notes {
                    await logStore.append(
                        serviceID: serviceID,
                        entry: LogEntry(stream: .stdout, text: "[travel-runner] \(note)")
                    )
                }
            }
        }

        // Platform core needs its packages and its env file. Without them it is
        // skipped, and the rest of the stack starts.
        if serviceID == ServiceCatalog.platformCoreID {
            switch await preparePlatformCore(definition) {
            case .skip(let reason):
                state.phase = .skipped
                await logStore.append(
                    serviceID: serviceID,
                    entry: LogEntry(stream: .stderr, text: "[travel-runner] Platform core is skipped. \(reason)")
                )
                return nil
            case .run(let notes):
                for note in notes {
                    await logStore.append(
                        serviceID: serviceID,
                        entry: LogEntry(stream: .stdout, text: "[travel-runner] \(note)")
                    )
                }
            }
        }

        // The event directory needs its packages and its env file. Without them it is
        // skipped, and the rest of the stack starts.
        var eventDirectoryEnv: [String: String] = [:]
        if serviceID == ServiceCatalog.eventDirectoryID {
            switch await prepareEventDirectory(definition) {
            case .skip(let reason):
                state.phase = .skipped
                await logStore.append(
                    serviceID: serviceID,
                    entry: LogEntry(stream: .stderr, text: "[travel-runner] The event directory is skipped. \(reason)")
                )
                return nil
            case .run(let notes, let env):
                eventDirectoryEnv = env
                for note in notes {
                    await logStore.append(
                        serviceID: serviceID,
                        entry: LogEntry(stream: .stdout, text: "[travel-runner] \(note)")
                    )
                }
            }
        }

        // The booking portal of the fork shows the chat of the agent when it knows the
        // address of the agent (AMATEUR_AGENT_URL). The runner gives it the agent that it
        // started, when the portal's own env files do not set an address.
        if Flavor.current.runsAgent, serviceID == ServiceCatalog.bookingPortalID,
           serviceStates[ServiceCatalog.agentID]?.phase != .skipped,
           let cwd = definition.resolvedCwd {
            let env = await Task.detached {
                EventDirectoryEnv.processEnv(EventDirectoryEnv.values(directory: cwd))
            }.value
            eventDirectoryEnv = env
            if let agent = env[EventDirectoryEnv.agentURLKey] {
                await logStore.append(
                    serviceID: serviceID,
                    entry: LogEntry(
                        stream: .stdout,
                        text: "[travel-runner] The chat of the portal uses the agent of the runner (\(EventDirectoryEnv.agentURLKey)=\(agent))."
                    )
                )
            }
        }

        // Local mode puts the local stack's keys into the app's .env.local. Without
        // them the app has no signing key, or it takes the hosted dev values from its
        // shared .env while the runner shows "local". Read the keys again, and do
        // not start the app when they are still unknown.
        if dbMode == .local, let envFile = Self.localKeyApps[serviceID], localSupabaseKeys == nil {
            await refreshLocalSupabaseKeys()
            guard localSupabaseKeys != nil else {
                throw ServiceError.localKeysMissing(name: definition.displayName, envFile: envFile)
            }
        }

        if !definition.shouldReuseIfRunning {
            // A process of this service that the runner still tracks would fight the
            // new one for the port. Callers stop it first; this covers one that did not.
            await processRunner.stop(serviceID: serviceID)

            // Kill any stale occupant on the port
            if let port = definition.probe?.port, definition.resolvedType == .daemon, isPortBound(port) {
                // The port frees only when a listener was killed. With none killed
                // (a container holds it) there is nothing to wait for.
                if await killPortOccupants(port) {
                    for _ in 0..<10 {
                        try? await clock.sleep(for: .milliseconds(500))
                        if !isPortBound(port) { break }
                    }
                }
                // A container still has the port: the service would fail with
                // EADDRINUSE while its TCP probe passes against the container.
                if isPortBound(port),
                   let owner = await portTools.listeners(port).first(where: { PortOwner.isContainerRuntime($0.command) }) {
                    throw ServiceError.portHeldByContainer(name: definition.displayName, port: port, owner: owner.command)
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
                state.phase = .starting
                state.lastStarted = clock.date()
                // Wait up to 30s for Stripe to capture its secret
                for _ in 0..<60 {
                    if let _ = await secretStore.get("STRIPE_WEBHOOK_SECRET") { break }
                    try? await clock.sleep(for: .milliseconds(500))
                }
            }
        }

        // A start during a read of the shell waits for the new PATH. The wait is
        // here, before the last check for a stop: the process runner must not
        // wait, or a stop-all in that time sees no process and the start runs one.
        await tools.settled()

        // The waits above can outlast a stop-all.
        guard !isShuttingDown, health != .stopped else {
            if state.phase == .starting || state.phase == .pending { state.phase = .stopped }
            return nil
        }

        state.phase = .starting
        state.lastStarted = clock.date()
        state.readyAt = nil
        state.exitCode = nil
        // No pid until the new process has one: handleTermination compares it.
        state.pid = nil

        var stdoutProbe: StdoutProbe?
        if let probeConfig = definition.probe, probeConfig.type == .stdoutRegex {
            do {
                stdoutProbe = try StdoutProbe(pattern: probeConfig.pattern ?? "")
            } catch {
                throw ServiceError.badProbe(name: definition.displayName, reason: "\(error)")
            }
            stdoutProbes[serviceID] = stdoutProbe
        }

        let logStore = self.logStore
        let secretStore = self.secretStore
        let artifactName = definition.probe?.artifact
        let capturedProbe = stdoutProbe
        let streamDefinition = streamAwareDefinition(for: definition, serviceID: serviceID)
        let lanDefinition = lanAwareDefinition(for: streamDefinition, serviceID: serviceID)
        let agentDefinition = agentLaunch.map { AgentLauncher.definition(lanDefinition, launch: $0) } ?? lanDefinition
        let effectiveDefinition = EventDirectoryLauncher.definition(agentDefinition, env: eventDirectoryEnv)

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
                                    guard let now = self?.clock.date() else { return }
                                    if self?.stripeReconnectingSince == nil {
                                        self?.stripeReconnectingSince = now
                                    }
                                    if let since = self?.stripeReconnectingSince,
                                       now.timeIntervalSince(since) > 120 {
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
            onTermination: { [weak self] termination in
                Task { @MainActor in self?.handleTermination(serviceID: sid, termination: termination) }
            }
        )

        state.pid = pid
        await logStore.markStart(serviceID: sid, name: definition.displayName, pid: pid)
        return ServiceLaunch(
            pid: pid, definition: effectiveDefinition, stdoutProbe: capturedProbe, artifactName: artifactName
        )
    }

    /// Waits until the process that `spawnService` started is ready, then marks the
    /// service as running. It holds no lock.
    private func awaitReady(_ serviceID: String, _ launch: ServiceLaunch) async throws {
        guard let state = serviceStates[serviceID] else { return }

        // Oneshots: wait for exit
        if launch.definition.resolvedType == .oneshot {
            while true {
                if state.phase == .completed { return }
                if state.phase == .failed {
                    throw ServiceError.oneshotFailed(serviceID)
                }
                // Stopped before it finished: stop-all, or a new run replaced this one.
                if isShuttingDown || state.phase == .stopping || state.phase == .stopped { return }
                if let exit = await processRunner.exit(of: launch.pid), exit.stoppedByRunner { return }
                try await clock.sleep(for: .milliseconds(250))
            }
        }

        // Daemons: wait for the probe (the launch's definition has the LAN-aware host)
        if let probeConfig = launch.definition.probe {
            let probe: Probe = if let sp = launch.stdoutProbe { sp } else { try ProbeFactory.makeProbe(for: probeConfig) }
            let deadline = clock.uptime() + probeConfig.resolvedTimeout
            var ready = false
            while clock.uptime() < deadline {
                if await probe.check() {
                    ready = true
                    break
                }
                if let exit = await processRunner.exit(of: launch.pid),
                   try await !shouldKeepWaiting(for: state, after: exit) {
                    return
                }
                try await clock.sleep(for: .seconds(2))
            }
            if !ready {
                let seconds = probeConfig.timeout ?? 120
                // Every start path throws from here, so one capture covers them all.
                // An automatic restart can replace this launch's process during the
                // wait, so the answer comes from the service's current process.
                var alive = "no"
                if let pid = state.pid {
                    if let exit = await processRunner.exit(of: pid) {
                        if state.definition.shouldReuseIfRunning, ServiceTermination.classify(exit) == .cleanExit {
                            alive = "no; the launcher ended cleanly and its containers may still run"
                        }
                    } else {
                        alive = "yes"
                    }
                }
                let name = state.definition.displayName
                // The signature leaves out the details, so the waiters of one startup
                // (the first launch and its restart) file one issue.
                Task { await self.captureDebugIssue(
                    trigger: "probe_timeout",
                    serviceID: serviceID,
                    summary: "\(name) did not pass its startup probe in \(seconds)s (process alive: \(alive))",
                    signature: "startup probe timeout"
                )}
                throw ServiceError.probeTimeout(serviceID, seconds: seconds)
            }
        }

        // If this service produces an artifact (e.g. Stripe secret), ensure it's
        // written to .env.local BEFORE we mark the service as running and unblock
        // dependents. The onChange observer fires async, so we do a direct write here.
        if let name = launch.artifactName {
            // Brief wait for the async secretStore.set() Task to complete
            try? await clock.sleep(for: .milliseconds(200))
            if let value = await secretStore.get(name) {
                recordArtifact(name, value: value)
                state.capturedArtifact = value
            }
        }

        // A stop can win while the probe passes; the stop owns the state then.
        guard !isShuttingDown, state.phase != .stopping, state.phase != .stopped, state.phase != .skipped else { return }

        // The process can end at the moment its probe passes. Then handleTermination
        // owns the state, unless a newer process of the service runs.
        if await processRunner.exit(of: launch.pid) != nil,
           !launch.definition.shouldReuseIfRunning,
           !(await processRunner.isRunning(serviceID: serviceID)) {
            return
        }

        state.phase = .running
        if state.readyAt == nil { state.readyAt = clock.date() }
    }

    /// The process of a launch ended before its probe passed. Returns true to keep
    /// waiting and false to stop without an error. Throws when the start failed.
    private func shouldKeepWaiting(for state: ServiceState, after exit: ProcessRunner.Termination) async throws -> Bool {
        switch ServiceTermination.classify(exit) {
        case .stoppedByRunner:
            // Stop-all, or another operation replaced this process and owns the state.
            return false
        case .cleanExit:
            // The launcher of a container-managed service ends while the stack still starts.
            if state.definition.shouldReuseIfRunning { return true }
            // Stripe degrades to skipped; handleTermination owns its state.
            if state.id == "stripe" { return false }
            throw ServiceError.exitedDuringStartup(state.id)
        case .commandNotRunnable(let code):
            let tool = await missingTool(forExit: code, pid: exit.pid, of: state.definition)
            // The question takes time. A stop, or a newer launch, owns the state now.
            if isShuttingDown || state.phase == .stopping || state.phase == .stopped { return false }
            if let current = state.pid, current != exit.pid { return false }
            throw ServiceError.commandNotRunnable(
                name: state.definition.displayName, command: state.definition.cmd.first ?? "its command", code: code,
                tool: tool
            )
        case .killedExternally, .crashed:
            // Stripe degrades to skipped when its CLI fails.
            if state.phase == .skipped { return false }
            // A stop-all or another operation took over after the failure.
            if isShuttingDown || health == .stopped || state.phase == .stopped { return false }
            if state.isCircuitBroken {
                // The reason is in lastError: a crash loop, or a container runtime that is down.
                throw ServiceError.autoRestartStopped(
                    lastError ?? "\(state.definition.displayName) keeps failing — auto-restart stopped; see its log"
                )
            }
            // The supervisor restarts a failed daemon, and the new process can pass this probe.
            if state.definition.resolvedRestart == .onFailure { return true }
            throw ServiceError.exitedDuringStartup(state.id)
        }
    }

    /// What exit 127 means when the PATH of the launch did not have the tool of
    /// the service. It reads the shell again. Nil for a script path, and when the
    /// PATH of the launch had the tool.
    private func missingTool(
        forExit code: Int32, pid: Int32, of definition: ServiceDefinition
    ) async -> ToolEnvironment.MissingTool? {
        guard code == 127, let tool = ToolEnvironment.toolName(of: definition.cmd) else { return nil }
        if let known = missingToolDiagnoses[definition.id], known.pid == pid { return await known.task.value }
        let (tools, shell, cwd) = (tools, shell, definition.resolvedCwd)
        let task = Task { await tools.diagnoseMissing(tool: tool, cwd: cwd, runner: shell) }
        missingToolDiagnoses[definition.id] = (pid, task)
        return await task.value
    }

    private func handleTermination(serviceID: String, termination: ProcessRunner.Termination) {
        guard let state = serviceStates[serviceID] else { return }
        let kind = ServiceTermination.classify(termination)

        // The runner stopped this process itself: a restart, a mode switch, wake
        // recovery, or stop-all. The operation that stopped it owns the next state.
        // The mark belongs to the launch, so a process that takes long to die
        // cannot fail the one that started after it.
        if kind == .stoppedByRunner { return }

        // An older process of this service, not the one the state describes.
        if let current = state.pid, current != termination.pid { return }

        // During shutdown, don't overwrite the .stopped/.stopping state
        if isShuttingDown || state.phase == .stopping || state.phase == .stopped {
            return
        }

        let name = state.definition.displayName

        // Stripe is an optional local gateway. A stale/expired CLI session must
        // degrade to "skipped", not enter the daemon crash loop (and emit a
        // notification on every retry). The next manual/full start re-runs the
        // credential probe and will enable Stripe again once `stripe login`
        // succeeds.
        if serviceID == "stripe" {
            state.phase = .skipped
            state.exitCode = termination.status
            state.pid = nil
            state.lastStopped = clock.date()
            state.failureTimestamps.removeAll()
            let exit = "the Stripe CLI \(ServiceTermination.describe(termination))"
            // The log keeps the lines of earlier launches. An old 401 is not the
            // cause of this exit.
            let launched = state.lastStarted ?? .distantPast
            Task {
                let output = await logStore.entries(for: serviceID)
                    .filter { $0.timestamp >= launched }.map(\.text)
                let cause = if let known = CrashCause.knownCause(in: output, serviceID: serviceID) {
                    "\(exit) — \(known)"
                } else {
                    "\(exit) — see the lines above. If they show 401, run: stripe login. Then start it from its row."
                }
                await logStore.append(serviceID: serviceID, entry: LogEntry(
                    stream: .stderr, text: Self.stripeStoppedLine(cause)
                ))
                await recordDebugEvent(kind: "stripe_skip", serviceID: serviceID, message: cause)
            }
            recalculateHealth()
            return
        }

        if state.definition.resolvedType == .oneshot {
            state.phase = kind == .cleanExit ? .completed : .failed
            state.exitCode = termination.status
            return
        }

        state.exitCode = termination.status
        let uptime = state.lastStarted.map { clock.date().timeIntervalSince($0) }
        // Time in the ready state. A service that never became ready has none, so a
        // slow failure (two minutes to give up) does not start a new series each time.
        let stableFor = state.readyAt.map { clock.date().timeIntervalSince($0) }
        let restarts = state.definition.resolvedRestart == .onFailure

        switch kind {
        case .stoppedByRunner:
            return

        case .cleanExit:
            // The launcher of a container-managed service (Supabase) ends when the
            // stack is up, or while it still starts. The service itself runs on.
            if state.definition.shouldReuseIfRunning {
                if state.phase == .starting { return }
                if let port = state.definition.probe?.port, isPortBound(port) { return }
            }
            // The daemon ended by itself and nothing starts it again. "Failed" makes
            // the environment degraded; "stopped" left it at "starting" with no end.
            // It is not a crash: no notification and no debug issue.
            state.phase = .failed
            state.lastStopped = clock.date()
            // The header shows the banner only with a text: say which service ended.
            lastError = Self.cleanExitMessage(name)
            Task { await logStore.append(serviceID: serviceID, entry: LogEntry(
                stream: .stderr, text: "[travel-runner] \(name) exited (code 0) — not restarted"
            ))}

        case .killedExternally(let signal):
            // Someone stopped it from outside: `kill`, a script that frees the port.
            // The service did not fail, so there is no crash notification and no
            // debug issue. It still counts toward the circuit breaker: three kills
            // in a minute mean that something else wants the port.
            state.phase = .failed
            state.lastStopped = clock.date()
            noteFailure(state, stableFor: stableFor)
            let action = restarts ? "restarting it" : "it stays stopped"
            let killed = "\(name) was stopped from outside Travel Runner (\(ServiceTermination.signalName(signal))) — \(action)"
            Task {
                await logStore.append(serviceID: serviceID, entry: LogEntry(
                    stream: .stderr, text: "[travel-runner] \(killed)"
                ))
                await recordDebugEvent(kind: "outside_kill", serviceID: serviceID, message: killed)
            }
            if restarts {
                scheduleRestart(serviceID: serviceID, wasEarlyExit: (uptime ?? 0) < 10)
            }

        case .commandNotRunnable(let code):
            // Exit 126/127: the shell could not run the command. The same command
            // fails again, so there is no automatic restart.
            state.phase = .failed
            state.lastStopped = clock.date()
            let command = state.definition.cmd.first ?? "its command"
            let plain = ServiceError.commandNotRunnable(name: name, command: command, code: code).description
            lastError = plain
            let definition = state.definition
            Task {
                guard let tool = await missingTool(forExit: code, pid: termination.pid, of: definition) else { return }
                let line = switch tool {
                case .notFound(let path): ToolEnvironment.notFoundText(tool: command, searchedPath: path)
                case .foundNow(let path): ToolEnvironment.foundNowText(name: name, tool: command, path: path)
                }
                await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stderr, text: "[travel-runner] \(line)"))
                // A newer error stays.
                if lastError == plain {
                    lastError = ServiceError.commandNotRunnable(
                        name: name, command: command, code: code, tool: tool
                    ).description
                }
            }
            onServiceCrash?(name, code)
            Task { await captureDebugIssue(
                trigger: "service_crash",
                serviceID: serviceID,
                summary: "\(name) \(ServiceTermination.describe(termination))"
            )}

        case .crashed:
            state.phase = .failed
            state.lastStopped = clock.date()
            noteFailure(state, stableFor: stableFor)
            if !state.isCircuitBroken {
                onServiceCrash?(name, termination.status)
                Task { await captureDebugIssue(
                    trigger: "service_crash",
                    serviceID: serviceID,
                    summary: "\(name) \(ServiceTermination.describe(termination))"
                )}
            }
            if restarts {
                scheduleRestart(serviceID: serviceID, wasEarlyExit: (uptime ?? 0) < 10)
            }
        }
        recalculateHealth()
    }

    /// Records one failure of a daemon. A service that ran for a while before it
    /// failed starts a new series: the restart count and the backoff start again.
    private func noteFailure(_ state: ServiceState, stableFor: TimeInterval?, countsTowardBreaker: Bool = true) {
        if AutoRestart.startsNewSeries(uptime: stableFor) {
            state.restartCount = 0
        }
        if countsTowardBreaker {
            state.failureTimestamps.append(clock.date())
        }
    }

    private func scheduleRestart(serviceID: String, wasEarlyExit: Bool = false) {
        guard let state = serviceStates[serviceID] else { return }
        let name = state.definition.displayName

        state.failureTimestamps = AutoRestart.recentFailures(state.failureTimestamps, now: clock.date())
        let baseDelay: TimeInterval
        switch AutoRestart.decide(recentFailureCount: state.failureTimestamps.count, restartCount: state.restartCount) {
        case .crashLoop:
            state.isCircuitBroken = true
            lastError = "\(name) is crash-looping — auto-restart stopped"
            Task { await recordDebugEvent(
                kind: "breaker_trip", serviceID: serviceID, message: "\(name) is crash-looping — auto-restart stopped"
            )}
            Task { await captureDebugIssue(
                trigger: "circuit_breaker",
                serviceID: serviceID,
                summary: "\(name) crash-looping — circuit breaker tripped"
            )}
            return
        case .exhausted:
            if serviceID == "stripe" {
                // The network stayed down. Stripe is optional: it degrades to skipped,
                // and the next start (manual, start-all, or a wake) tries it again.
                state.phase = .skipped
                let cause = "no network after \(AutoRestart.maxRestarts) tries — start it from its row when the network is back"
                Task {
                    await logStore.append(serviceID: serviceID, entry: LogEntry(
                        stream: .stderr, text: Self.stripeStoppedLine(cause)
                    ))
                    await recordDebugEvent(kind: "stripe_skip", serviceID: serviceID, message: cause)
                }
                recalculateHealth()
                return
            }
            state.isCircuitBroken = true
            lastError = "\(name) did not come back after \(AutoRestart.maxRestarts) restarts — auto-restart stopped"
            Task { await recordDebugEvent(
                kind: "breaker_trip", serviceID: serviceID,
                message: "\(name) did not come back after \(AutoRestart.maxRestarts) restarts — auto-restart stopped"
            )}
            Task { await captureDebugIssue(
                trigger: "circuit_breaker",
                serviceID: serviceID,
                summary: "\(name) failed \(AutoRestart.maxRestarts) restarts in a row — auto-restart stopped"
            )}
            return
        case .restart(let after):
            baseDelay = after
        }

        let delay = (serviceID == "stripe" && wasEarlyExit) ? max(baseDelay, 15.0) : baseDelay
        Task {
            try? await clock.sleep(for: .seconds(delay))
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

            // A service that failed because the container runtime is down fails again
            // at once. Start the runtime first; if it does not come up, say so and stop.
            let recentLines = await logStore.entries(for: serviceID).map(\.text)
            if CrashCause.showsContainerRuntimeDown(recentLines), !(await ContainerRuntime.isResponding()) {
                let runtime = ContainerRuntime.detect()
                await logStore.append(serviceID: serviceID, entry: LogEntry(
                    stream: .stdout,
                    text: "[travel-runner] \(runtime.displayName) is not running — starting it before the restart of \(name)"
                ))
                guard await ContainerRuntime.ensureRunning(clock: clock) else {
                    state.isCircuitBroken = true
                    lastError = "\(runtime.displayName) is not running — open \(runtime.appName), then restart \(name)"
                    await recordDebugEvent(
                        kind: "breaker_trip", serviceID: serviceID,
                        message: "\(runtime.displayName) is not running — the restart of \(name) stopped"
                    )
                    return
                }
                guard serviceStates[serviceID]?.phase == .failed else { return }
            }

            await autoRestart(serviceID)
        }
    }

    // MARK: - Private: Health

    func recalculateHealth() {
        let daemonStates = serviceStates.values
            .filter { $0.definition.resolvedType != .oneshot }
            .map(\.phase)

        if daemonStates.allSatisfy({ $0 == .stopped || $0 == .pending }) {
            health = .stopped
        } else if daemonStates.contains(.failed) || dbSetupFailedAtStart {
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

    func handleWake() {
        guard health == .healthy || health == .degraded else { return }

        // Wake notifications can come in pairs a few seconds apart. Two passes at
        // once probe the same services, and both restart the ones that fail.
        if isHandlingWake {
            // A notification that comes long after the pass started is a new wake:
            // the machine slept again in the middle of the pass.
            if let started = wakePassStartedAt, clock.date().timeIntervalSince(started) > 30 {
                wakePending = true
            }
            return
        }
        isHandlingWake = true

        Task {
            repeat {
                wakePending = false
                wakePassStartedAt = clock.date()
                await runWakeChecks()
            } while wakePending && (health == .healthy || health == .degraded)
            isHandlingWake = false
            wakePassStartedAt = nil
        }
    }

    private func runWakeChecks() async {
        try? await clock.sleep(for: .seconds(3))

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
                try? await clock.sleep(for: .seconds(3))
            }
            if currentIP.isEmpty {
                await logStore.append(
                    serviceID: "travel-portal",
                    entry: LogEntry(stream: .stdout, text: "[travel-runner] No LAN IP ~20s after wake — switching back to localhost mode")
                )
                await killWebServicePorts()
                networkMode = false
                applyNetworkMode()
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
            guard let probe = try? ProbeFactory.makeProbe(for: effectiveProbe) else { continue }
            let ok = (try? await waitForProbe(probe, timeout: .seconds(15), interval: .seconds(3))) ?? false
            // A restart or a stop can start while the probe runs; it owns the state then.
            guard state.phase == .running else { continue }
            if !ok {
                noteFailure(state, stableFor: state.readyAt.map { clock.date().timeIntervalSince($0) }, countsTowardBreaker: false)
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
                guard state.phase == .running else { continue }
                if !healthy {
                    await logStore.append(
                        serviceID: serviceID,
                        entry: LogEntry(stream: .stderr, text: "[travel-runner] \(state.definition.displayName) answers TCP but fails HTTP check after wake — killing port \(port) and restarting")
                    )
                    noteFailure(state, stableFor: state.readyAt.map { clock.date().timeIntervalSince($0) }, countsTowardBreaker: false)
                    state.phase = .failed
                    recalculateHealth()
                    await lifecycle.withLock(serviceID) {
                        await processRunner.stop(serviceID: serviceID)
                        await killPortOccupants(port)
                    }
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

    // MARK: - Debug Tracking

    /// Starts issue capture. A config reload comes here again: the tracker, its
    /// poll and the launch prune stay single.
    func initDebugTracking() async {
        let tracker = currentIssueTracker()
        let prune = !issueLaunchPruneDone
        issueLaunchPruneDone = true
        startIssueCapturePoll()
        await refreshIssueCapture()
        if prune, debugTracker != nil {
            await tracker.pruneClosedIssues()
        }
    }

    /// The one tracker of this run. It holds the rate limit.
    private func currentIssueTracker() -> DebugTracker {
        if let issueTracker { return issueTracker }
        let tracker = debugTracker ?? makeIssueTracker()
        issueTracker = tracker
        return tracker
    }

    /// The config can change on disk, and issues can be closed there.
    private func startIssueCapturePoll() {
        guard !issueCapturePollStarted else { return }
        issueCapturePollStarted = true
        let (interval, clock) = (issueCapturePollInterval, clock)
        Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: interval)
                guard let self else { return }
                await self.refreshIssueCapture()
            }
        }
    }

    /// Reads the switch and the open count from the issue folder.
    private func refreshIssueCapture() async {
        guard let tracker = issueTracker else { return }
        let enabled = await tracker.isEnabled()
        let count = enabled ? await tracker.openIssueCount() : 0
        debugTracker = enabled ? tracker : nil
        debugTrackingEnabled = enabled
        debugOpenIssueCount = count
    }

    /// The switch in Settings. It is saved in the config of the issue folder.
    func setIssueCaptureEnabled(_ enabled: Bool) async {
        let tracker = currentIssueTracker()
        guard await tracker.setEnabled(enabled) else {
            let path = await tracker.configFilePath
            onActionFeedback?(
                "Issue capture: could not write \(path). Check that the folder is writable, then try again.", false
            )
            return
        }
        await refreshIssueCapture()
    }

    /// The issue folder of this app, for "Show in Finder".
    func issueCaptureFolder() async -> String {
        await currentIssueTracker().folderPath
    }

    /// One line in `events.jsonl` for something that files no issue.
    func recordDebugEvent(kind: String, serviceID: String?, message: String) async {
        guard let tracker = debugTracker else { return }
        await tracker.recordEvent(kind: kind, serviceId: serviceID, message: message, redactor: makeRedactor())
    }

    func captureDebugIssue(
        trigger: String,
        serviceID: String?,
        summary: String,
        errorMessage: String? = nil,
        recoveryGuidance: String? = nil,
        signature: String? = nil,
        log: [LogEntry]? = nil
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
                uptimeSeconds: state.lastStarted.map { Int(clock.date().timeIntervalSince($0)) }
            )
        }

        let redactor = makeRedactor()
        var logEntries: [DebugTracker.LogEntry] = []
        var likelyCause: String?
        if let sid = serviceID {
            let raw: [LogEntry] = if let log { log } else { await logStore.entries(for: sid) }
            logEntries = raw.map { DebugTracker.LogEntry(timestamp: $0.timestamp, serviceId: sid, line: $0.text) }
            likelyCause = CrashCause.likelyCause(in: raw.map(\.text), serviceID: sid, redactor: redactor)
        }

        let _ = await tracker.captureIssue(
            trigger: trigger,
            serviceId: serviceID,
            errorMessage: errorMessage ?? summary,
            signatureText: signature,
            likelyCause: likelyCause,
            logEntries: logEntries,
            stateSnapshots: snapshots,
            redactor: redactor
        )

        debugOpenIssueCount = await tracker.openIssueCount()
    }

    /// The redactor for text that leaves the app. It knows the secret values in the
    /// env files of the services, as they are now.
    func makeRedactor() -> Redactor {
        let definitions = graph.map { Array($0.nodes.values) } ?? []
        return Redactor(
            envDirectories: definitions.compactMap(\.resolvedCwd),
            environments: definitions.compactMap(\.env)
        )
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

    private func runShellCommand(_ command: String, timeout: Duration = Shell.defaultTimeout) async -> Bool {
        await shell.run(command, timeout: timeout).succeeded
    }

    /// The line in the Stripe log for each case where Stripe ends as skipped.
    nonisolated static func stripeStoppedLine(_ cause: String) -> String {
        "[travel-runner] Stripe stopped: \(cause)"
    }

    private func isStripeAvailable() async -> Bool {
        if let stripeAvailability { return await stripeAvailability() }
        // `stripe config --list` only proves that a credential is stored; it
        // still exits zero for expired API keys. Exercise the authenticated API
        // so invalid sessions are skipped before `stripe listen` can crash.
        return await runShellCommand(
            "which stripe >/dev/null 2>&1 && stripe balance retrieve >/dev/null 2>&1", timeout: .seconds(15)
        )
    }

    private func canReachHost(_ host: String) async -> Bool {
        await runShellCommand("nc -z -w 2 \(host) 443 >/dev/null 2>&1", timeout: .seconds(10))
    }

    private func waitForNetwork(timeout: Duration = .seconds(30)) async -> Bool {
        let deadline = clock.uptime() + timeout
        while clock.uptime() < deadline {
            if await canReachHost("api.stripe.com") { return true }
            try? await clock.sleep(for: .seconds(2))
        }
        return false
    }

    /// Whether the local database has the travel tables. A fresh Docker volume has
    /// none. A query that fails gives `unknown`, never `empty`.
    private func probeDatabase(cwd: String) async -> DbProbe {
        DbProbe.classify(await queryDatabase(cwd: cwd, sql: "SELECT count(*) FROM pg_tables WHERE schemaname = 'fb_travel'"))
    }

    /// An automatic reset needs a start that is still wanted and a Supabase that runs.
    private var canAutoReset: Bool {
        !Task.isCancelled && !isShuttingDown && serviceStates["supabase"]?.phase == .running
    }

    /// What `applyDbResetPolicy` did.
    enum AutoSetupOutcome: Equatable, Sendable {
        /// No setup ran: nothing to do, the person is asked, or nothing may change.
        case notRun
        case passed
        case failed
    }

    /// After Supabase starts: applies `DbResetPolicy`. It changes nothing when
    /// Supabase does not run, after a stop, or when the database cannot be read.
    /// True when a setup ran; false when none ran or another setup already runs.
    @discardableResult
    func resetDatabaseIfNeeded(cwd: String, checkMigrations: Bool) async -> Bool {
        await applyDbResetPolicy(cwd: cwd, checkMigrations: checkMigrations, atStart: false) != .notRun
    }

    /// An empty database is set up. With `checkMigrations`, changed migrations reset
    /// the database only when the opt-in setting is on; otherwise the banner asks.
    func applyDbResetPolicy(cwd: String, checkMigrations: Bool, atStart: Bool) async -> AutoSetupOutcome {
        guard canAutoReset else { return .notRun }
        // A runner that is too old for this checkout does not even ask the database.
        guard !refreshCompatibility(cwd: cwd) else { return .notRun }
        var probe = await probeDatabase(cwd: cwd)
        // Supabase counts as running when its port opens, and Postgres takes queries
        // a little later (much later on a new volume). Ask again before giving up.
        let deadline = clock.uptime() + databaseProbeRetry.timeout
        var saidWaiting = false
        while case .unknown(let detail) = probe, canAutoReset, clock.uptime() < deadline {
            if !saidWaiting {
                saidWaiting = true
                await logStore.append(serviceID: "supabase", entry: LogEntry(
                    stream: .stderr,
                    text: "[travel-runner] The local database does not answer yet (\(detail)). Asking again…"
                ))
            }
            try? await clock.sleep(for: databaseProbeRetry.interval)
            guard canAutoReset else { return .notRun }
            probe = await probeDatabase(cwd: cwd)
        }
        // The probe takes time: a stop can arrive while it runs.
        guard canAutoReset else { return .notRun }

        // Migrations matter only to the opt-in setting; the banner reads them itself.
        var migrations: DbResetPolicy.MigrationStatus?
        var builtFrom: DbResetPolicy.BuiltFrom?
        if probe == .hasTables, checkMigrations, autoResetOnMigrations {
            migrations = await migrationStatus(cwd: cwd)
            if migrations?.isCurrent == false { builtFrom = await readBuiltFrom(cwd: cwd) }
            guard canAutoReset else { return .notRun }
        }
        let decision = DbResetPolicy.decide(
            probe: probe,
            migrations: migrations,
            builtFrom: builtFrom,
            current: DbResetPolicy.Checkout(path: cwd, branch: gitBranches["supabase"]),
            autoResetOnMigrations: autoResetOnMigrations
        )

        let reason: String
        let origin: DbSetupOrigin
        switch decision {
        case .blocked(let message):
            lastError = message
            return .notRun
        case .none, .offerMigrate, .offerReset:
            return .notRun
        case .autoSetup:
            reason = "Empty database detected — running db:reset..."
            origin = atStart ? .emptyDatabaseAtStart : .emptyDatabase
        case .autoReset:
            let count = migrations.map { $0.missing.count + $0.extra.count } ?? 0
            reason = "\(count) migration change\(count == 1 ? "" : "s") — resetting, because Settings resets the database when migrations change..."
            origin = .autoResetSetting
        }
        // Another reset or setup runs: this one does not start.
        guard !dbResetRunning, dbSetupPipeline?.isRunning != true else { return .notRun }
        let ok = await performDbSetup(cwd: cwd, profile: "reset", reason: reason, origin: origin)
        return ok ? .passed : .failed
    }

    /// How the database differs from the migration files; nil when that cannot be
    /// read (database down, no backend baseline checkout).
    private func migrationStatus(cwd: String) async -> DbResetPolicy.MigrationStatus? {
        guard let expected = MigrationTracker.expectedVersions(root: cwd) else { return nil }
        let result = await queryDatabase(cwd: cwd, sql: "SELECT version FROM supabase_migrations.schema_migrations")
        guard result.exitCode == 0 else { return nil }
        return DbResetPolicy.MigrationStatus.compare(
            expected: expected, applied: MigrationTracker.parseVersions(result.stdout)
        )
    }

    /// One query against the local database (`psql -tA`), with its exit status and
    /// its error text.
    private func queryDatabase(cwd: String, sql: String) async -> DbQueryResult {
        if let databaseQuery { return await databaseQuery(cwd, sql) }
        let container = SupabaseProject.dbContainerName(root: cwd)
        let command = ShellQuote.join(["docker", "exec", container, "psql", "-U", "postgres", "-d", "postgres", "-tAc", sql])
        let result = await shell.run(command, cwd: cwd, timeout: Self.databaseQueryTimeout)
        if result.timedOut {
            return DbQueryResult(
                exitCode: -1, stdout: "",
                stderr: "The database did not answer in \(Self.databaseQueryTimeout.components.seconds) s."
            )
        }
        return DbQueryResult(
            exitCode: result.exitCode,
            stdout: result.trimmedOutput,
            stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// A query that hangs counts as a failed query, never as an empty database.
    nonisolated static let databaseQueryTimeout: Duration = .seconds(20)

    nonisolated static let dbResetCancelledMessage =
        "The database reset stopped before it finished. Open DB Tools and click Reset Database to run it again."

    /// A pipeline for the manifest profile with the selected seed scenario, or nil (and
    /// `lastError` set) when no valid scenario is selected.
    private func makeDbSetupPipeline(cwd: String, profile: String) -> DbSetupPipeline? {
        if let dbPipelineFactory {
            guard let pipeline = dbPipelineFactory(cwd, profile) else {
                lastError = "No DB setup pipeline for the profile \(profile)."
                return nil
            }
            return pipeline
        }
        let manifestPath = (cwd as NSString).appendingPathComponent("scripts/db/manifest.json")
        // The loader runs `reset` for a profile it does not find. Apply must never reset,
        // and a reset without hotels must not load them.
        if profile == DbResetPolicy.migrateProfile,
           DbManifestLoader.profileNames(from: manifestPath)?.contains(profile) != true {
            lastError = DbResetPolicy.noMigrateProfileText
            return nil
        }
        if profile == HotelCatalog.withoutHotelsProfile,
           DbManifestLoader.profileNames(from: manifestPath)?.contains(profile) != true {
            lastError = HotelCatalog.noWithoutHotelsProfileText
            return nil
        }
        reloadDbSeedScenarios()
        // Apply migrations seeds nothing, so it needs no scenario.
        let scenario = selectedDbSeedScenario
            ?? (profile == DbResetPolicy.migrateProfile ? DbResetPolicy.noScenario : nil)
        guard let seedScenario = scenario else {
            lastError = dbSeedScenarioLoadError
                ?? "Choose a valid seed scenario before resetting the database."
            return nil
        }
        // A bad manifest or a profile it lacks runs nothing. Only a checkout with no
        // manifest runs the built-in steps, and the pipeline says so.
        let steps: [DbSetupStep]
        do {
            steps = try DbManifestLoader.load(from: manifestPath, profile: profile)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        let pipeline = DbSetupPipeline(profile: profile, seedScenario: seedScenario)
        pipeline.steps = steps
        if !FileManager.default.fileExists(atPath: manifestPath) {
            pipeline.stepsSource = DbSetupPipeline.builtInStepsLabel
        }
        return pipeline
    }

    /// The runner of a DB setup. Its steps and its health checks get the PATH and
    /// the shell of the supervisor.
    private func makeDbSetupRunner(cwd: String, pipeline: DbSetupPipeline) -> DbSetupRunner {
        DbSetupRunner(
            portalCwd: cwd, logStore: logStore, seedScenarioID: pipeline.seedScenario.id,
            profile: pipeline.profile, tools: tools, shell: shell, launcher: dbStepLauncher
        )
    }

    /// Name of the Docker container that publishes this host port, if any.
    nonisolated static func containerPublishing(port: Int, shell: any CommandRunning = LoginShell()) async -> String? {
        let result = await shell.run(
            "docker ps --filter publish=\(port) --format '{{.Names}}' 2>/dev/null", timeout: .seconds(10)
        )
        guard result.succeeded else { return nil }
        return result.stdout.split(separator: "\n").first.map(String.init)
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

        // A number that is not a port has no listener.
        guard let portNumber = UInt16(exactly: port) else { return false }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = portNumber.bigEndian
        addr.sin_addr.s_addr = address

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Kills the process that listens on the port. `lsof -i :port` alone also matches
    /// the clients of the port (a browser tab, the Stripe CLI that forwards to the
    /// portal, another dev server), and those must stay alive.
    /// A container runtime is never killed: its port helper serves every container.
    /// True when it killed a listener.
    @discardableResult
    private func killPortOccupants(_ port: Int) async -> Bool {
        var killed = false
        for listener in await portTools.listeners(port) {
            if PortOwner.isContainerRuntime(listener.command) {
                if let serviceID = sortedServiceIDs.first(where: { serviceStates[$0]?.definition.probe?.port == port }) {
                    await logStore.append(
                        serviceID: serviceID,
                        entry: LogEntry(stream: .stderr, text: "[travel-runner] Port \(port) is published by \(listener.command) (a container). Not killed.")
                    )
                }
                continue
            }
            portTools.kill(listener.pid)
            killed = true
        }
        return killed
    }

    /// Services whose port the cleanup may clear: in the profile, and not a
    /// reuse_if_running service (e.g. Docker-managed Supabase).
    private var killableServices: [ServiceDefinition] {
        sortedServiceIDs
            .compactMap { serviceStates[$0]?.definition }
            .filter { isInProfile($0.id) && !$0.shouldReuseIfRunning }
    }

    /// The ports that Stop All and the quit of the app clear: those of `killableServices`,
    /// and those of a service outside the profile that this session started. A change
    /// of profile leaves such a service running until the next stop.
    var sweepPorts: [Int] {
        let killable = Set(killableServices.map(\.id))
        return sortedServiceIDs
            .compactMap { serviceStates[$0] }
            .filter { state in
                killable.contains(state.definition.id)
                    || (state.lastStarted != nil && !state.definition.shouldReuseIfRunning)
            }
            .compactMap { $0.definition.probe?.port }
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
            if attempt > 0 { try? await clock.sleep(for: .seconds(3)) }
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
    func killWebServicePorts() async {
        for serviceID in Self.wakeHealthPaths.keys.sorted() where isInProfile(serviceID) {
            guard let port = serviceStates[serviceID]?.definition.probe?.port else { continue }
            await lifecycle.withLock(serviceID) {
                await processRunner.stop(serviceID: serviceID)
                await killPortOccupants(port)
            }
        }
    }

    /// Kill any stale processes from a previous session before starting the DAG.
    /// Skips ports belonging to reuse_if_running services (e.g. Docker-managed Supabase)
    /// and to services outside the profile.
    func cleanupStaleProcesses() async {
        // Kill by port — only non-reuse services of the profile (skip Docker-managed ports)
        let killablePorts = killableServices.compactMap { $0.probe?.port }

        var didKill = false
        for port in killablePorts {
            if isPortBound(port) {
                await killPortOccupants(port)
                didKill = true
            }
        }

        // Kill a Stripe listener that an earlier session left. The pattern is the
        // command of the service, so any other `stripe listen` stays alive.
        if isInProfile("stripe"), let stripe = serviceStates["stripe"]?.definition {
            await portTools.killCommands(PortOwner.commandPattern(for: stripe.cmd))
        }

        if didKill {
            try? await clock.sleep(for: .milliseconds(500))
        }
    }
}
