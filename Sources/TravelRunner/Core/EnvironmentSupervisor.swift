import Foundation
import SwiftUI

@Observable
@MainActor
final class EnvironmentSupervisor {
    // MARK: - Published State

    var health: HealthStatus = .stopped
    /// Why the stack has its health: the header, the menu-bar tooltip and `health_reason`.
    private(set) var healthSummary = HealthSummary.stopped
    /// Why the last start did not start anything. Cleared by the next start, a stop,
    /// or once a service runs or fails.
    private var startRefusal: String?
    /// Services that `replaceProcess` replaces now, with a count: the health counts
    /// their pending phase as starting.
    private var restartsInFlight: [String: Int] = [:]
    var serviceStates: [String: ServiceState] = [:]
    var preflightChecks: [PreflightCheck] = []
    var currentPhase: StartupPhase = .idle
    var completedPhases: Set<String> = []
    var sortedServiceIDs: [String] = []
    /// The header's notices, one per key.
    var notices = NoticeCenter()
    /// The newest error notice. Post a notice to set it.
    var lastError: String? { notices.newestError?.text }
    /// Set when the control API could not listen on a loopback address.
    var controlAPIError: String? = nil
    /// One line for each service of services.json that the last load left out.
    var configIssues: [String] = []
    /// Set when a release copy runs outside an Applications folder, until the person closes it.
    var misplacedCopyNotice: InstanceGuard.MisplacedNotice? = nil
    /// True when macOS denies the notifications: a crash shows only in the menu bar.
    var notificationsOff = false
    /// The person closed the "Notifications are off" banner for this run.
    var notificationsOffDismissed = false
    static let notificationsOffText = "Notifications are off — crashes show only as the red menu-bar dot."
    /// Set while the checkout needs a newer runner. No reset and no DB step runs
    /// while it is set; the services still start.
    var compatibilityNotice: Compatibility.Notice? = nil
    /// Set at launch while processes of the last session still run, until they are
    /// stopped or Start stops them.
    var leftoverNotice: String? = nil
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
    /// The Supabase restart that waits for the person to confirm it, or nil.
    var supabaseRestartConfirmation: SupabaseRestartRequest? = nil
    /// Off: Supabase keeps running when the app quits. Saved in UserDefaults.
    var stopSupabaseOnQuit = false {
        didSet { userDefaults.set(stopSupabaseOnQuit, forKey: SupabaseStackHealth.stopOnQuitSettingKey) }
    }
    /// True while "Stop Supabase" runs.
    private(set) var supabaseStopping = false
    /// The cached hotel dump, as `fetch-hotels.mjs --verify` sees it.
    var hotelDump: HotelCatalog.DumpState = .unknown
    /// Set after a reset passed while portals ran, until a restart or a dismiss.
    var portalRestartNotice: String? = nil

    var selectedDbSeedScenario: DbSeedScenario? {
        guard let selectedDbSeedScenarioID else { return nil }
        return dbSeedScenarios.first { $0.id == selectedDbSeedScenarioID }
    }
    var networkMode = false
    /// The LAN address of LAN mode. Nil when LAN mode is off.
    var lanAddress: LanAddress? = nil
    var localIP: String? { lanAddress?.ip }
    var panelVisible = false
    var rootCauseServiceID: String? = nil
    var phaseTimings: [String: TimeInterval] = [:]
    /// A crash, with its cause and what happens next: the notification.
    var onServiceCrash: (@MainActor (CrashAlert) -> Void)? = nil
    var debugTrackingEnabled = false
    var debugOpenIssueCount = 0
    /// True while "Report a problem" saves its zip.
    private(set) var reportExportRunning = false
    /// Makes the exporter of a report. Tests give one with a temporary folder and a fake zip.
    @ObservationIgnored var makeReportExporter: () -> ReportExporter = { .live() }
    var actionsInFlight: Set<String> = []
    /// Shows one feedback as a toast. `showFeedback` also lists it in `recentActivity`.
    var onFeedback: ((ActionFeedback) -> Void)?
    /// The last feedback and crashes, the newest first, for Status.
    private(set) var recentActivity = RecentActivity()
    /// The short form of `showFeedback`, for an action that only succeeds or fails.
    var onActionFeedback: ((String, Bool) -> Void)? {
        { [weak self] message, success in self?.showFeedback(message, success ? .success : .error) }
    }
    /// Opens Health: every setup check, and where each tool was found (the "Open Health" button).
    var onOpenHealth: (() -> Void)?
    /// Opens Settings, where the paths of the repos are set.
    var onOpenSettings: (() -> Void)?
    /// The setup checks of Health. The preflight of a start runs the fast ones
    /// (see `CheckRegistry`), so Health, the preflight and the Status banner show
    /// the same results. Built at each config load.
    private(set) var healthChecker: EnvironmentChecker?
    /// The paths that `healthChecker` was built for.
    @ObservationIgnored private var healthCheckerPaths: RepoPaths?
    var gitBranches: [String: String] = [:]
    var gitBehindCounts: [String: Int] = [:]
    /// The profile changed while the stack ran: it applies at the next start or with "Apply now".
    var profileApplyPending = false
    /// Saves the profile. Tests replace it, so they never write the real services.json.
    @ObservationIgnored var saveProfile: (RunProfile) throws -> Void = { try ConfigLoader.saveProfile($0) }
    /// The tooltip of a repo whose last fetch failed, by service.
    var gitFetchFailures: [String: String] = [:]
    var behindBannerDismissed = false
    var npmStaleServices: Set<String> = []
    var dbMode: DatabaseMode = .local
    /// Which part of the graph start-all brings up (stored in services.json).
    var profile: RunProfile = .both
    private(set) var profileMembers: Set<String> = []
    /// True when Settings saved new paths while the stack ran. They load at the
    /// next launch, or at the next reconfigure with the stack stopped.
    private(set) var reconfigurePending = false
    /// Reconfigures that run now, "Stop and apply" included.
    private var reconfiguresRunning = 0
    /// `/api/preflight` requests that run their checks now.
    private var preflightRequestsRunning = 0
    /// True while "Run Checks Now" runs the checks.
    private(set) var preflightOnlyRunning = false
    /// The checks of "Run Checks Now". A start cancels it and waits for it.
    @ObservationIgnored private var preflightOnlyTask: Task<Void, Never>?

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

    func dismissNotice(_ key: NoticeKey) {
        notices.dismiss(key)
    }

    /// `first` false: a later failure of a start. The first failure stays the
    /// newest error, and this notice goes behind it.
    private func postNotice(_ key: NoticeKey, _ text: String, severity: Notice.Severity = .error, first: Bool = true) {
        notices.post(key, text, severity: severity, now: clock.date(), atFront: first)
    }

    /// A start or a stop makes the notices of the stack stale.
    private func resolveStackNotices() {
        notices.resolveAll { $0.endsWithStack }
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
        let dependents = graph.dependents(of: rootID)
        let waiting = dependents.filter { serviceStates[$0]?.phase == .waiting }.count
        if waiting > 0 {
            return waiting == 1 ? "1 service is waiting for it." : "\(waiting) services are waiting for it."
        }
        let affected = dependents.count
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
    /// The processes that the runner started. The app gives it the file; without
    /// one it stays in memory.
    @ObservationIgnored var ledger = LaunchLedger(path: nil)
    /// Per service, the start time of its earliest launch in this session that has
    /// ended (`checkOtherNextDev`).
    @ObservationIgnored private var endedLaunchStarts: [String: Int64] = [:]
    /// The check that the Stripe CLI is installed and can call Stripe, with the test
    /// key or the login. Tests set a fake; nil runs the CLI in `shell`.
    @ObservationIgnored var stripeTooling: (any StripeTooling)?
    /// Whether the network reaches Stripe. Tests set a fake; nil asks with `nc`.
    @ObservationIgnored var stripeNetworkUp: (@Sendable () async -> Bool)?
    /// The waits of the Stripe retries. Tests make them short.
    @ObservationIgnored var stripeRetryPolicy = StripeRetryPolicy()
    /// Runs in the wake reconnect before it stops the stale CLI. Tests let the CLI exit there.
    @ObservationIgnored var stripeBeforeWakeStop: (@MainActor () async -> Void)?
    /// Finds the LAN address of the Mac. Tests set a fake.
    @ObservationIgnored var findLanAddress: @Sendable () async -> LanAddress? = { await LanAddress.current() }
    /// The time of every wait, deadline and time stamp of the supervisor. Its
    /// deadlines are awake time: a Mac that sleeps while a service starts uses none
    /// of the service's time. Tests set a fake.
    @ObservationIgnored var clock = RunnerClock.awake
    /// The services that the other runner app runs now. The config load and Start
    /// All ask it. Tests set a fake, so no test asks the other app.
    @ObservationIgnored var siblingActiveServices: @Sendable () async -> [String] = { await SiblingRunner.activeServices() }
    /// The ports that the secret registry tries. Tests give port 0, so the
    /// system picks a free one.
    @ObservationIgnored var secretRegistryPorts: ClosedRange<UInt16> = LiveSecretRegistry.defaultPorts
    /// Where the config and the control server come from.
    @ObservationIgnored var configHost = ConfigHost()
    /// The preflight checks run their commands in the shell of the supervisor and
    /// wait on its clock. The checks of the registry come from Health, and the port
    /// checks know which processes are the runner's own.
    private var preflightRunner: PreflightRunner {
        PreflightRunner(
            shell: shell, clock: clock, environment: resolvedHealthChecker(), profile: profile,
            inspectPort: { [weak self] port in await self?.portOccupants(port) ?? [] }
        )
    }
    private var registry: LiveSecretRegistry?
    private var controlServer: ControlServer?
    private var sleepWakeObserver: SleepWakeObserver?
    private var networkObserver: NetworkObserver?
    private var startTask: Task<Void, Never>?
    /// Tells a Start All apart from one that a stop replaced.
    private var startToken = UUID()
    /// The stop that runs. Each stack operation waits for it.
    private var stopTask: Task<Void, Never>?
    /// The last stack operation of the queue: Start All, a branch-change restart, or
    /// a DB setup or an install that a person asked for. Each waits for the one before.
    private var stackTail: Task<Void, Never>?
    private var stackOperationsQueued = 0
    /// The first service that failed in this Start All. Its error is the headline.
    private var startFailure: String?
    /// The automatic restarts that are due, per service. A waiter of the old process
    /// gives no verdict then: the restart gives it.
    private var pendingRestarts: [String: Int] = [:]
    /// How long a oneshot may run before it is stopped.
    @ObservationIgnored var oneshotDeadline: Duration = .seconds(15 * 60)
    private var config: ServiceConfig?
    private var isShuttingDown = false
    private let userDefaults: UserDefaults
    private var stdoutProbes: [String: StdoutProbe] = [:]
    private var didBootstrap = false
    /// The env reset of the last config load, which first asks the other runner
    /// app. Nil before the first load.
    private(set) var envResetAfterLoad: Task<Void, Never>?
    /// Start All: the services of each startup phase that have not settled, and
    /// when the phase began. A phase is done when all its services are.
    private var startPhaseRemaining: [String: Int] = [:]
    private var startPhaseBegan: [String: Date] = [:]
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
    /// The tools of an issue's `diagnostics.json`. Tests give a fake; nil runs the
    /// tools report in the shell of the supervisor.
    @ObservationIgnored var diagnosticsTools: (@Sendable (_ cwd: String?) async -> [ToolReport])?
    @ObservationIgnored private var cachedDiagnosticsTools: (at: Date, reports: [ToolReport])?
    private var gitBranchWatcher: GitBranchWatcher?
    private var gitRepoRoots: [String: String] = [:]
    private var dependencyWatcher: DependencyWatcher?
    /// `deps.json`: the lockfile hash of each install folder at its last install.
    /// Tests give a file in their own folder.
    @ObservationIgnored var dependencyRecord = DependencyRecord.live
    /// The install that runs in each install folder. A second caller waits for it.
    /// Stop-all cancels them, which kills the install.
    private var installTasks: [String: Task<CommandResult, Never>] = [:]
    /// Counts the stop-alls. An install that sees a new count stops what it was for.
    private var stopAllCount = 0
    private var gitWatcherTask: Task<Void, Never>?
    private var depsWatcherTask: Task<Void, Never>?
    private var isTogglingNetwork = false
    private var localSupabaseKeys: LocalSupabaseKeys?
    private var stripeWebhookSecret: String?
    /// The portal's log has said that it has no webhook secret, for this start.
    private var warnedNoWebhookSecret = false
    /// How the last start of the Stripe CLI signed in. An exit reads it for its cause.
    private var stripeMode: StripeMode?
    /// The last answer of the Stripe probe, for 60 s.
    private var stripeAvailabilityCache = StripeAvailabilityCache()
    /// Counts the changes of Stripe's state. A retry that waits runs only when no
    /// newer change (a start, a stop, another retry) came first.
    private var stripeGeneration = 0
    /// The tries since the network went away, and the restarts since the CLI
    /// began to crash. A start by a person sets both to 0.
    private var stripeNetworkAttempts = 0
    private var stripeCrashRestarts = 0
    /// The reconnect after a wake runs. A wait for the network says so on the row.
    private var stripeReconnectingAfterWake = false
    /// The CLI that the wake reconnect replaces. Its own exit is part of the reconnect.
    private var stripeWakeStalePID: Int32?
    /// Why Stripe waits, as the log last said it. The retries do not say it again.
    private var stripeWaitAnnounced: String?
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
    /// The failed liveness checks of the running daemons.
    private var healthMonitor = HealthMonitor()
    /// How often the running daemons are checked. Nil: never (tests).
    @ObservationIgnored var livenessInterval: Duration? = HealthMonitor.interval
    /// The liveness probe of each service. Tests set it; nil builds it from the config.
    @ObservationIgnored var livenessProbeOverride: ((String) -> Probe?)?
    private var livenessLoopStarted = false
    /// How long a start may run while its process lives. Tests make it short.
    @ObservationIgnored var startHardCap: Duration = HealthMonitor.startHardCap
    /// The start that passed its soft limit, per service: its process and the
    /// uptime at which it is stopped. "Keep waiting" moves the deadline.
    private var slowStartDeadlines: [String: (pid: Int32, deadline: Duration)] = [:]
    /// The waits of a wake check. Tests make them short.
    struct WakeTiming {
        /// The wait before the first check.
        var settle: Duration = .seconds(3)
        /// How long one pass waits for a service, and for Supabase, whose
        /// containers wake slowly.
        var window: Duration = .seconds(15)
        var supabaseWindow: Duration = .seconds(60)
        var interval: Duration = .seconds(3)
        /// The wait between the first and the second pass.
        var passGap: Duration = .seconds(5)
    }
    @ObservationIgnored var wakeTiming = WakeTiming()
    /// The last line of the last wake check: what it checked and what it restarted.
    private(set) var lastWakeSummary: String?
    private var networkReapplyPending = false
    private var wakePassStartedAt: Date?
    private var wakePending = false
    /// Tests replace the database query and the reset with fakes.
    var databaseQuery: ((_ cwd: String, _ sql: String) async -> DbQueryResult)?
    /// How long the automatic reset waits for a database that does not answer yet.
    /// The port of Supabase opens before Postgres takes queries.
    var databaseProbeRetry: (interval: Duration, timeout: Duration) = (.seconds(2), .seconds(60))
    var dbResetAction: ((_ cwd: String) async -> Bool)?
    /// Tests give the health of the Supabase stack; nil checks its containers.
    @ObservationIgnored var supabaseHealthCheck: ((_ root: String, _ dbPort: Int) async -> SupabaseStackHealth)?
    /// A start repairs a Supabase stack that is only partly up once. Start All and
    /// a restart that a person asks for allow one more.
    private var supabaseRepairUsed = false
    /// Tests give the pipeline of a DB setup, so no manifest and no seed scenario
    /// is read. Nil from the closure starts nothing and posts a db-setup notice, like a
    /// missing scenario.
    var dbPipelineFactory: ((_ cwd: String, _ profile: String) -> DbSetupPipeline?)?
    /// How a DB step command starts. Tests give a shell that reads no startup files.
    var dbStepLauncher: StepLauncher = .loginShell
    /// How long the stop of a DB step waits after SIGTERM before SIGKILL. Tests make it long.
    var dbStepKillGrace: Duration = ProcessTree.defaultGrace
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
        self.stopSupabaseOnQuit = userDefaults.bool(forKey: SupabaseStackHealth.stopOnQuitSettingKey)
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

        /// The plain name on the timeline pills and the Status sections.
        var label: String {
            switch self {
            case .idle: "Idle"
            case .preflight: "Checks"
            case .ground: "Database"
            case .gateway: "Gateway"
            case .portal: "Portals"
            case .stream: "Streams"
            case .verification: "Verify"
            case .running: "Running"
            }
        }
    }

    /// The texts use display names.
    enum ServiceError: Error, CustomStringConvertible {
        case oneshotFailed(name: String)
        /// `lastProbe` is the last check; `processAlive` says whether the process still ran.
        case probeTimeout(name: String, seconds: Int, processAlive: Bool, lastProbe: ProbeOutcome?)
        case exitedDuringStartup(name: String)
        /// The supervisor stopped the automatic restarts; the text says why.
        case autoRestartStopped(String)
        /// Exit 126 or 127. `finding` says what is missing.
        case commandNotRunnable(name: String, finding: CommandDiagnosis.Finding)
        case localKeysMissing(name: String, envFile: String)
        case portHeldByOtherStack(port: Int, container: String)
        /// The Supabase stack stayed partly up after its one repair of this start.
        case supabasePartlyUp(missing: [String])
        /// `owner` is the process name of the container runtime that listens on the port.
        case portHeldByContainer(name: String, port: Int, owner: String)
        /// `reason` is `ProbeConfig.problem`.
        case badProbe(name: String, reason: String)
        /// services.json does not set the folder of the service's repo.
        case folderUnset(name: String)
        /// The packages were missing and their install failed. `why` comes from `installFailure`.
        case installFailed(name: String, command: String, why: String)
        /// A oneshot ran past its deadline and was stopped. `limit` reads "15 min".
        case oneshotTimedOut(name: String, limit: String)
        /// A daemon did not answer by the hard cap of its start and was stopped.
        case startTimedOut(name: String, limit: Duration)
        /// A process that the runner did not start listens on the port of the service.
        case portHeldByProcess(name: String, port: Int, occupant: PortOwner.Occupant)
        /// A `next dev` that the runner did not start runs in the folder of the service.
        case otherNextDev(pid: pid_t, port: Int?, folder: String, startTime: Int64)

        var description: String {
            switch self {
            case .oneshotFailed(let name): "\(name) exited with non-zero status"
            case .probeTimeout(let name, let s, _, let last):
                "\(name) did not pass its health probe in \(s)s" + (last.map { " (last check: \($0.summary))" } ?? "")
            case .exitedDuringStartup(let name): "\(name) exited before it was ready — see its log"
            case .autoRestartStopped(let reason): reason
            case .commandNotRunnable(let name, let finding):
                CommandDiagnosis.message(finding, name: name)
            case .localKeysMissing(let name, let envFile):
                "\(name) was not started: the keys of the local Supabase stack could not be read (scripts/local-db.sh status -o env). Without them it would use the hosted dev values in \(envFile). Restart Supabase, then restart \(name)."
            case .portHeldByOtherStack(let port, let container):
                "Port \(port) is held by another Supabase stack (\(container)) — stop it, then start again"
            case .supabasePartlyUp(let missing):
                "Supabase is still only partly up (\(SupabaseStackHealth.missingText(missing))) after db:stop and db:start — restart Supabase, and see its log"
            case .badProbe(let name, let reason):
                "\(name) cannot start: \(reason). Correct its probe in services.json, then quit \(Flavor.current.displayName) and open it again."
            case .portHeldByContainer(let name, let port, let owner):
                "\(name) cannot start: port \(port) is published by a container (\(owner)) — stop that container, then restart \(name)"
            case .folderUnset(let name):
                "\(name) cannot start: no folder is set — open Settings → Reconfigure Repos"
            case .installFailed(let name, let command, let why):
                "\(name) cannot start: its packages are not installed and \(command) \(why)"
            case .oneshotTimedOut(let name, let limit):
                "\(name) did not finish in \(limit) and was stopped. See its log."
            case .startTimedOut(let name, let limit):
                HealthMonitor.hardCapText(name: name, limit: limit)
            case .portHeldByProcess(let name, let port, let occupant):
                PortOwner.foreignText(port: port, occupant: occupant, service: name)
            case .otherNextDev(let pid, let port, let folder, _):
                PortOwner.otherNextDevText(pid: pid, port: port, folder: folder)
            }
        }
    }

    // MARK: - Lifecycle

    /// What the config load takes from the app and from this Mac. Tests give fakes,
    /// so no test reads services.json or binds the control port.
    struct ConfigHost {
        var load: () throws -> ServiceConfig = { try ConfigLoader.load() }
        var controlServer: () -> ControlServer = { ControlServer() }
        /// False: the load starts no git and no npm watcher on the service folders,
        /// and runs no setup check of Health. Tests set it, so no test runs the git
        /// of this Mac or asks the network.
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
            // The fast setup checks run once at launch, so the Status banner is
            // current. The network checks wait until Health opens.
            if configHost.startsWatchers, let checker = healthChecker {
                Task { await checker.runFastChecks() }
            }
        } catch ConfigLoader.ConfigError.noConfig {
            // First run — setup wizard will handle this
        } catch ConfigLoader.ConfigError.monorepoNotFound {
            // Old three-repo config with no monorepo nearby — setup wizard will handle this
        } catch {
            postNotice(.config, "Config load failed: \(error)")
            print("[Supervisor] Config load failed: \(error)")
        }
        reconcileLeftovers()
    }

    /// Loads the config that Settings saved. While the stack runs it changes
    /// nothing and answers `.needsStop`: a new service state knows no process, so
    /// a load now would lose the processes that run.
    func reconfigure() async -> ReconfigureResult {
        reconfiguresRunning += 1
        defer { reconfiguresRunning -= 1 }
        guard await !holdsLiveStack() else {
            reconfigurePending = true
            return .needsStop
        }
        do {
            try applyConfig()
            notices.resolve(.config)
            onActionFeedback?("Paths updated", true)
            return .applied
        } catch {
            let message = "Paths not applied: \(error)"
            postNotice(.config, message)
            onActionFeedback?(message, false)
            return .failed(message)
        }
    }

    /// "Stop and apply": stops the stack, then loads the config that Settings saved.
    @discardableResult
    func stopAndReconfigure() -> Task<ReconfigureResult, Never> {
        let stop = beginStopAll()
        reconfiguresRunning += 1
        return Task {
            defer { reconfiguresRunning -= 1 }
            await stop.value
            let result = await reconfigure()
            if result == .needsStop {
                onActionFeedback?("Paths not applied: the stack did not stop. Stop it, then save the paths again.", false)
            }
            return result
        }
    }

    /// What a restart for an update would interrupt now. The window is the app's to report.
    func updateRestartState(panelOpen: Bool) async -> UpdatePolicy.RestartState {
        // The process runner answers first: the other checks then see the state of this moment.
        let processRuns = await processRunner.hasRunningProcess()
        var state = updateRestartStateNow(panelOpen: panelOpen)
        state.stackRunning = state.stackRunning || processRuns
        return state
    }

    /// `updateRestartState` without the process runner, read at once. The update
    /// controller reads it again right before the install: a click may have come
    /// while the process runner answered.
    func updateRestartStateNow(panelOpen: Bool) -> UpdatePolicy.RestartState {
        UpdatePolicy.RestartState(
            // The quit stops the holds viewer too.
            stackRunning: holdsLiveStackNow() || holdsViewer.pid != nil,
            panelOpen: panelOpen,
            databaseBusy: dbResetRunning || dbSetupPipeline?.isRunning == true,
            fixRunning: EnvironmentChecker.fixesRunning > 0,
            reconfigureRunning: reconfiguresRunning > 0,
            otherWorkRunning: reportExportRunning || preflightRequestsRunning > 0
        )
    }

    /// True while the runner starts, stops or holds a process of the stack, or
    /// runs a database step.
    private func holdsLiveStack() async -> Bool {
        // A failed service can still have a process, and `pid` of a state stays
        // after its process ends. The process runner knows what runs. It answers
        // first: the other checks then see the state of this moment.
        if await processRunner.hasRunningProcess() { return true }
        return holdsLiveStackNow()
    }

    /// `holdsLiveStack` without the process runner.
    private func holdsLiveStackNow() -> Bool {
        if startTask != nil || isShuttingDown || !actionsInFlight.isEmpty || stackOperationsQueued > 0 { return true }
        if dbResetRunning || dbSetupPipeline?.isRunning == true { return true }
        let livePhases: Set<ServicePhase> = [.starting, .waiting, .running, .stopping]
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
        startLivenessLoop()

        networkObserver = NetworkObserver { [weak self] in
            Task { await self?.handleNetworkChange() }
        }
        networkObserver?.startObserving()

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
        resolvedHealthChecker()

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
        gitFetchFailures = [:]
        depsWatcherTask?.cancel()
        depsWatcherTask = nil
        dependencyWatcher = nil
        npmStaleServices = []

        // Initialize git branch watcher for all repos with cwds
        var repoMap: [String: String] = [:]
        for service in config.services {
            if let cwd = service.resolvedCwd, !cwd.isEmpty {
                repoMap[service.id] = cwd
            }
        }
        if configHost.startsWatchers, !repoMap.isEmpty {
            // git runs off the main thread, each command with a time limit.
            let (shell, clock) = (shell, clock)
            gitWatcherTask = Task { [weak self] in
                let roots = await GitBranchWatcher.resolveRoots(repos: repoMap, shell: shell)
                guard let self, !Task.isCancelled else { return }
                let watcher = GitBranchWatcher(roots: roots, shell: shell, clock: clock)
                self.gitBranchWatcher = watcher
                self.gitRepoRoots = roots
                await self.startGitBranchWatching(watcher: watcher)
            }
        }

        // Initialize dependency (npm install) freshness watcher
        var depsMap: [String: String] = [:]
        for service in config.services {
            if let cwd = service.resolvedCwd, !cwd.isEmpty, service.resolvedType == .daemon {
                depsMap[service.id] = cwd
            }
        }
        if configHost.startsWatchers, !depsMap.isEmpty {
            let depsWatcher = DependencyWatcher(repoPaths: depsMap, record: dependencyRecord)
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
        resolvedHealthChecker()
    }

    // MARK: - Start / Stop

    /// What Start All starts.
    enum StartMode: Sendable {
        case everything
        /// "Retry failed": a service that runs, or a oneshot that is done, stays as it is.
        case missingOnly
    }

    nonisolated static let startWaitsText = "Start waits for the running step to finish"

    /// Starts the stack. It is a stack operation: it waits for a stop that runs and
    /// for the operation before it, so a Start pressed during a Stop is not lost.
    func startAll(skipPreflight: Bool = false, mode: StartMode = .everything) {
        guard startTask == nil else {
            showFeedback(ActionFeedback.startInProgress, .info)
            return
        }
        guard graph != nil else { return }
        // The start runs the checks of "Run Checks Now" itself (`runStartAll` waits for them).
        preflightOnlyTask?.cancel()
        let waits = !stackIsIdle
        if !waits {
            prepareStartAll()
        } else if stopTask == nil {
            onActionFeedback?(Self.startWaitsText, true)
        }
        let token = UUID()
        startToken = token
        startTask = enqueueStackOperation(finally: { [weak self] in
            guard let self, self.startToken == token else { return }
            self.startTask = nil
            // The start is over: a health of "starting" ends here.
            self.recalculateHealth()
        }) { [weak self] in
            guard let self else { return }
            if waits { self.prepareStartAll() }
            await self.runStartAll(skipPreflight: skipPreflight, mode: mode)
        }
    }

    /// The state of a new Start All.
    private func prepareStartAll() {
        // The start uses the profile that is saved now.
        profileApplyPending = false
        // A start that a person asks for begins a new failure series for each service.
        for serviceID in serviceStates.keys { clearFailureHistory(serviceID) }
        // This start takes over the services that wait for a dependency.
        for state in serviceStates.values where state.phase == .waiting { state.phase = .pending }
        // Stripe keeps its own retry counts. The preflight fills the probe cache after this.
        resetStripeRetries(keepingAvailability: true)
        startRefusal = nil
        applyHealth(HealthSummary(status: .starting))
        resolveStackNotices()
        startFailure = nil
        supabaseRepairUsed = false
        dbSetupFailedAtStart = false
        startupBeganAt = clock.date()
        phaseTimings = [:]
    }

    /// True when no stop and no stack operation runs or waits.
    var stackIsIdle: Bool { stackOperationsQueued == 0 && stopTask == nil }

    /// Runs `body` after the stop that runs and after the stack operation before it.
    /// A stop that comes after the call ends what was asked: `body` does not run then,
    /// and the toast says `dropped`. `finally` runs in either case.
    @discardableResult
    private func enqueueStackOperation(
        dropped: String? = nil,
        finally: (@MainActor () -> Void)? = nil, _ body: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = stackTail
        let stops = stopAllCount
        stackOperationsQueued += 1
        let task = Task { @MainActor in
            defer {
                self.stackOperationsQueued -= 1
                finally?()
            }
            await previous?.value
            await self.stopTask?.value
            guard self.stopAllCount == stops, !Task.isCancelled else {
                if let dropped, self.stopAllCount != stops { self.onActionFeedback?(dropped, false) }
                return
            }
            await body()
        }
        stackTail = task
        return task
    }

    /// True when the service runs, or its oneshot is done: "Retry failed" leaves it.
    private func isUp(_ serviceID: String) async -> Bool {
        guard let state = serviceStates[serviceID] else { return false }
        switch state.phase {
        case .completed: return true
        case .running:
            if state.definition.resolvedType == .oneshot || state.definition.shouldReuseIfRunning { return true }
            return await processRunner.isRunning(serviceID: serviceID)
        default: return false
        }
    }

    /// False while Start All runs and another service failed first: its error is
    /// the headline, and a later failure does not replace it.
    private func ownsBanner(_ serviceID: String) -> Bool {
        guard startupBeganAt != nil, let first = startFailure else { return true }
        return first == serviceID
    }

    /// The headline of the first failure of a Start All.
    nonisolated static func startFailureHeadline(_ name: String, _ error: Error) -> String {
        "\(name) failed: \(error)"
    }

    private func runStartAll(skipPreflight: Bool, mode: StartMode) async {
        // Each end of the start, also a refusal, ends its time: health reads "stopped" again.
        defer { startupBeganAt = nil }
        guard let graph else { return }
        do {
            await preflightOnlyTask?.value
            await self.waitForEnvResetOfLoad()

            // The other runner app uses the same ports, and this start stops what it
            // finds on them.
            let siblingServices = await self.siblingActiveServices()
            if !siblingServices.isEmpty {
                await MainActor.run {
                    self.startRefusal = "Not started — \(Flavor.current.sibling.displayName) runs a stack now"
                    self.recalculateHealth(startInFlight: false)
                    self.postNotice(.siblingRunner, SiblingRunner.refusal(activeServices: siblingServices))
                    self.currentPhase = .idle
                }
                return
            }

            // The processes of the last session hold the ports and the folders. They
            // are the runner's own: stop them before the checks look at the ports.
            await self.stopLeftovers()

            // "Retry failed" leaves the services that run. The checks and the
            // cleanup skip them: their ports are in use by their own process.
            var kept: Set<String> = []
            if mode == .missingOnly {
                for serviceID in self.sortedServiceIDs where await self.isUp(serviceID) { kept.insert(serviceID) }
            }

            // Stale processes of the runner on the ports of the stack. "Retry failed"
            // spares the services that run: their ports are in use by their own process.
            await self.cleanupStaleProcesses(sparing: kept)

            // Preflight
            if !skipPreflight {
                self.currentPhase = .preflight
                let profileServices = self.loadedServices.filter { self.isInProfile($0.id) && !kept.contains($0.id) }
                let runner = self.preflightRunner
                let checks = runner.allChecks(for: profileServices)
                await MainActor.run { self.preflightChecks = checks }

                // The checks run in parallel; each command of a check has a short limit.
                await runner.runAll(checks)
                var failedDetails: [String] = []
                for check in checks {
                    if case .failed(let message, _) = check.result {
                        failedDetails.append("\(check.name): \(message)")
                    }
                }
                let allPassed = failedDetails.isEmpty

                _ = await MainActor.run { self.completedPhases.insert("PREFLIGHT") }

                if !allPassed {
                    let summary = failedDetails.joined(separator: " · ")
                    await MainActor.run {
                        let count = failedDetails.count
                        self.startRefusal = "Not started — \(count) check\(count == 1 ? "" : "s") failed"
                        self.recalculateHealth(startInFlight: false)
                        self.postNotice(.preflight, "Preflight failed — \(summary)")
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

            // Start registry. One registry runs: a retry replaces the one before.
            await self.registry?.stop()
            self.registry = LiveSecretRegistry(secretStore: self.secretStore, portRange: self.secretRegistryPorts)
            do {
                try await self.registry?.start()
            } catch {
                await MainActor.run {
                    self.postNotice(.secretRegistry, "Secret registry failed to start: \(error)")
                }
            }

            // Execute DAG with migration check after GROUND phase
            let levels = graph.startOrder()
            var didMigrationCheck = false

            // A phase is done, and timed, when all its services are, also the
            // ones that start after the next level began.
            self.startPhaseRemaining = [:]
            self.startPhaseBegan = [:]
            for level in levels {
                self.startPhaseRemaining[self.resolvePhase(for: level).rawValue, default: 0] += level.count
            }

            // The next level waits only for the services that a later service
            // needs. A service that nothing needs (Stripe) starts with its level,
            // and Start All waits for it at the end. The GROUND level waits for
            // all its services: the database check after it can reset the database.
            await withTaskGroup(of: Void.self) { trailing in
                for level in levels {
                    if Task.isCancelled { break }

                    let phase = self.resolvePhase(for: level)
                    await MainActor.run {
                        self.currentPhase = phase
                        if self.startPhaseBegan[phase.rawValue] == nil {
                            self.startPhaseBegan[phase.rawValue] = self.clock.date()
                        }
                    }

                    let needed = phase == .ground ? level : level.filter { !graph.dependents(of: $0).isEmpty }
                    for serviceID in level where !needed.contains(serviceID) {
                        trailing.addTask { await self.startForStartAll(serviceID, phase: phase, mode: mode) }
                    }
                    await withTaskGroup(of: Void.self) { group in
                        for serviceID in needed {
                            group.addTask { await self.startForStartAll(serviceID, phase: phase, mode: mode) }
                        }
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
            }

            await MainActor.run {
                self.recalculateHealth(startInFlight: false)
                if self.dbSetupFailedAtStart {
                    self.currentPhase = .idle
                } else if self.health == .healthy {
                    self.currentPhase = .running
                }
                self.startupBeganAt = nil
            }
        }
    }

    /// One service of Start All. A failure marks the service, and the services that
    /// need it wait for it. The first failure is the headline; a later one keeps it.
    private func startForStartAll(_ serviceID: String, phase: StartupPhase, mode: StartMode) async {
        do {
            if case .launched = try await startService(serviceID, mode: mode) {
                await awaitReplacingLaunch(serviceID)
            }
        } catch {
            let first = startFailure == nil
            if first { startFailure = serviceID }
            recordFailure(
                serviceID, error: error,
                lastError: first ? Self.startFailureHeadline(displayName(serviceID), error) : nil
            )
            recalculateHealth()
        }
        finishStartAllService(inPhase: phase.rawValue)
    }

    /// A restart can replace the launch of Start All while it starts (a new
    /// webhook secret restarts the portal, or a crash restarts the service). The
    /// services that need this one wait until the new process is up or has failed.
    private func awaitReplacingLaunch(_ serviceID: String) async {
        while let state = serviceStates[serviceID], !isShuttingDown, !Task.isCancelled,
              state.phase == .stopping || state.phase == .pending || state.phase == .starting
                || pendingRestarts[serviceID] != nil {
            try? await clock.sleep(for: .milliseconds(250))
        }
    }

    private func finishStartAllService(inPhase phase: String) {
        guard !isShuttingDown, let remaining = startPhaseRemaining[phase] else { return }
        guard remaining <= 1 else {
            startPhaseRemaining[phase] = remaining - 1
            return
        }
        startPhaseRemaining[phase] = nil
        if let began = startPhaseBegan[phase] {
            phaseTimings[phase] = clock.date().timeIntervalSince(began)
        }
        completedPhases.insert(phase)
    }

    /// Stops the stack. The task ends when the stack is stopped.
    @discardableResult
    func stopAll() -> Task<Void, Never> {
        beginStopAll()
    }

    /// Starts the stop of the stack. The task ends when the stack is stopped.
    @discardableResult
    private func beginStopAll() -> Task<Void, Never> {
        isShuttingDown = true
        profileApplyPending = false
        stopAllCount += 1
        let stops = stopAllCount
        startTask?.cancel()
        startTask = nil
        for install in installTasks.values { install.cancel() }
        let previousStop = stopTask
        let task = Task {
            // Two stops do not run at once: the second ends after the first.
            await previousStop?.value
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
                serviceStates[serviceID]?.clearCondition()
            }

            await registry?.stop()
            dbSetupFailedAtStart = false
            startRefusal = nil
            applyHealth(.stopped)
            currentPhase = .idle
            completedPhases = []
            phaseTimings = [:]
            resolveStackNotices()
            startupBeganAt = nil
            // A newer stop still runs: it owns the end.
            if stopAllCount == stops { isShuttingDown = false }
            networkMode = false
            lanAddress = nil
            resetEnvToLocalhost()
            if stopAllCount == stops { stopTask = nil }
        }
        stopTask = task
        return task
    }

    /// The answer of `/api/status`.
    func statusJSON(buildInfo: BuildInfo = .current) -> String {
        let states = serviceStates.mapValues(Self.statusFields)
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
        // Why the stack has its health: a failed service, the services that are off, a refused start.
        if let reason = healthSummary.reason { dict["health_reason"] = reason }
        // Present only while this runner is too old to reset the checkout.
        if let compatibilityNotice { dict["reset_blocked"] = compatibilityNotice.text }
        // version, build, commit, build_kind
        dict.merge(buildInfo.statusFields) { current, _ in current }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) { return str }
        return "{}"
    }

    /// One service of `/api/status`. `reason` is the condition of a failed service,
    /// `skip_reason` that of a skipped one; each field is there only with a value.
    static func statusFields(_ state: ServiceState) -> [String: String] {
        var fields = ["phase": state.phase.rawValue, "pid": state.pid.map(String.init) ?? "nil"]
        if let condition = state.condition {
            fields[state.phase == .skipped ? "skip_reason" : "reason"] = condition.text
        }
        if let likelyCause = state.likelyCause { fields["likely_cause"] = likelyCause }
        if let lastProbe = state.lastProbe { fields["last_probe"] = lastProbe.summary }
        return fields
    }

    /// "Run Checks Now": the checks of a start for the profile, run without a
    /// start. The results replace `preflightChecks`, so Diagnostics and Status
    /// show each reason and fix. The checks change nothing: a container runtime
    /// that does not answer fails its check and is not opened. The ports of
    /// services that run are left out (`preflightPortsLeftOut`). A start that
    /// runs has its own checks: this is refused then, and says why.
    func runPreflightOnly() async {
        guard startTask == nil else {
            showFeedback(ActionFeedback.checksDuringStart, .info)
            return
        }
        if let running = preflightOnlyTask {
            await running.value
            return
        }
        var runner = preflightRunner
        runner.opensContainerRuntime = false
        let leftOut = Set(preflightPortsLeftOut.map { "port-\($0)" })
        let checks = runner.allChecks(for: loadedServices.filter { isInProfile($0.id) })
            .filter { !leftOut.contains($0.id) }
        preflightChecks = checks
        preflightOnlyRunning = true
        preflightRequestsRunning += 1
        // A start cancels the run: it runs the same checks itself.
        let task = Task { await runner.runAll(checks) }
        preflightOnlyTask = task
        await task.value
        preflightOnlyTask = nil
        preflightOnlyRunning = false
        preflightRequestsRunning -= 1
    }

    /// The ports that "Run Checks Now" leaves out: the probe port of each service
    /// that starts, runs or stops. Its own process holds it. The ports of failed,
    /// stopped and skipped services are checked.
    var preflightPortsLeftOut: [Int] {
        let livePhases: Set<ServicePhase> = [.starting, .running, .stopping]
        let ports = serviceStates.values
            .filter { livePhases.contains($0.phase) }
            .compactMap { $0.definition.probe?.port }
        return Set(ports).sorted()
    }

    /// True while a start runs. "Run Checks Now" is refused then.
    var startRunning: Bool { startTask != nil }

    /// The answer of `/api/preflight`: the checks of a start that change nothing
    /// (Node, the ports, the folders), run now. Each check has a time limit, so
    /// the answer always comes. Without a config only the Node check runs.
    func preflightJSON() async -> String {
        preflightRequestsRunning += 1
        defer { preflightRequestsRunning -= 1 }
        let runner = preflightRunner
        let checks = runner.readOnlyChecks(for: loadedServices)
        await runner.runAll(checks)
        var rows: [[String: String]] = []
        for check in checks {
            var row = ["id": check.id, "name": check.name]
            switch check.result {
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

    /// The checker of Health for the paths of the config. A new config builds a
    /// new one. Without a config only the checks of the tools apply. Its commands
    /// run in the shell that the supervisor has at that moment.
    @discardableResult
    func resolvedHealthChecker() -> EnvironmentChecker {
        let paths = config?.paths
        if let healthChecker, healthCheckerPaths == paths { return healthChecker }
        let current: @Sendable () async -> any CommandRunning = { [weak self] in
            await self?.shell ?? LoginShell()
        }
        let checker = EnvironmentChecker(
            monorepoPath: paths?.monorepo.map(ServiceCatalog.expand) ?? "",
            loginPath: paths?.universalLogin.map(ServiceCatalog.expand) ?? "",
            streamServicesPath: paths?.streamServices.map(ServiceCatalog.expand) ?? "",
            shell: CurrentShell(current: current), tools: tools, clock: clock
        )
        checker.buildChecks()
        healthChecker = checker
        healthCheckerPaths = paths
        return checker
    }

    /// The setup checks of the profile that fail, or that the setup needs and warn.
    var setupItemsNeedingAttention: [HealthCheck] {
        guard let healthChecker else { return [] }
        return CheckRegistry.needsAttention(healthChecker.checks, profile: profile)
    }

    private func startControlServer() {
        let logStore = self.logStore
        controlServer = configHost.controlServer()
        Task {
            let failures = await controlServer?.start(actions: controlActions(), logStore: logStore) ?? []
            controlAPIError = ControlServer.BindFailure.summary(failures)
        }
    }

    // MARK: - Control API

    /// The actions of the control API. Each one checks what it can do now and
    /// answers with what it did (`ControlResult`): a route never says ok when
    /// nothing ran.
    func controlActions() -> ControlServer.Actions {
        ControlServer.Actions(
            getStatus: { [weak self] in await self?.statusJSON() ?? "{}" },
            getPreflight: { [weak self] in await self?.preflightJSON() ?? "{}" },
            getHealth: { [weak self] in await self?.healthJSON() ?? "{}" },
            getServices: { [weak self] in await self?.servicesJSON() ?? "[]" },
            getDiagnostics: { [weak self] in await self?.diagnosticsJSON() ?? "{}" },
            getEvents: { [weak self] in await self?.eventsJSON() ?? "[]" },
            listLogs: { [weak self] in await self?.logIDsJSON() ?? "{}" },
            getLogs: { [weak self] id, lines in await self?.apiLogs(id, lines: lines) ?? .notFound("no runner") },
            restartService: { [weak self] id, stack in await self?.apiRestart(id, stopsStack: stack) ?? .accepted },
            clearCacheRestart: { [weak self] id in await self?.apiClearCacheRestart(id) ?? .accepted },
            startAll: { [weak self] in await self?.apiStartAll() ?? .accepted },
            stopAll: { [weak self] in
                await self?.stopAll()
                return .accepted
            },
            toggleLan: { [weak self] in await self?.apiToggleLan() ?? .accepted },
            restartCascade: { [weak self] id in await self?.apiRestartCascade(id) ?? .accepted },
            dbResetBlock: { [weak self] in await self?.resetBlockJSON() },
            dbReset: { [weak self] in await self?.apiRunDbSetup(profile: "reset") ?? .accepted },
            dbSetupRun: { [weak self] profile in await self?.apiRunDbSetup(profile: profile) ?? .accepted },
            dbSetupRetry: { [weak self] stepId in await self?.apiRetryDbSetup(from: stepId) ?? .accepted },
            dbSetupCancel: { [weak self] in await self?.apiCancelDbSetup() ?? .accepted },
            dbSetupStatus: { [weak self] in await self?.dbSetupStatusJSON() ?? "{}" },
            dbSetupRunStep: { [weak self] stepId in await self?.apiRunDbSetupStep(stepId) ?? .accepted },
            debugListIssues: { [weak self] in
                guard let self, let tracker = await self.debugTracker else { return "[]" }
                let issues: [[String: String]] = await tracker.listOpenIssues()
                if let data = try? JSONSerialization.data(withJSONObject: issues, options: [.sortedKeys]),
                   let str = String(data: data, encoding: .utf8) { return str }
                return "[]"
            },
            debugCapture: { [weak self] description in await self?.apiCaptureIssue(description) ?? .accepted },
            debugCloseIssue: { [weak self] id, resolution in
                await self?.apiCloseIssue(id, resolution: resolution) ?? .notFound("issue not found")
            },
            toggleDbMode: { [weak self] in await self?.apiToggleDbMode() ?? .accepted },
            getProfile: { [weak self] in
                guard let self else { return "{}" }
                let (name, members) = await (self.profile.rawValue, self.profileMembers.sorted())
                let dict: [String: Any] = [
                    "profile": name,
                    "services": members,
                    "available": RunProfile.allCases.map(\.rawValue),
                ]
                if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
                   let str = String(data: data, encoding: .utf8) { return str }
                return "{}"
            },
            setProfile: { [weak self] name in await self?.apiSetProfile(name) ?? .done }
        )
    }

    private static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `GET /api/health`: the four health strings and the reason.
    func healthJSON() -> String {
        var dict: [String: Any] = ["health": health.rawValue]
        if let reason = healthSummary.reason { dict["health_reason"] = reason }
        return Self.jsonString(dict)
    }

    /// `GET /api/services`: each service in start order, with its name, profile and reason.
    func servicesJSON() -> String {
        let rows: [[String: Any]] = sortedServiceIDs.compactMap { id in
            guard let state = serviceStates[id] else { return nil }
            var row: [String: Any] = Self.statusFields(state)
            row["id"] = id
            row["name"] = state.definition.displayName
            row["in_profile"] = isInProfile(id)
            if let action = state.condition?.action { row["action"] = "\(action)" }
            return row
        }
        return Self.jsonString(rows)
    }

    /// `GET /api/diagnostics`: the snapshot of an issue, redacted.
    func diagnosticsJSON() async -> String {
        let snapshot = await diagnosticsSnapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return "{}" }
        return makeRedactor().redact(String(decoding: data, as: UTF8.self))
    }

    /// `GET /api/events`: the events of `events.jsonl`, oldest first. Empty while capture is off.
    func eventsJSON() async -> String {
        guard let tracker = debugTracker else { return "[]" }
        let events = await tracker.listEvents()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(events) else { return "[]" }
        return makeRedactor().redact(String(decoding: data, as: UTF8.self))
    }

    /// The log ids: each service, then each id with lines in the store (DB steps).
    private func logIDs() async -> [String] {
        let stored = await logStore.serviceIDs()
        return sortedServiceIDs + stored.filter { !sortedServiceIDs.contains($0) }.sorted()
    }

    /// `GET /api/logs`: the ids that `/api/logs/<id>` reads.
    func logIDsJSON() async -> String {
        Self.jsonString(["ids": await logIDs()])
    }

    /// `GET /api/logs/<id>`: the last lines, redacted. An id with no service and no lines is a 404.
    func apiLogs(_ id: String, lines: Int) async -> ControlResult {
        let known = await logIDs()
        guard known.contains(id) else { return .notFound("no log '\(id)'; known: \(known.joined(separator: ", "))") }
        let entries = await logStore.entries(for: id).suffix(lines)
        let redactor = makeRedactor()
        let rows = entries.map {
            ["stream": $0.stream == .stdout ? "stdout" : "stderr", "text": redactor.redact($0.text)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: []) else { return .json("[]") }
        return .json(String(decoding: data, as: UTF8.self))
    }

    /// Why an action on one service cannot run now, or nil. `queued` holds the
    /// services whose same action already waits.
    private func serviceActionRefusal(_ serviceID: String, queued: Bool) -> ControlResult? {
        guard serviceStates[serviceID] != nil else { return .unknownService(serviceID, known: sortedServiceIDs) }
        if isShuttingDown { return .stackStopping }
        if health == .stopped, startTask == nil { return .stackStopped }
        if queued { return .alreadyQueued(ActionFeedback.alreadyRestarting(displayName(serviceID))) }
        return nil
    }

    /// `POST /api/restart/<id>`. It starts what is down; `?stack=1` stops and starts
    /// the Supabase containers too, as the panel's confirmed restart does.
    func apiRestart(_ serviceID: String, stopsStack: Bool) -> ControlResult {
        if let refusal = serviceActionRefusal(serviceID, queued: queuedRestarts.contains(serviceID)) { return refusal }
        restartService(serviceID, stopsStack: stopsStack)
        return .accepted
    }

    func apiClearCacheRestart(_ serviceID: String) -> ControlResult {
        if let refusal = serviceActionRefusal(serviceID, queued: queuedCacheClears.contains(serviceID)) { return refusal }
        guard serviceCwd(serviceID) != nil else { return .refused("\(displayName(serviceID)) has no folder") }
        clearCacheAndRestart(serviceID)
        return .accepted
    }

    func apiRestartCascade(_ serviceID: String) -> ControlResult {
        if let refusal = serviceActionRefusal(serviceID, queued: actionsInFlight.contains(serviceID)) { return refusal }
        restartCascade(serviceID)
        return .accepted
    }

    /// `POST /api/start-all`. A start during a stop waits for it.
    func apiStartAll() -> ControlResult {
        guard graph != nil else { return .refused("No services are loaded — finish the setup in the app first.") }
        if startTask != nil { return .alreadyStarting }
        let afterStop = stopTask != nil
        startAll()
        return afterStop ? .queuedAfterStop : .accepted
    }

    func apiToggleLan() -> ControlResult {
        if isTogglingNetwork { return .alreadyQueued("A LAN mode change is already running.") }
        toggleNetworkMode()
        return .accepted
    }

    /// `POST /api/toggle-db-mode`: refused with the same reason as the panel.
    func apiToggleDbMode() -> ControlResult {
        let target: DatabaseMode = dbMode == .local ? .remote : .local
        if let refusal = databaseModeRefusal(for: target) { return .refused(refusal) }
        setDatabaseMode(target)
        return .accepted
    }

    /// `POST /api/profile/<name>`. Saved at once; the result is 200.
    func apiSetProfile(_ name: String) -> ControlResult {
        guard let newProfile = RunProfile(rawValue: name) else {
            return .unknownProfile(name, known: RunProfile.allCases.map(\.rawValue))
        }
        setProfile(newProfile)
        if let error = notices.text(.profile) { return .refused(error) }
        return .done
    }

    /// The profiles of the checkout's manifest, or nil when it has none.
    private var manifestProfiles: [String: [String]]? {
        guard let cwd = supabaseCwd else { return nil }
        return DbManifestLoader.profiles(from: (cwd as NSString).appendingPathComponent("scripts/db/manifest.json"))
    }

    /// Why no DB setup can begin now, or nil.
    private func dbSetupRefusal() -> ControlResult? {
        if dbResetRunning || dbSetupPipeline?.isRunning == true {
            let active: Set<DbStepStatus> = [.running, .healthCheck]
            let steps: [DbSetupStep] = dbSetupPipeline?.steps ?? []
            let step: DbSetupStep? = steps.first { active.contains($0.status) }
            return .runActive(step: step?.name ?? "starting")
        }
        if supabaseCwd == nil { return .refused("Cannot find supabase service cwd in config") }
        return nil
    }

    /// 422 when a reset has no valid seed scenario. The migrate profile seeds nothing.
    private func scenarioRefusal(profile: String) -> ControlResult? {
        guard dbPipelineFactory == nil, dbResetAction == nil, profile != DbResetPolicy.migrateProfile else { return nil }
        reloadDbSeedScenarios()
        guard selectedDbSeedScenario == nil else { return nil }
        return .invalidScenario(dbSeedScenarioLoadError ?? "Choose a valid seed scenario before resetting the database.")
    }

    private static func controlResult(_ outcome: DbSetupQueueOutcome) -> ControlResult {
        switch outcome {
        case .began, .queued: .accepted
        case .refused(let why): .refused(why)
        }
    }

    /// `POST /api/db-setup` and `/api/db-reset`.
    func apiRunDbSetup(profile: String) -> ControlResult {
        if let refusal = dbSetupRefusal() { return refusal }
        if let profiles = manifestProfiles, profiles[profile] == nil {
            return .unknownProfile(profile, known: profiles.keys.sorted())
        }
        if let refusal = scenarioRefusal(profile: profile) { return refusal }
        return Self.controlResult(runDbSetup(profile: profile))
    }

    /// `POST /api/db-setup/retry/<step>`: from a step of the shown pipeline, or of `reset`.
    func apiRetryDbSetup(from stepId: String) -> ControlResult {
        if let refusal = dbSetupRefusal() { return refusal }
        var known = dbSetupPipeline?.steps.map(\.id) ?? []
        if let profiles = manifestProfiles {
            known += (profiles["reset"] ?? []).filter { !known.contains($0) }
            guard known.contains(stepId) else { return .unknownStep(stepId, known: known) }
        }
        if dbSetupPipeline?.steps.contains(where: { $0.id == stepId }) != true,
           let refusal = scenarioRefusal(profile: "reset") { return refusal }
        return Self.controlResult(runDbSetup(from: stepId))
    }

    /// `POST /api/db-setup/step/<step>`: one step of any profile, also one that the
    /// shown pipeline lacks (`load-hotels` after a `fast` run).
    func apiRunDbSetupStep(_ stepId: String) -> ControlResult {
        if let refusal = dbSetupRefusal() { return refusal }
        if let profiles = manifestProfiles {
            var known: [String] = []
            for name in ["full", "reset"] + profiles.keys.sorted() {
                for id in profiles[name] ?? [] where !known.contains(id) { known.append(id) }
            }
            guard known.contains(stepId) else { return .unknownStep(stepId, known: known) }
            if let refusal = scenarioRefusal(profile: singleStepProfile(stepId)) { return refusal }
        }
        return Self.controlResult(runDbSetupStep(stepId))
    }

    func apiCancelDbSetup() -> ControlResult {
        guard dbResetRunning || dbSetupPipeline?.isRunning == true else {
            return .refused("No database setup is running.")
        }
        cancelDbSetup()
        return .accepted
    }

    func apiCaptureIssue(_ description: String) -> ControlResult {
        guard debugTracker != nil else { return .refused("issue capture is off") }
        Task { await captureDebugIssue(trigger: "manual", serviceID: nil, summary: description) }
        return .accepted
    }

    func apiCloseIssue(_ id: String, resolution: String?) async -> ControlResult {
        guard let tracker = debugTracker else { return .refused("issue capture is off") }
        guard await tracker.closeIssue(id: id, resolution: resolution ?? "Closed via API") else {
            return .notFound("issue not found")
        }
        debugOpenIssueCount = await tracker.openIssueCount()
        return .done
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
        guard let loginCwd = graph?.nodes["universal-login"]?.resolvedCwd, !loginCwd.isEmpty else { return }
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
            restartPortalForNewWebhookSecret()
        } else if let cwd = graph?.nodes["travel-portal"]?.resolvedCwd {
            EnvCompatLayer(envFilePaths: [cwd + "/.env.local"]).write(key: name, value: value)
        }
    }

    /// The portal does not wait for Stripe, so it can run on an old secret or on
    /// none. Node reads `.env.local` when it boots: a running portal restarts.
    private func restartPortalForNewWebhookSecret() {
        guard let portal = serviceStates["travel-portal"], !isShuttingDown,
              portal.phase == .running || (portal.phase == .starting && portal.pid != nil) else { return }
        Task {
            await logStore.append(serviceID: "travel-portal", entry: LogEntry(
                stream: .stdout, text: Self.webhookSecretChangedLine
            ))
        }
        restartService("travel-portal")
    }

    nonisolated static let webhookSecretChangedLine =
        "[travel-runner] Stripe webhook secret changed — restarting Travel Portal to load it"
    nonisolated static let noWebhookSecretLine =
        "No Stripe webhook secret — payments will not confirm until Stripe runs."

    /// Says once per portal start that payments will not confirm: the portal is
    /// up or on its way and Stripe does not run. A secret in `.env.local` from an
    /// earlier run does not count: without Stripe no webhook arrives.
    private func warnIfNoWebhookSecret() async {
        guard !warnedNoWebhookSecret,
              let portal = serviceStates["travel-portal"],
              portal.phase == .starting || portal.phase == .running else { return }
        let stripeOff: Bool
        if let stripe = serviceStates["stripe"], isInProfile("stripe") {
            stripeOff = stripe.phase == .skipped || stripe.phase == .failed
        } else {
            stripeOff = true
        }
        guard stripeOff else { return }
        warnedNoWebhookSecret = true
        await logStore.append(serviceID: "travel-portal", entry: LogEntry(
            stream: .stderr, text: "[travel-runner] " + Self.noWebhookSecretLine
        ))
    }

    func clearCacheAndRestart(_ serviceID: String) {
        guard let cwd = serviceCwd(serviceID) else {
            postNotice(.service(serviceID), "No cwd found for \(serviceID)")
            return
        }
        guard queuedCacheClears.insert(serviceID).inserted else {
            showFeedback(ActionFeedback.alreadyRestarting(displayName(serviceID)), .info, serviceID: serviceID)
            return
        }
        Task {
            beginAction(serviceID)
            defer { endAction(serviceID) }
            do {
                var heldBy: String?
                try await replaceProcess(serviceID, onlyIf: {
                    heldBy = self.dependencyHolding(serviceID)
                    if heldBy != nil { self.queuedCacheClears.remove(serviceID) }
                    return heldBy == nil
                }, prepare: {
                    self.queuedCacheClears.remove(serviceID)
                    let nextCachePath = (cwd as NSString).appendingPathComponent(".next")
                    try? FileManager.default.removeItem(atPath: nextCachePath)
                    await self.logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stdout, text: "[travel-runner] Cleared .next cache"))
                    try? await self.clock.sleep(for: .seconds(1))
                })
                if let heldBy {
                    onActionFeedback?(keptRunningText(serviceID, heldBy), false)
                    return
                }
                clearCleanExitError(serviceID)
            } catch {
                recordFailure(serviceID, error: error, lastError: "\(error)")
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

    static let dbModeStartingRefusal =
        "A start is in progress — wait for it to finish, or stop the stack, then switch."
    static let dbModeSwitchingRefusal = "A database switch is in progress — wait for it to finish."
    static let dbModeStoppingRefusal = "The stack is stopping — wait for it to stop, then switch."
    static let devDatabaseConfirmationTitle = "Use the shared dev database?"
    static let switchToDevTitle = "Switch to Dev"
    static let dbToolsDevCaption = "Acts on the local database only. The portals currently use dev."

    /// The apps that read the database mode from their env, in the loaded profile.
    private var databaseModeServices: [String] { webServicesInStartOrder }

    /// The apps that a switch restarts now. A stopped stack restarts none. A service
    /// that the person stopped, that waits or that was skipped stays as it is; a
    /// failed one starts with the new env.
    private var databaseModeRestarts: [String] {
        guard health != .stopped else { return [] }
        return databaseModeServices.filter { serviceID in
            guard let phase = serviceStates[serviceID]?.phase else { return false }
            return phase != .stopped && phase != .pending && phase != .skipped
        }
    }

    /// Why the database mode cannot change to `target` now, or nil when it can. A
    /// switch is allowed when the stack is stopped, healthy or degraded. The restart
    /// of one service does not block it: the switch waits for the service's lock.
    func databaseModeRefusal(for target: DatabaseMode) -> String? {
        if startTask != nil { return Self.dbModeStartingRefusal }
        // Stop All resets the env to local when it ends, so a switch now would be lost.
        if isShuttingDown { return Self.dbModeStoppingRefusal }
        if actionsInFlight.contains("db-mode") { return Self.dbModeSwitchingRefusal }
        if target == .remote, let missing = missingHostedDevValues { return missing }
        return nil
    }

    /// The notice when a shared .env lacks the hosted dev values, or nil. Hosted dev
    /// comes from each app's shared .env; the runner block then stops overriding Supabase.
    private var missingHostedDevValues: String? {
        let apps = ["travel-portal"] + (isInProfile("partner-portal") ? ["partner-portal"] : [])
        let lacking = apps.filter { serviceID in
            guard let shared = sharedEnvPath(serviceID),
                  let url = RunnerEnv.value(of: "AMATEUR_SUPABASE_URL", inFile: shared) else { return true }
            return url.isEmpty
        }
        guard !lacking.isEmpty else { return nil }
        let files = lacking.map { $0 == "travel-portal" ? "apps/booking-portal/.env" : "apps/partner-portal/.env" }
        return "Hosted dev values are missing from \(files.joined(separator: " and ")) — use Import… or Pull from Doppler in Health, then switch again"
    }

    /// The text under "Use the shared dev database?": which apps restart now and
    /// which use the dev data at the next start.
    var devDatabaseConfirmation: String {
        let restarts = databaseModeRestarts
        let later = databaseModeServices.filter { !restarts.contains($0) }
        guard !restarts.isEmpty else {
            return "\(namesList(later)) will read and write the shared hosted dev data at the next start."
        }
        let now = "\(namesList(restarts)) will restart and will read and write the shared hosted dev data."
        return later.isEmpty ? now : now + " \(namesList(later)) will use it at the next start."
    }

    /// "A", "A and B", "A, B and C" with display names; "The portals" for none.
    private func namesList(_ serviceIDs: [String]) -> String {
        let names = serviceIDs.map(displayName)
        guard let last = names.last else { return "The portals" }
        return names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + last : last
    }

    /// Switches the database of the apps. A running stack restarts the apps that
    /// read it. Ask the person before a switch to dev: the dev data is shared.
    func setDatabaseMode(_ target: DatabaseMode) {
        guard target != dbMode else { return }
        if let refusal = databaseModeRefusal(for: target) {
            postNotice(.dbMode, refusal)
            return
        }

        if target == .remote {
            // The reset of a config load that still waits must not undo this choice.
            envResetAfterLoad?.cancel()
            notices.resolve(.dbMode)
            dbMode = .remote
            writeAppEnv()
        } else {
            notices.resolve(.dbMode)
            resetEnvToLocalhost()
        }

        guard health != .stopped else { return }

        // A degraded stack switches too. The question named the same apps, in start order.
        let servicesToRestart = databaseModeRestarts
        beginAction("db-mode")
        Task {
            defer { endAction("db-mode") }
            var switchFailed = false
            for serviceID in servicesToRestart {
                serviceStates[serviceID]?.phase = .stopping
            }
            for serviceID in servicesToRestart {
                do {
                    let outcome = try await replaceProcess(serviceID)
                    if let why = notRestarted(serviceID, outcome) {
                        postNotice(.dbMode, "DB mode switch failed for \(displayName(serviceID)): \(why)")
                        switchFailed = true
                    }
                } catch {
                    recordFailure(serviceID, error: error, lastError: "DB mode switch failed for \(displayName(serviceID)): \(error)")
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

    /// The web services that a DB mode switch and the LAN toggle restart, in start
    /// order: Universal Login is up again before the portals that need it start.
    private var webServicesInStartOrder: [String] {
        let web: Set = ["universal-login", "travel-portal", "partner-portal"]
        return sortedServiceIDs.filter { web.contains($0) && isInProfile($0) }
    }

    /// Why a restart of a mode switch did not bring the service back, or nil when it did.
    private func notRestarted(_ serviceID: String, _ outcome: StartOutcome?) -> String? {
        switch outcome {
        case .skipped(let why)?: return "skipped — \(why)"
        case .blocked(let dependency)?: return "not started — waiting for \(dependencyState(of: waitTarget(dependency)))"
        case .refused(let why)?: return why
        case .launched?, .reused?, .alreadyHealthy?, nil: return nil
        }
    }

    func toggleNetworkMode() {
        guard !isTogglingNetwork else { return }
        networkMode.toggle()
        applyNetworkMode()
    }

    /// What LAN mode says when the Mac has no LAN address.
    static let noLanAddressText = "No LAN address found — connect to Wi-Fi or Ethernet, then try again."
    /// What the log says when LAN mode loses its address and goes back to localhost.
    static let lanAddressLostLine = "[travel-runner] The network changed and there is no LAN address now — switching back to localhost mode"

    /// Applies the current `networkMode` to env files and restarts LAN services.
    /// It uses `address` when the caller found one, and else finds the LAN
    /// address, so a network change with a new address uses it too.
    func applyNetworkMode(address: LanAddress? = nil) {
        guard !isTogglingNetwork else {
            // A new LAN address can come while a toggle runs. If the request were
            // dropped, the env files would keep the old address. Run it after the current one.
            networkReapplyPending = true
            return
        }
        isTogglingNetwork = true
        let requestedMode = networkMode

        Task {
            var mode = requestedMode
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
                var found = address
                if found == nil { found = await findLanAddress() }
                if let found {
                    lanAddress = found
                } else if lanAddress == nil {
                    // The user turned LAN mode on. LAN mode on 127.0.0.1 reaches
                    // no phone, so it stays off and nothing restarts.
                    networkMode = false
                    onActionFeedback?(Self.noLanAddressText, false)
                    return
                } else {
                    // LAN mode was on and its address is gone: the env files point
                    // at an address the Mac no longer has, so go back to localhost.
                    await logStore.append(serviceID: "travel-portal", entry: LogEntry(stream: .stdout, text: Self.lanAddressLostLine))
                    networkMode = false
                    mode = false
                    lanAddress = nil
                }
            } else {
                lanAddress = nil
            }

            let ip = lanAddress?.ip ?? "localhost"
            writeAppEnv()

            let servicesToRestart = webServicesInStartOrder

            for serviceID in servicesToRestart {
                serviceStates[serviceID]?.phase = .stopping
            }

            var restartFailed = false
            for serviceID in servicesToRestart {
                do {
                    let outcome = try await replaceProcess(serviceID, prepare: {
                        await self.logStore.append(
                            serviceID: serviceID,
                            entry: LogEntry(stream: .stdout, text: "[travel-runner] Network mode \(mode ? "ON — http://\(ip)" : "OFF — localhost only")")
                        )
                    })
                    if let why = notRestarted(serviceID, outcome) {
                        postNotice(.lan, "Network mode restart failed for \(displayName(serviceID)): \(why)")
                        restartFailed = true
                    }
                } catch {
                    recordFailure(
                        serviceID, error: error, lastError: "Network mode restart failed for \(displayName(serviceID)): \(error)"
                    )
                    restartFailed = true
                }
            }

            recalculateHealth()
            if restartFailed {
                onActionFeedback?("LAN mode toggle hit errors — check Status", false)
            } else {
                let port = serviceStates["travel-portal"]?.definition.probe?.port ?? 3002
                onActionFeedback?(mode ? "LAN mode on — open http://\(ip):\(port) on your phone" : "LAN mode off — localhost only", true)
            }
        }
    }

    /// The network changed (`NetworkObserver`). The web servers listen on all
    /// addresses, so the same address needs nothing. A new LAN address needs new
    /// URLs in the env files, and so a restart of the LAN services. No address
    /// goes back to localhost mode, as the env files name an address that is gone.
    func handleNetworkChange() async {
        guard networkMode, !isShuttingDown else { return }
        let found = await findLanAddress()
        guard networkMode, !isShuttingDown, let old = lanAddress else { return }
        guard let found else {
            // The env files still name the old address, which the Mac no longer
            // has, so the browser on localhost cannot reach Supabase or the login.
            await logStore.append(serviceID: "travel-portal", entry: LogEntry(stream: .stdout, text: Self.lanAddressLostLine))
            networkMode = false
            applyNetworkMode()
            return
        }
        guard found.ip != old.ip else {
            // Same address, maybe on another interface: the URLs stay right.
            lanAddress = found
            return
        }
        await logStore.append(serviceID: "travel-portal", entry: LogEntry(
            stream: .stdout,
            text: "[travel-runner] LAN address changed (\(old.ip) → \(found.ip)) — applying LAN mode again"
        ))
        applyNetworkMode(address: found)
    }

    private func shellOutput(_ command: String, cwd: String? = nil) async -> (String, Bool) {
        let result = await shell.run(command, cwd: cwd)
        return (result.stdout, result.succeeded)
    }

    /// A restart that a person or the API asks for. It clears the failure history:
    /// the circuit breaker and the backoff start again. With `stopsStack`, a restart
    /// of Supabase stops its containers first; without it, it only starts what is down.
    func restartService(_ serviceID: String, stopsStack: Bool = false) {
        if serviceID == "stripe" { resetStripeRetries() }
        let stopsStack = stopsStack && isSupabaseStack(serviceID)
        if isSupabaseStack(serviceID) { supabaseRepairUsed = false }
        let name = serviceStates[serviceID]?.definition.displayName ?? serviceID
        guard queuedRestarts.insert(serviceID).inserted else {
            showFeedback(ActionFeedback.alreadyRestarting(name), .info, serviceID: serviceID)
            return
        }
        Task {
            beginAction(serviceID)
            defer { endAction(serviceID) }
            await waitForEnvResetOfLoad()
            do {
                var heldBy: String?
                var stackDidNotStop = false
                let outcome = try await replaceProcess(serviceID, stoppedPhase: .pending, onlyIf: {
                    heldBy = self.dependencyHolding(serviceID)
                    if heldBy != nil { self.queuedRestarts.remove(serviceID) }
                    return heldBy == nil
                }, prepare: {
                    self.queuedRestarts.remove(serviceID)
                    // A stopped stack refuses the start: its containers stay as they are.
                    if stopsStack, !self.isShuttingDown, self.health != .stopped,
                       let definition = self.graph?.nodes[serviceID] {
                        self.serviceStates[serviceID]?.phase = .stopping
                        stackDidNotStop = !(await self.stopSupabaseStack(definition))
                        self.serviceStates[serviceID]?.phase = .pending
                    }
                    try? await self.clock.sleep(for: .seconds(1))
                })
                if let heldBy {
                    showFeedback(keptRunningText(serviceID, heldBy), .error, serviceID: serviceID)
                    return
                }
                // A crash during the start: the automatic restart gives the answer.
                if case .launched = outcome { await awaitReplacingLaunch(serviceID) }
                let (text, ok) = restartFeedback(serviceID, outcome)
                if ok { clearCleanExitError(serviceID) }
                // The containers ran on, so the start only reused them: nothing restarted.
                if stackDidNotStop {
                    showFeedback(SupabaseStackHealth.didNotStopText, .error, serviceID: serviceID)
                } else {
                    showFeedback(text, ok ? .success : .error, serviceID: serviceID)
                }
            } catch {
                recordFailure(serviceID, error: error, lastError: "\(error)")
                showFeedback("\(name) restart failed", .error, serviceID: serviceID)
            }
            recalculateHealth()
        }
    }

    nonisolated static let stackStoppedRefusal = "Not started — the stack is stopped. Press Start."

    /// A deliberate restart of a service that runs, while a dependency is not up: the
    /// new process would only wait, so the old one keeps running. The dependency, or nil.
    private func dependencyHolding(_ serviceID: String) -> String? {
        guard serviceStates[serviceID]?.phase == .running,
              case .blocked(let dependency) = dependencyGate(serviceID) else { return nil }
        return dependency
    }

    /// The toast of a restart that `dependencyHolding` kept from stopping the service.
    private func keptRunningText(_ serviceID: String, _ dependency: String) -> String {
        "\(displayName(serviceID)) not restarted — waiting for \(dependencyState(of: waitTarget(dependency))); it keeps running"
    }

    /// The toast of a restart: what the start did, not only that it ended.
    private func restartFeedback(_ serviceID: String, _ outcome: StartOutcome?) -> (String, Bool) {
        let name = displayName(serviceID)
        switch outcome {
        case .launched?, .reused?, .alreadyHealthy?, nil:
            switch serviceStates[serviceID]?.phase {
            case .running?, .completed?: return ("\(name) restarted", true)
            // Stripe ended at its start and is off.
            case .skipped?: return ("\(name) skipped — see its log", false)
            default: return ("\(name) restart failed", false)
            }
        case .skipped(let why)?:
            return ("\(name) skipped — \(why)", false)
        case .blocked(let dependency)?:
            return ("\(name) not started — waiting for \(dependencyState(of: waitTarget(dependency)))", false)
        case .refused(let why)?:
            return (why, false)
        }
    }

    // MARK: - Supabase stack

    /// What the Supabase confirmation restarts.
    enum SupabaseRestartRequest: Equatable, Sendable {
        case service
        case withDependents
    }

    /// True for the container-managed Supabase service: its launcher ends, and its
    /// containers run on.
    func isSupabaseStack(_ serviceID: String) -> Bool {
        serviceID == "supabase" && graph?.nodes[serviceID]?.shouldReuseIfRunning == true
    }

    /// The health of the local Supabase stack at `root`.
    private func supabaseStackHealth(root: String, dbPort: Int) async -> SupabaseStackHealth {
        if let supabaseHealthCheck { return await supabaseHealthCheck(root, dbPort) }
        return await SupabaseStackHealth.check(
            root: root, dbPort: dbPort, shell: shell, environment: graph?.nodes["supabase"]?.env ?? [:]
        )
    }

    /// Why the launched Supabase stack is not ready although its database port is
    /// open, or nil when it is ready (or the service is not Supabase). It throws when
    /// another project's database holds the port: this start cannot succeed.
    private func supabaseStackNotReady(_ serviceID: String, _ launch: ServiceLaunch) async throws -> String? {
        guard serviceID == "supabase", launch.definition.shouldReuseIfRunning,
              let root = launch.definition.resolvedCwd, let port = launch.definition.probe?.port else { return nil }
        switch await supabaseStackHealth(root: root, dbPort: port) {
        case .healthy: return nil
        case .partial(let missing): return "the database port is open; \(SupabaseStackHealth.missingText(missing))"
        case .down: return "the database port is open; no container of the stack runs"
        case .foreign(let occupant): throw await otherStackHoldsPort(port, occupant: occupant, root: root)
        }
    }

    /// Logs how to stop the other project's stack on the database port, and gives the error.
    private func otherStackHoldsPort(_ port: Int, occupant: String, root: String) async -> ServiceError {
        let expected = SupabaseProject.dbContainerName(root: root)
        await logStore.append(serviceID: "supabase", entry: LogEntry(
            stream: .stderr,
            text: "[travel-runner] Port \(port) is held by \(occupant), not \(expected). Stop that stack (npx supabase stop in its checkout, or: docker stop $(docker ps -q --filter name=_\(occupant.replacingOccurrences(of: "supabase_db_", with: ""))$)) and start again."
        ))
        return ServiceError.portHeldByOtherStack(port: port, container: occupant)
    }

    /// Runs `pnpm db:stop` in the stack's folder, with its output in the Supabase log.
    /// The data stays in the Docker volumes. True when it passed.
    @discardableResult
    private func stopSupabaseStack(_ definition: ServiceDefinition) async -> Bool {
        guard let root = definition.resolvedCwd else { return false }
        let id = definition.id
        let logStore = logStore
        serviceStates[id]?.progressNote = SupabaseStackHealth.stoppingText
        defer { serviceStates[id]?.progressNote = nil }
        let command = ShellQuote.join(SupabaseStackHealth.stopCommand)
        await logStore.append(serviceID: id, entry: LogEntry(
            stream: .stdout, text: "[travel-runner] Stopping the Supabase containers (\(command)). Data is kept."
        ))
        // One reader appends the lines, so the log keeps their order.
        let (lines, sink) = AsyncStream<LogEntry>.makeStream()
        let writer = Task {
            for await entry in lines { await logStore.append(serviceID: id, entry: entry) }
        }
        let result = await shell.run(
            command, cwd: root, environment: definition.env ?? [:], timeout: Self.supabaseStopTimeout,
            onLine: { line, stream in sink.yield(LogEntry(stream: stream, text: line)) }
        )
        sink.finish()
        await writer.value
        if !result.succeeded {
            let why = result.timedOut
                ? "did not finish in \(Self.supabaseStopTimeout.components.seconds) s"
                : "failed (exit \(result.exitCode))"
            await logStore.append(serviceID: id, entry: LogEntry(
                stream: .stderr, text: "[travel-runner] \(command) \(why) — see the lines above"
            ))
        }
        return result.succeeded
    }

    nonisolated static let supabaseStopTimeout: Duration = .seconds(120)

    /// The last line that `supabase start` printed, for the row while it starts.
    private func noteStartProgress(_ serviceID: String, _ lines: [String]) {
        guard let state = serviceStates[serviceID], state.phase == .starting,
              let line = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        state.progressNote = String(line.trimmingCharacters(in: .whitespaces).prefix(160))
    }

    /// A restart from the panel. Supabase asks first: its restart stops the containers.
    func requestRestart(_ serviceID: String) {
        guard isSupabaseStack(serviceID), health != .stopped else {
            restartService(serviceID)
            return
        }
        supabaseRestartConfirmation = .service
    }

    /// A restart with dependents from the panel. Supabase asks first.
    func requestCascadeRestart(_ serviceID: String) {
        guard isSupabaseStack(serviceID), health != .stopped else {
            restartCascade(serviceID)
            return
        }
        supabaseRestartConfirmation = .withDependents
    }

    func confirmSupabaseRestart() {
        guard let request = supabaseRestartConfirmation else { return }
        supabaseRestartConfirmation = nil
        switch request {
        case .service: restartService("supabase", stopsStack: true)
        case .withDependents: restartCascade("supabase")
        }
    }

    func cancelSupabaseRestart() {
        supabaseRestartConfirmation = nil
    }

    /// The menu offers "Stop Supabase" for a config with the Supabase stack.
    var hasSupabaseStack: Bool { isSupabaseStack("supabase") }

    /// "Stop Supabase" works while the stack is stopped, so no portal loses its database.
    var canStopSupabase: Bool {
        hasSupabaseStack && health == .stopped && stackIsIdle && !supabaseStopping
    }

    /// Stops the Supabase containers. The data is kept.
    func stopSupabase() {
        guard canStopSupabase, let definition = graph?.nodes["supabase"] else { return }
        supabaseStopping = true
        enqueueStackOperation(finally: { [weak self] in self?.supabaseStopping = false }) { [weak self] in
            guard let self else { return }
            self.serviceStates["supabase"]?.phase = .stopping
            let ok = await self.stopSupabaseStack(definition)
            self.serviceStates["supabase"]?.phase = .stopped
            self.onActionFeedback?(ok ? "Supabase stopped" : SupabaseStackHealth.didNotStopText, ok)
        }
    }

    /// The stop that quitting runs for Supabase, or nil. Supabase keeps running
    /// between sessions unless Settings says to stop it.
    var supabaseStopAtQuit: ServiceDefinition? {
        guard stopSupabaseOnQuit, isSupabaseStack("supabase"), var definition = graph?.nodes["supabase"] else { return nil }
        definition.stopCmd = SupabaseStackHealth.stopCommand
        return definition
    }

    // MARK: - Recovery actions

    /// The actions that a service row can run now. The others belong to the DB
    /// steps and the checks.
    func canPerform(_ action: RecoveryAction, for serviceID: String) -> Bool {
        switch action {
        case .restart, .startService, .stopForeignAndRetry, .stopProcessAndRetry, .openContainerRuntime: true
        case .keepWaiting: serviceStates[serviceID]?.phase == .starting && slowStartDeadlines[serviceID] != nil
        case .clearCacheAndRestart: Self.cacheClearingServices.contains(serviceID)
        case .installDependencies: serviceCwd(serviceID) != nil
        case .openLog: logStore.revealTarget(for: serviceID) != nil
        case .openHealth: onOpenHealth != nil
        case .openSettingsPaths: onOpenSettings != nil
        case .installStripe, .updateStripe, .stripeLogin, .importSharedEnv: serviceID == "stripe"
        default: false
        }
    }

    /// True while the buttons in a service's row must wait for an action of the
    /// service. The buttons of a slow start never wait: the action is that start, and
    /// "Keep waiting" and "Restart" are the way out of it.
    func inlineActionsBusy(_ serviceID: String) -> Bool {
        actionsInFlight.contains(serviceID) && serviceStates[serviceID]?.condition?.kind != .slowStart
    }

    /// Runs the button of a condition.
    func perform(_ action: RecoveryAction, for serviceID: String) {
        guard canPerform(action, for: serviceID) else { return }
        switch action {
        case .restart:
            requestRestart(serviceID)
        case .keepWaiting:
            keepWaiting(serviceID)
        case .startService:
            restartService(serviceID)
        case .stopForeignAndRetry(let port):
            // The port can be another port of the app (the HMR port). With no port in
            // the line, the button frees the port of the probe: the start alone
            // would refuse a process that the runner did not start.
            let target = port ?? serviceStates[serviceID]?.definition.probe?.port
            Task {
                if let target { await freePort(target, includingForeign: true) }
                restartService(serviceID)
            }
        case .stopProcessAndRetry(let pid, let startTime, let port, _):
            // The person pressed the button: the process need not be the runner's.
            // It must still be the process that the row named; the start checks again.
            let tools = portTools
            Task {
                if await Self.isSameProcess(pid, startTime: startTime, port: port, tools: tools) {
                    await tools.stopTree(pid)
                } else {
                    await logStore.append(serviceID: serviceID, entry: LogEntry(
                        stream: .stderr, text: "[travel-runner] PID \(pid) is no longer the process that blocked the start. Not stopped."
                    ))
                }
                restartService(serviceID)
            }
        case .clearCacheAndRestart:
            clearCacheAndRestart(serviceID)
        case .openContainerRuntime:
            let shell = shell
            Task { await ContainerRuntime.open(shell: shell) }
        case .installDependencies:
            installDependenciesAndRestart(serviceID)
        case .openHealth:
            onOpenHealth?()
        case .openSettingsPaths:
            onOpenSettings?()
        case .openLog:
            switch logStore.revealTarget(for: serviceID) {
            case .file(let file): NSWorkspace.shared.activateFileViewerSelecting([file])
            case .folder(let folder): NSWorkspace.shared.open(folder)
            case nil: break
            }
        case .installStripe:
            runStripeSetup(StripeLauncher.installCommand)
        case .updateStripe:
            runStripeSetup(StripeLauncher.updateCommand)
        case .stripeLogin:
            openStripeLogin()
        case .importSharedEnv:
            importSharedEnvForStripe()
        default:
            break
        }
    }

    nonisolated static let installWaitsText = "The install waits for the running start or step to finish"
    nonisolated static let installDroppedText = "Stop all cancelled the install that waited"

    /// `pnpm install --frozen-lockfile` at the root of the pnpm workspace of the
    /// service (`npm install` in a repo without one), with its output in the
    /// service's log, then a restart.
    private func installDependenciesAndRestart(_ serviceID: String) {
        guard let cwd = serviceCwd(serviceID) else { return }
        let name = displayName(serviceID)
        let (folder, command) = DependencyWatcher.installTarget(for: cwd)
        // A stack operation: it waits for a start, a stop or a DB step that runs.
        if !stackIsIdle { onActionFeedback?(Self.installWaitsText, true) }
        beginAction(serviceID)
        enqueueStackOperation(
            dropped: Self.installDroppedText, finally: { [weak self] in self?.endAction(serviceID) }
        ) { [self] in
            // Nil: a stop-all stopped the install.
            guard let result = await installPackages(
                serviceID, cwd: cwd, announce: "[travel-runner] Running \(command) in \(folder)"
            ) else { return }
            guard result.succeeded else {
                let why = Self.installFailure(result, folder: folder)
                postNotice(.service(serviceID), "\(command) for \(name) \(why)")
                onActionFeedback?("\(command) \(why)", false)
                return
            }
            restartService(serviceID)
        }
    }

    /// Installs the packages of the service's repo, with the output in the service's
    /// log. One install runs per install folder: a second caller writes one line and
    /// waits for the install that runs. A successful install records the lockfile
    /// hash in `deps.json`. Nil when a stop-all came during the install: it cancels
    /// the install, and the caller does nothing more.
    private func installPackages(_ serviceID: String, cwd: String, announce: String) async -> CommandResult? {
        let (folder, command) = DependencyWatcher.installTarget(for: cwd)
        let logStore = logStore
        let stops = stopAllCount
        if let running = installTasks[folder] {
            await logStore.append(serviceID: serviceID, entry: LogEntry(
                stream: .stdout, text: "[travel-runner] Waiting for the \(command) that runs in \(folder)"
            ))
            let result = await running.value
            return stopAllCount == stops ? result : nil
        }
        let shell = shell
        let record = dependencyRecord
        let task = Task<CommandResult, Never> {
            await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stdout, text: announce))
            // One reader appends the lines, so the log keeps their order.
            let (lines, sink) = AsyncStream<LogEntry>.makeStream()
            let writer = Task {
                for await entry in lines { await logStore.append(serviceID: serviceID, entry: entry) }
            }
            let result = await shell.run(
                command, cwd: folder, environment: [:], timeout: EnvironmentChecker.installTimeout,
                onLine: { line, stream in sink.yield(LogEntry(stream: stream, text: line)) }
            )
            sink.finish()
            await writer.value
            if result.succeeded { DependencyWatcher.recordInstall(folder: folder, record: record) }
            return result
        }
        installTasks[folder] = task
        let result = await task.value
        if installTasks[folder] == task { installTasks[folder] = nil }
        guard stopAllCount == stops else {
            await logStore.append(serviceID: serviceID, entry: LogEntry(
                stream: .stdout, text: "[travel-runner] Stop all stopped the \(command)"
            ))
            return nil
        }
        if result.succeeded {
            // The row drops its install button now, not at the next watcher check.
            npmStaleServices = npmStaleServices.filter { id in
                serviceCwd(id).map { DependencyWatcher.installTarget(for: $0).folder } != folder
            }
        }
        return result
    }

    /// pnpm prints this when `--frozen-lockfile` finds a lockfile that does not
    /// match a package.json.
    nonisolated static let outdatedLockfileMarker = "ERR_PNPM_OUTDATED_LOCKFILE"

    /// Why an install in `folder` failed, after its command: "failed (exit 1) — see its log".
    nonisolated static func installFailure(_ result: CommandResult, folder: String) -> String {
        let output = result.stdout + result.stderr
        if output.contains(EnvironmentChecker.registryRejectedMarker) {
            return "failed: \(EnvironmentChecker.registryRejectedText)"
        }
        if output.contains(outdatedLockfileMarker) {
            return "failed: the lockfile does not match package.json — run pnpm install in \(folder)"
        }
        let minutes = EnvironmentChecker.installTimeout.components.seconds / 60
        return result.timedOut
            ? "did not finish in \(minutes) minutes — see its log"
            : "failed (exit \(result.exitCode)) — see its log"
    }

    /// The services that check their own packages and are skipped without them.
    /// No install runs for them before a start.
    private static let ownPackageCheck: Set<String> = [
        ServiceCatalog.agentID, ServiceCatalog.platformCoreID, ServiceCatalog.eventDirectoryID,
    ]

    /// The state of the packages of the service, or nil for a service that gets no
    /// install from the runner: a oneshot, one with its own check, or one with no folder.
    private func dependencyState(_ serviceID: String) async -> DependencyState? {
        guard let definition = graph?.nodes[serviceID], definition.resolvedType == .daemon,
              !Self.ownPackageCheck.contains(serviceID),
              let cwd = definition.resolvedCwd, !cwd.isEmpty else { return nil }
        let record = dependencyRecord
        return await Task.detached { DependencyWatcher.state(of: cwd, record: record) }.value
    }

    /// The services that a branch change does not restart.
    nonisolated static let keptOnBranchChange: Set<String> = [ServiceCatalog.sequinID]
    nonisolated static let sequinBranchChangeLine =
        "[travel-runner] Branch changed — Sequin keeps running; restart it if scripts/local-cdc changed."

    /// The changed services that a branch change restarts: the running ones, but not Sequin.
    nonisolated static func branchChangeRestarts(_ changed: Set<String>, phases: [String: ServicePhase]) -> Set<String> {
        changed.filter { phases[$0] == .running && !keptOnBranchChange.contains($0) }
    }

    /// A branch change restarts the running services of the repo. When their packages
    /// are not fresh (the new branch changed the lockfile), the install runs first: the
    /// old packages would make the portal crash in a loop. After a failed install the
    /// services of that folder keep their process, and the banner says why and what
    /// to do. After a stop-all during the install nothing restarts.
    func restartAfterBranchChange(_ serviceIDs: [String]) async {
        var installed: [String: Bool] = [:]
        for serviceID in serviceIDs {
            guard let cwd = serviceCwd(serviceID) else { continue }
            let (folder, command) = DependencyWatcher.installTarget(for: cwd)
            guard installed[folder] == nil else { continue }
            guard let state = await dependencyState(serviceID), state != .fresh else {
                installed[folder] = true
                continue
            }
            beginAction(serviceID)
            let result = await installPackages(
                serviceID, cwd: cwd,
                announce: "[travel-runner] The lockfile changed — running \(command) before the restart"
            )
            endAction(serviceID)
            guard let result else { return }
            installed[folder] = result.succeeded
            if !result.succeeded {
                let why = Self.installFailure(result, folder: folder)
                let kept = serviceIDs.filter {
                    serviceCwd($0).map { DependencyWatcher.installTarget(for: $0).folder } == folder
                }.map(displayName)
                let names = kept.count > 1
                    ? kept.dropLast().joined(separator: ", ") + " and " + kept[kept.count - 1]
                    : kept.joined()
                let verb = kept.count == 1 ? "still runs" : "still run"
                let failure = "\(command) for \(displayName(serviceID)) \(why)"
                postNotice(
                    .service(serviceID),
                    (failure.hasSuffix(".") ? failure : failure + ".")
                        + " \(names) \(verb) the old packages; fix the cause, then press Install dependencies."
                )
                onActionFeedback?("\(command) \(why)", false)
            }
        }
        for serviceID in serviceIDs {
            let folder = serviceCwd(serviceID).map { DependencyWatcher.installTarget(for: $0).folder }
            if let folder, installed[folder] == false { continue }
            restartService(serviceID)
        }
    }

    /// A restart that the supervisor starts by itself after a failure. It keeps the
    /// failure history, so the circuit breaker and the backoff see the whole series.
    /// It releases the pending restart under the lock, in the step that changes the
    /// phase: an old waiter never sees a failed service with no restart due.
    private func autoRestart(_ serviceID: String) async {
        var released = false
        let release = {
            guard !released else { return }
            released = true
            self.releasePendingRestart(serviceID)
        }
        defer { release() }
        do {
            try await replaceProcess(serviceID, stoppedPhase: .pending, keepsFailureHistory: true, onlyIf: {
                release()
                // A manual restart or a mode switch can bring the service back first.
                guard let state = self.serviceStates[serviceID],
                      state.phase == .failed, !state.isCircuitBroken else { return false }
                state.restartCount += 1
                return true
            })
        } catch {
            recordFailure(serviceID, error: error, lastError: "\(error)")
        }
        recalculateHealth()
    }

    /// Shows a toast and lists it in Recent activity. A guard that refuses an action
    /// says so with `.info`; before, it did nothing.
    func showFeedback(_ message: String, _ style: ActionFeedback.Style, serviceID: String? = nil) {
        let feedback = ActionFeedback(message: message, style: style, serviceID: serviceID, at: clock.date())
        recentActivity.add(feedback)
        onFeedback?(feedback)
    }

    /// Lists the crash in Recent activity and posts its notification. The cause
    /// comes from the log of this launch, so it reads the log first.
    private func alertCrash(_ state: ServiceState, code: Int32, next: CrashAlert.Next, cause knownCause: String? = nil) {
        let definition = state.definition
        let launched = state.lastStarted ?? .distantPast
        Task {
            var cause = knownCause
            if cause == nil {
                let tail = await launchLogTail(state.id, since: launched)
                let probe = definition.probe
                cause = FailureAdvisor.cause(FailureAdvisor.Context(
                    name: definition.displayName, port: probe?.port, logTail: tail,
                    likelyCause: CrashCause.likelyCause(in: tail, serviceID: state.id, redactor: makeRedactor()),
                    runtime: ContainerRuntime.detect().displayName, command: definition.cmd, cwd: definition.resolvedCwd
                ))
            }
            let alert = CrashAlert(
                serviceID: state.id, name: definition.displayName, exitCode: code, cause: cause, next: next
            )
            recentActivity.add(ActionFeedback(
                message: "\(alert.title): \(alert.body)", style: .error, serviceID: state.id, at: clock.date()
            ))
            onServiceCrash?(alert)
        }
    }

    /// The last lines of the service's log since `launched`. The log keeps the lines
    /// of earlier launches; they are not the cause of this one.
    private func launchLogTail(_ serviceID: String, since launched: Date) async -> [String] {
        await logStore.entries(for: serviceID)
            .filter { $0.timestamp >= launched }
            .suffix(FailureAdvisor.logWindow).map(\.text)
    }

    /// The banner text for a daemon that ended with code 0.
    nonisolated static func cleanExitMessage(_ name: String) -> String {
        "\(name) exited (code 0) and was not restarted — restart it from its row"
    }

    /// The person restarted the service, as the banner asked. A newer error stays.
    private func clearCleanExitError(_ serviceID: String) {
        guard let name = serviceStates[serviceID]?.definition.displayName else { return }
        notices.resolve(.service(serviceID), ifText: Self.cleanExitMessage(name))
    }

    private func clearFailureHistory(_ serviceID: String) {
        serviceStates[serviceID]?.restartCount = 0
        serviceStates[serviceID]?.haltReason = nil
        serviceStates[serviceID]?.failureTimestamps = []
        serviceStates[serviceID]?.killTimestamps = []
        serviceStates[serviceID]?.lastKillSignal = nil
        serviceStates[serviceID]?.memoryNotified = false
        serviceStates[serviceID]?.cleanExitRestarted = false
    }

    private func displayName(_ serviceID: String) -> String {
        serviceStates[serviceID]?.definition.displayName ?? serviceID
    }

    // MARK: - Failure record

    /// A start that threw: the service is failed, its notice gets `text`, and the
    /// row gets the reason and the fix. With no `text` the notice
    /// goes behind the first failure of the start.
    private func recordFailure(_ serviceID: String, error: Error, lastError text: String?) {
        guard let state = serviceStates[serviceID] else { return }
        state.phase = .failed
        // The breaker posted why it stopped; the waiter that ends on it adds nothing.
        // A notice the person dismissed stays dismissed.
        if case ServiceError.autoRestartStopped = error, state.isCircuitBroken { return }
        postNotice(.service(serviceID), text ?? "\(error)", first: text != nil)
        recordFailure(serviceID, kind: failureKind(of: error, state: state), ownsBanner: text != nil)
    }

    private func failureKind(of error: Error, state: ServiceState) -> FailureAdvisor.Kind {
        guard let serviceError = error as? ServiceError else { return .message("\(error)") }
        switch serviceError {
        case .probeTimeout(_, let seconds, let alive, let lastProbe):
            return .probeTimeout(seconds: seconds, processAlive: alive, lastProbe: lastProbe)
        case .oneshotFailed, .exitedDuringStartup:
            return .exited(code: state.exitCode)
        case .commandNotRunnable(_, let finding):
            return .cannotRun(finding)
        case .installFailed:
            return .installFailed(serviceError.description)
        case .portHeldByProcess(_, let port, let occupant):
            let pid = occupant.listener.pid
            return .blocked(serviceError.description, action: .stopProcessAndRetry(
                pid: pid, startTime: portTools.facts(pid)?.startTime, port: port
            ))
        case .otherNextDev(let pid, _, _, let startTime):
            return .blocked(serviceError.description, action: .stopProcessAndRetry(
                pid: pid, startTime: startTime, sameFolder: true
            ))
        default:
            return .message(serviceError.description)
        }
    }

    /// Says why the service failed. It reads the log of this launch, so the
    /// condition comes a moment later; a newer record, or a new start, wins.
    /// `CrashCause.likelyCause` runs here whether or not issue capture is on.
    /// `ownsBanner` false: another service failed first in this start. Its notice
    /// stays the newest error; the refined notice of this one goes behind it.
    func recordFailure(_ serviceID: String, kind: FailureAdvisor.Kind, ownsBanner: Bool = true) {
        guard let state = serviceStates[serviceID] else { return }
        state.failureRecordCount += 1
        let record = state.failureRecordCount
        let launched = state.lastStarted ?? .distantPast
        let definition = state.definition
        let probe = definition.probe
        let probePath = probe?.type == .http ? probe?.url.flatMap { URL(string: $0)?.path }.flatMap { $0.isEmpty ? nil : $0 } : nil
        // The notice of this failure ("exited before it was ready", "failed 3 times in a minute").
        let banner = notices.text(.service(serviceID))
        Task {
            let tail = await launchLogTail(serviceID, since: launched)
            let likely = CrashCause.likelyCause(in: tail, serviceID: serviceID, redactor: makeRedactor())
            guard state.failureRecordCount == record, state.phase == .failed else { return }
            let context = FailureAdvisor.Context(
                name: definition.displayName, port: probe?.port, probePath: probePath, logTail: Array(tail),
                likelyCause: likely, canClearCache: Self.cacheClearingServices.contains(serviceID),
                runtime: ContainerRuntime.detect().displayName, command: definition.cmd, cwd: definition.resolvedCwd
            )
            state.likelyCause = likely
            var condition = FailureAdvisor.advise(kind, context, now: clock.date())
            // A verification run of the full profile fails without its seed: say which one.
            if let hint = verificationSeedHint(serviceID) {
                condition.detail = [condition.detail, hint].compactMap { $0 }.joined(separator: " ")
            }
            state.condition = condition
            // A pnpm run that ended with 1 because the packages or the script are
            // missing: the notice says so too, like exit 127. A newer error stays.
            switch kind {
            case .exited, .probeTimeout, .crashLoop, .exhausted:
                if let banner, notices.text(.service(serviceID)) == banner,
                   let finding = FailureAdvisor.commandFinding(context) {
                    postNotice(
                        .service(serviceID), CommandDiagnosis.message(finding, name: definition.displayName), first: ownsBanner
                    )
                }
            default:
                break
            }
        }
    }

    /// Records why an optional service is off, or why a service did not start.
    private func noteSkip(
        _ state: ServiceState, _ kind: ServiceCondition.Kind, _ headline: String, detail: String? = nil,
        actions: [RecoveryAction] = []
    ) {
        state.failureRecordCount += 1
        state.likelyCause = nil
        state.condition = ServiceCondition(kind: kind, headline: headline, detail: detail, actions: actions, since: clock.date())
        // The skip replaces the failure, so its notice is stale.
        notices.resolve(.service(state.id))
    }

    /// Skips a service that cannot run here, with the reason in its row and its log.
    private func skipOptional(
        _ state: ServiceState, _ headline: String, detail: String? = nil, actions: [RecoveryAction]
    ) async {
        state.phase = .skipped
        state.pid = nil
        noteSkip(state, .optionalOff, headline, detail: detail, actions: actions)
        let text = [headline, detail].compactMap { $0 }.joined(separator: " ")
        await logStore.append(serviceID: state.id, entry: LogEntry(stream: .stderr, text: "[travel-runner] \(text)"))
    }

    /// Why the skipped dependency `blocker` did not run, as "<name>: <reason>", with
    /// its buttons that do not act on a service. A dependency that was itself skipped
    /// for its dependency passes on that reason.
    private func dependencySkipReason(_ blocker: String) -> (detail: String?, actions: [RecoveryAction]) {
        guard let condition = serviceStates[blocker]?.condition else { return (nil, []) }
        let actions = condition.actions.filter { $0 == .openSettingsPaths || $0 == .openHealth }
        if let definition = graph?.nodes[blocker], ServiceCatalog.missingOptionalRepo(definition) == nil,
           case .unavailable = dependencyGate(blocker) {
            return (condition.detail, actions)
        }
        return ("\(displayName(blocker)): \(condition.headline)", actions)
    }

    nonisolated static func qstashCLIExists(_ cwd: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: (cwd as NSString).appendingPathComponent(ServiceCatalog.qstashBinary))
    }

    /// True when the stream services have their packages and the lockfile did not change.
    private func streamPackagesAreCurrent(_ cwd: String) async -> Bool {
        let record = dependencyRecord
        return await Task.detached {
            FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent("package.json"))
                && DependencyWatcher.state(of: cwd, record: record) == .fresh
        }.value
    }

    /// The seed hint for a verification service of the full profile, when the chosen
    /// seed scenario is not the one it needs. Nil on a branch without that scenario.
    private func verificationSeedHint(_ serviceID: String) -> String? {
        guard profile == .full, ServiceCatalog.verificationSeedServices.contains(serviceID),
              dbSeedScenarios.contains(where: { $0.id == ServiceCatalog.verificationSeedScenarioID }),
              selectedDbSeedScenarioID != ServiceCatalog.verificationSeedScenarioID else { return nil }
        return ServiceCatalog.verificationSeedHint
    }

    /// The Next apps: their `.next` cache can be cleared.
    static let cacheClearingServices: Set<String> = ["travel-portal", "partner-portal"]

    /// Stops the service's process and starts a new one. The stop and the start hold
    /// the service's lock, so two requests cannot start two processes that fight for
    /// the port. `prepare` runs between them. The wait for readiness holds no lock: a
    /// process that fails while it starts can be restarted at once.
    /// Returns what the start did, or nil when `onlyIf` said no.
    @discardableResult
    private func replaceProcess(
        _ serviceID: String,
        stoppedPhase: ServicePhase = .starting,
        keepsFailureHistory: Bool = false,
        onlyIf condition: (@MainActor () -> Bool)? = nil,
        prepare: (@MainActor () async -> Void)? = nil
    ) async throws -> StartOutcome? {
        restartsInFlight[serviceID, default: 0] += 1
        defer {
            let remaining = (restartsInFlight[serviceID] ?? 1) - 1
            restartsInFlight[serviceID] = remaining > 0 ? remaining : nil
        }
        let outcome = try await lifecycle.withLock(serviceID) { () -> StartOutcome? in
            if let condition, !condition() { return nil }
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
        if case .launched(let launch)? = outcome { try await awaitReady(serviceID, launch) }
        return outcome
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
            var stackDidNotStop = false
            for id in topoOrder.reversed() {
                await lifecycle.withLock(id) {
                    serviceStates[id]?.phase = .stopping
                    await processRunner.stop(serviceID: id)
                    // Supabase's launcher has ended: a restart stops its containers.
                    if isSupabaseStack(id), !isShuttingDown, health != .stopped, let definition = graph.nodes[id] {
                        supabaseRepairUsed = false
                        stackDidNotStop = !(await stopSupabaseStack(definition))
                    }
                    serviceStates[id]?.phase = .stopped
                }
            }

            for id in topoOrder {
                serviceStates[id]?.phase = .starting
                clearFailureHistory(id)
                do {
                    switch try await startService(id) {
                    case .launched:
                        // A crash during the start: the automatic restart gives the answer.
                        await awaitReplacingLaunch(id)
                    case .refused(let why):
                        onActionFeedback?(why, false)
                        return
                    default:
                        break
                    }
                } catch {
                    let text = Self.restartWithDependentsFailedText(displayName(id), cause: "\(error)")
                    recordFailure(id, error: error, lastError: text)
                    recalculateHealth()
                    onActionFeedback?(text, false)
                    return
                }
                if serviceStates[id]?.phase == .failed {
                    recalculateHealth()
                    let cause = serviceStates[id]?.condition?.headline ?? "it failed"
                    onActionFeedback?(Self.restartWithDependentsFailedText(displayName(id), cause: cause), false)
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
            // The containers ran on, so the start only reused them.
            if stackDidNotStop {
                onActionFeedback?(SupabaseStackHealth.didNotStopText, false)
            } else {
                onActionFeedback?("\(name) restarted with dependents", true)
            }
        }
    }

    /// The failure of "Restart with dependents": where it stopped, why, and where to look.
    nonisolated static func restartWithDependentsFailedText(_ name: String, cause: String) -> String {
        "Restart with dependents failed at \(name): \(cause) — see its log"
    }

    /// "Retry failed": starts what does not run, and leaves the services that do.
    func retryStartAll() {
        preflightChecks = []
        completedPhases = []
        resolveStackNotices()
        startAll(mode: .missingOnly)
    }

    /// "Restart everything": a Start All that restarts the services that run too.
    func restartEverything() {
        preflightChecks = []
        completedPhases = []
        resolveStackNotices()
        startAll(mode: .everything)
    }

    nonisolated static let profileSavedText = "Profile saved — applies on the next start."
    nonisolated static let applyProfileTitle = "Apply now"

    /// Switches the profile and saves it to services.json. A stopped stack uses it
    /// at the next start. While the stack runs, the running services stay as they
    /// are until the next start or "Apply now" (`profileApplyPending`).
    func setProfile(_ newProfile: RunProfile) {
        do {
            try saveProfile(newProfile)
        } catch {
            postNotice(.profile, "Could not save profile: \(error)")
            return
        }
        notices.resolve(.profile)
        let changed = newProfile != profile
        profile = newProfile
        profileMembers = newProfile.members(of: loadedServices)
        if health == .stopped, startTask == nil, stopTask == nil {
            profileApplyPending = false
            onActionFeedback?("Profile: \(newProfile.displayName)", true)
        } else {
            profileApplyPending = profileApplyPending || changed
            showFeedback(Self.profileSavedText, .info)
        }
    }

    /// "Apply now": stops the services that left the profile, then starts the ones
    /// that joined it ("Retry failed": the services that run stay as they are).
    func applyProfileNow() {
        profileApplyPending = false
        let live: Set<ServicePhase> = [.running, .starting, .pending, .waiting, .failed]
        let leaving = sortedServiceIDs.filter { id in
            guard !isInProfile(id), let phase = serviceStates[id]?.phase else { return false }
            return live.contains(phase)
        }
        if !leaving.isEmpty {
            enqueueStackOperation { [self] in
                // Dependents first: a service stops before what it needs.
                for id in leaving.reversed() {
                    await lifecycle.withLock(id) {
                        serviceStates[id]?.phase = .stopping
                        await processRunner.stop(serviceID: id)
                        serviceStates[id]?.phase = .stopped
                        serviceStates[id]?.clearCondition()
                    }
                    notices.resolve(.service(id))
                }
                recalculateHealth()
            }
        }
        startAll(mode: .missingOnly)
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
        // A reconfigure replaced this watcher: its answers are for other folders.
        if Task.isCancelled { return }
        await publishGitState(watcher)

        while !Task.isCancelled {
            try? await clock.sleep(for: .seconds(5))
            if Task.isCancelled { break }
            let changes = await watcher.check()
            // The fetch runs here, never in a stack operation: a remote that does
            // not answer must not hold a start or a DB step.
            await watcher.fetchAndCount(fetchInterval: changes.isEmpty ? 120 : 0)
            if Task.isCancelled { break }
            await publishGitState(watcher)
            if !changes.isEmpty {
                behindBannerDismissed = false
                await applyBranchChanges(changes)
            }
        }
    }

    /// The branches, the behind counts and the fetch failures of the watcher.
    private func publishGitState(_ watcher: GitBranchWatcher) async {
        let branches = await watcher.branches
        let behind = await watcher.behindCounts
        let failures = await watcher.fetchFailures
        gitBranches = branches
        if behind != gitBehindCounts {
            gitBehindCounts = behind
            behindBannerDismissed = false
        }
        gitFetchFailures = failures
    }

    nonisolated static func branchRestartLine(_ branch: String, _ name: String) -> String {
        "[travel-runner] Branch changed to '\(branch)' — restarting \(name)"
    }

    nonisolated static func branchNoRestartLine(_ branch: String) -> String {
        "[travel-runner] Branch changed to '\(branch)' — no restart needed (dev servers hot-reload)"
    }

    /// A confirmed branch change. Only a change of the packages, the lockfile, the
    /// Next config or the env files restarts the running services of the repo;
    /// other files hot-reload. The database check runs for any change. A stopped
    /// stack restarts nothing: the next start reads the new branch. The runner
    /// version banner follows the new branch at once.
    func applyBranchChanges(_ changes: [GitBranchWatcher.Change]) async {
        guard health != .stopped else {
            let monorepo = changes.contains { $0.serviceIDs.contains("supabase") || $0.serviceIDs.contains("travel-portal") }
            if monorepo, let cwd = serviceCwd("supabase") ?? serviceCwd("travel-portal") {
                refreshCompatibility(cwd: cwd)
            }
            return
        }
        var changed: Set<String> = []
        var restarts: Set<String> = []
        for change in changes {
            changed.formUnion(change.serviceIDs)
            if change.needsRestart { restarts.formUnion(change.serviceIDs) }
            for serviceID in sortedServiceIDs where change.serviceIDs.contains(serviceID) {
                // A restart of Sequin tears down and rebuilds its containers: it keeps
                // running. Only a running service gets a line.
                guard serviceStates[serviceID]?.phase == .running else { continue }
                let text: String
                if Self.keptOnBranchChange.contains(serviceID) {
                    text = Self.sequinBranchChangeLine
                } else if change.needsRestart {
                    text = Self.branchRestartLine(change.branch, displayName(serviceID))
                } else {
                    text = Self.branchNoRestartLine(change.branch)
                }
                await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stdout, text: text))
            }
        }

        // A stack operation: it waits for a start, a stop or a DB step that runs.
        await enqueueStackOperation { [self] in
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
            let running = Self.branchChangeRestarts(restarts, phases: serviceStates.mapValues(\.phase))
            await restartAfterBranchChange(sortedServiceIDs.filter { running.contains($0) })
        }.value
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
    @discardableResult
    func runDbSetup(from stepId: String? = nil, profile: String = "reset") -> DbSetupQueueOutcome {
        let origin: DbSetupOrigin = profile == DbResetPolicy.migrateProfile
            ? .applyMigrations : (stepId == nil ? .manual : .retry)
        return queueDbSetup { [self] in
            beginDbSetup(cwd: supabaseCwd, profile: profile, reason: nil, origin: origin, from: stepId)
        }
    }

    nonisolated static let dbSetupWaitsText = "The database step waits for the running start or step to finish"
    nonisolated static let dbSetupDroppedText = "Stop all cancelled the database step that waited"

    /// What became of a DB setup that a person asked for.
    enum DbSetupQueueOutcome: Equatable, Sendable {
        /// The checks passed and the setup runs.
        case began
        /// It waits for the start, the stop or the operation that runs.
        case queued
        /// Nothing runs; the reason.
        case refused(String)
    }

    /// A DB setup that a person asked for is a stack operation: it waits for a
    /// start, a stop or another operation that runs. With none it begins at once,
    /// so the caller learns whether it could begin.
    @discardableResult
    private func queueDbSetup(_ begin: @escaping @MainActor () -> DbSetupRun?) -> DbSetupQueueOutcome {
        guard stackIsIdle else {
            onActionFeedback?(Self.dbSetupWaitsText, true)
            enqueueStackOperation(dropped: Self.dbSetupDroppedText) { [self] in
                guard let run = begin() else { return }
                _ = await completeDbSetup(run)
            }
            return .queued
        }
        guard let run = begin() else {
            return .refused(notices.text(.dbSetup) ?? ActionFeedback.dbSetupRunning)
        }
        // The setup has begun: the DB controls are locked. A Stop All in this turn
        // of the main actor drops the operation before its body runs, and then
        // nothing would unlock them.
        final class Ran { var value = false }
        let ran = Ran()
        enqueueStackOperation(dropped: Self.dbSetupDroppedText, finally: { [self] in
            guard !ran.value else { return }
            if run.runner == nil || dbSetupRunner === run.runner { dbResetRunning = false }
        }) { [self] in
            ran.value = true
            _ = await completeDbSetup(run)
        }
        return .began
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
    /// With no valid cached dump, the download runs first as its own step, under its
    /// own time limit: a load that downloads itself would get only the load's limit.
    func loadHotels() {
        var leading: [String] = []
        if case .cached = hotelDump {} else { leading = [HotelCatalog.fetchStepID] }
        queueDbSetup { [self] in
            beginDbSetup(
                cwd: supabaseCwd, profile: "reset", reason: nil, origin: .singleStep, from: HotelCatalog.loadStepID,
                singleStep: true, reusePipeline: false, leadingSteps: leading
            )
        }
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
        /// Runs only the steps of the pipeline from DB Tools, never a reset.
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
                let message = (notices.text(.dbSetup) ?? "the setup did not start")
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
                postNotice(.dbSetup, DbResetPolicy.emptySetupFailedText(step: "setup", message: message))
            }
            return false
        }
        return await completeDbSetup(run)
    }

    /// The checks and the guard. Nil when nothing may start; the reason is then in
    /// the db-setup notice, or another setup runs.
    /// `reusePipeline` false builds a new pipeline for a step, also when one is shown.
    /// A single step gets a pipeline of that step alone, so its Retry and Run All
    /// never reach a reset. `stepArguments` go after the command of the step `stepId`
    /// ("Re-download hotels": `--force`); only that one-step pipeline holds them.
    /// `leadingSteps` of the profile run before the single step, in the profile's
    /// order; one the profile lacks is left out.
    private func beginDbSetup(
        cwd: String?, profile: String, reason: String?, origin: DbSetupOrigin, from stepId: String?,
        singleStep: Bool = false, reusePipeline: Bool = true, stepArguments: String? = nil,
        leadingSteps: [String] = []
    ) -> DbSetupRun? {
        guard !dbResetRunning, dbSetupPipeline?.isRunning != true else {
            showFeedback(ActionFeedback.dbSetupRunning, .info)
            return nil
        }
        guard let cwd else {
            postNotice(.dbSetup, "Cannot find supabase service cwd in config")
            return nil
        }
        guard !refreshCompatibility(cwd: cwd) else { return nil }

        var pipeline: DbSetupPipeline?
        var runner: DbSetupRunner?
        var singleStep = singleStep
        var stepId = stepId
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
                    let leading = newPipeline.steps.filter { leadingSteps.contains($0.id) && $0.id != step.id }
                    newPipeline.steps = leading + [stepArguments.map { step.appending(arguments: $0) } ?? step]
                    newPipeline.isSingleStep = true
                    // The run starts at the first step of this pipeline.
                    stepId = newPipeline.steps.first?.id
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
        notices.resolve(.dbSetup)
        if let reason {
            postNotice(.dbProgress, reason, severity: .info)
        } else {
            notices.resolve(.dbProgress)
        }
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
            // A pipeline from DB Tools with more than one step runs from the step on,
            // like a Retry; it holds no reset.
            if run.singleStep, pipeline.steps.count == 1, let step = pipeline.steps.first(where: { $0.id == run.stepId }) {
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
        // A newer setup may run by now and show its own progress.
        if let reason = run.reason { notices.resolve(.dbProgress, ifText: reason) }
        if ok {
            notices.resolve(.dbSetup)
            if run.pipeline != nil { await refreshLocalSupabaseKeys() }
            if isApply {
                migrationsAppliedNotice = DbResetPolicy.appliedText
                onActionFeedback?("Migrations applied", true)
            } else if dbSetupFailedAtStart, !run.singleStep {
                // The start stays halted until Retry, so the header says what to do.
                postNotice(.dbSetup, DbResetPolicy.setUpAfterHaltText)
            } else if Self.isReset(run.pipeline), !runningPortalIDs.isEmpty {
                // The portals still hold the old data (sessions, caches).
                portalRestartNotice = Self.portalRestartText
            }
        } else if let failed {
            let message = failed.errorMessage ?? "unknown error"
            postNotice(.dbSetup, run.origin == .emptyDatabaseAtStart
                ? DbResetPolicy.emptySetupFailedText(step: failed.name, message: message)
                : "DB setup failed at \(failed.name): \(message)")
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
        } else if run.reason != nil, notices.notice(.dbSetup) == nil {
            // The run ended with no failed step: it was cancelled between two steps.
            postNotice(.dbSetup, Self.dbResetCancelledMessage)
        }
        // A step asked for services to restart (`##db:restart:`): Sequin reads a
        // slot that the reset dropped. Only after the run passed, and not after a cancel.
        if ok, let pipeline = run.pipeline {
            let cancelled: Bool
            if let runner = run.runner { cancelled = await runner.wasCancelled } else { cancelled = false }
            if !cancelled { await restartAfterReset(pipeline.steps.flatMap(\.restartRequests)) }
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

    /// Restarts the services that the steps asked for, in order: each one is ready,
    /// or its oneshot is done, before the next. A service that is not in the profile
    /// or does not run is left alone. A failed restart is a failure of that service;
    /// the DB setup stays passed (`scripts/db/README.md`, "After a reset").
    func restartAfterReset(_ requests: [DbRestartRequest]) async {
        var seen: Set<String> = []
        for request in requests {
            for serviceID in request.serviceIDs where seen.insert(serviceID).inserted {
                guard let state = serviceStates[serviceID] else {
                    await logStore.append(serviceID: LogFileSink.runnerLogID, entry: LogEntry(
                        stream: .stderr, text: Self.unknownRestartLine(serviceID)
                    ))
                    continue
                }
                guard !isShuttingDown, isInProfile(serviceID),
                      state.phase == .running || state.phase == .completed else { continue }
                let name = displayName(serviceID)
                await logStore.append(serviceID: serviceID, entry: LogEntry(
                    stream: .stdout, text: Self.restartAfterResetLine(name, reason: request.reason)
                ))
                beginAction(serviceID)
                do {
                    let outcome = try await replaceProcess(serviceID)
                    if let why = notRestarted(serviceID, outcome) {
                        postNotice(.service(serviceID), "\(name) did not restart after the database reset: \(why)")
                    }
                } catch {
                    recordFailure(serviceID, error: error, lastError: "\(name) did not restart after the database reset: \(error)")
                }
                endAction(serviceID)
            }
        }
        if !seen.isEmpty { recalculateHealth() }
    }

    nonisolated static func restartAfterResetLine(_ name: String, reason: String) -> String {
        let why = reason.isEmpty ? "The database reset changed what it reads" : reason
        return "[travel-runner] \(why) — restarting \(name)"
    }

    nonisolated static func unknownRestartLine(_ serviceID: String) -> String {
        "[travel-runner] The database setup asked to restart '\(serviceID)', which is not a service here — skipped"
    }

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
        guard !dbResetRunning, dbSetupPipeline?.isRunning != true else {
            showFeedback(ActionFeedback.dbSetupRunning, .info)
            return
        }
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
        queueDbSetup { [self] in
            beginDbSetup(
                cwd: supabaseCwd, profile: "reset", reason: nil, origin: .singleStep, from: HotelCatalog.fetchStepID,
                singleStep: true, reusePipeline: false, stepArguments: HotelCatalog.forceArgument
            )
        }
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
    @discardableResult
    func runDbSetupStep(_ stepId: String) -> DbSetupQueueOutcome {
        queueDbSetup { [self] in
            beginDbSetup(
                cwd: supabaseCwd, profile: singleStepProfile(stepId), reason: nil, origin: .singleStep, from: stepId,
                singleStep: true
            )
        }
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
            reuseIfRunning: definition.reuseIfRunning,
            stopCmd: definition.stopCmd,
            stopGraceSeconds: definition.stopGraceSeconds,
            stopNote: definition.stopNote
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

    /// The host that the web servers bind in LAN mode. All addresses: the LAN
    /// address for the phone, and loopback for the probes and the Stripe CLI. A
    /// new LAN address does not break the bind.
    nonisolated static let lanBindHost = "0.0.0.0"

    /// The service's own command with `--hostname 0.0.0.0` appended, so LAN mode keeps
    /// the configured package manager and port. `npm run` needs `--` before script flags;
    /// pnpm passes trailing flags to the script.
    nonisolated static func lanCommand(_ cmd: [String]) -> [String] {
        let needsSeparator = cmd.first == "npm" && cmd.dropFirst().first == "run" && !cmd.contains("--")
        return cmd + (needsSeparator ? ["--"] : []) + ["--hostname", lanBindHost]
    }

    private func lanAwareDefinition(for definition: ServiceDefinition, serviceID: String) -> ServiceDefinition {
        guard networkMode, let ip = localIP else { return definition }
        let lanServices: Set<String> = ["travel-portal", "universal-login", "partner-portal"]
        guard lanServices.contains(serviceID) else { return definition }

        let cmd = Self.lanCommand(definition.cmd)
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

        // The server listens on all addresses, so the loopback probe keeps working.
        return ServiceDefinition(
            id: definition.id,
            name: definition.name,
            cmd: cmd,
            cwd: definition.cwd,
            probe: definition.probe,
            type: definition.type,
            restart: definition.restart,
            dependsOn: definition.dependsOn,
            env: envOverrides,
            phase: definition.phase,
            reuseIfRunning: definition.reuseIfRunning,
            stopCmd: definition.stopCmd,
            stopGraceSeconds: definition.stopGraceSeconds,
            stopNote: definition.stopNote
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

    /// What a start of one service did. Start All and the toasts follow it.
    private enum StartOutcome {
        /// A new process runs; `awaitReady` waits for it.
        case launched(ServiceLaunch)
        /// The port of a container-managed service answered: it runs on.
        case reused
        /// "Retry failed": the service runs, and stays as it is.
        case alreadyHealthy
        /// The service is off; the text says why.
        case skipped(String)
        /// A dependency is not up. The service waits and starts when it is.
        case blocked(by: String)
        /// Nothing may start now; the text says why.
        case refused(String)
    }

    /// Whether the dependencies of a service let it start.
    private enum DependencyGate: Equatable {
        case met
        /// A dependency is off for good (an optional service that is skipped).
        case unavailable(String)
        /// A dependency is not up yet, or failed.
        case blocked(String)
    }

    /// A dependency is met when it runs, is done, or is not in the profile. Of the
    /// ones that are not up, a failed one comes first, then one that waits: the row
    /// names the cause, not a service that still starts. An edge that only sets the
    /// order is met once its dependency ended, however it ended.
    private func dependencyGate(_ serviceID: String) -> DependencyGate {
        let orderingOnly = ServiceCatalog.orderingOnlyDependencies[serviceID] ?? []
        var blocked: (id: String, rank: Int)?
        for dependency in graph?.nodes[serviceID]?.dependsOn ?? [] {
            guard isInProfile(dependency), let state = serviceStates[dependency] else { continue }
            if orderingOnly.contains(dependency), [.skipped, .failed].contains(state.phase) { continue }
            let rank: Int
            switch state.phase {
            case .running, .completed: continue
            case .skipped:
                if state.condition?.kind == .notInProfile { continue }
                return .unavailable(dependency)
            case .failed: rank = 0
            case .waiting: rank = 1
            default: rank = 2
            }
            if blocked == nil || rank < blocked!.rank { blocked = (dependency, rank) }
        }
        return blocked.map { .blocked($0.id) } ?? .met
    }

    /// The service that a wait for `dependency` comes down to: when the dependency
    /// waits too, the one it waits for, and so on to the root (a failed one, say).
    private func waitTarget(_ dependency: String) -> String {
        var current = dependency
        var seen: Set<String> = [dependency]
        while let state = serviceStates[current], state.phase == .waiting,
              case .waitingForDependency(let next)? = state.condition?.kind, seen.insert(next).inserted {
            current = next
        }
        return current
    }

    /// "Supabase (failed)": a dependency and its phase, for the row and the toast.
    private func dependencyState(of dependency: String) -> String {
        let phase = serviceStates[dependency]?.phase.rawValue.lowercased() ?? "missing"
        return "\(displayName(dependency)) (\(phase))"
    }

    /// The row of a waiting service names the phase of its dependency as it is now.
    private func refreshWaitingConditions() {
        for state in serviceStates.values where state.phase == .waiting {
            guard case .waitingForDependency(let dependency)? = state.condition?.kind else { continue }
            let headline = "Waiting for \(dependencyState(of: waitTarget(dependency)))"
            guard state.condition?.headline != headline else { continue }
            state.condition = ServiceCondition(
                kind: .waitingForDependency(dependency), headline: headline, since: state.condition?.since ?? clock.date()
            )
        }
    }

    /// A service is up: the services that waited for it start, in start order.
    private func startBlockedDependents(of serviceID: String) {
        guard !isShuttingDown, health != .stopped, let graph else { return }
        let ready = sortedServiceIDs.filter { id in
            serviceStates[id]?.phase == .waiting
                && graph.nodes[id]?.dependsOn.contains(serviceID) == true
                && dependencyGate(id) == .met
        }
        guard !ready.isEmpty else { return }
        let line = "[travel-runner] \(displayName(serviceID)) is up — starting \(ready.map(displayName).joined(separator: ", "))"
        Task { await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stdout, text: line)) }
        for id in ready {
            // No longer waiting: a second call does not start it again. Starting, not
            // pending: a health check meanwhile must not read a stopped stack.
            serviceStates[id]?.phase = .starting
            Task {
                beginAction(id)
                defer { endAction(id) }
                do {
                    _ = try await startService(id)
                } catch {
                    recordFailure(id, error: error, lastError: ownsBanner(id) ? "\(error)" : nil)
                }
                recalculateHealth()
            }
        }
    }

    /// Starts one service and waits until it is ready.
    @discardableResult
    private func startService(_ serviceID: String, mode: StartMode = .everything) async throws -> StartOutcome {
        let outcome = try await lifecycle.withLock(serviceID) { try await spawnService(serviceID, mode: mode) }
        if case .launched(let launch) = outcome { try await awaitReady(serviceID, launch) }
        return outcome
    }

    /// Starts the service's process. The caller holds the service's lock. Only
    /// `.launched` has a process to wait for.
    private func spawnService(_ serviceID: String, mode: StartMode = .everything) async throws -> StartOutcome {
        guard let state = serviceStates[serviceID],
              let definition = graph?.nodes[serviceID] else { return .refused("\(serviceID) is not in the config") }

        guard !isShuttingDown, health != .stopped else {
            // Stop-all won. Do not leave the service marked as on its way up.
            if state.phase == .starting || state.phase == .pending { state.phase = .stopped }
            return .refused(Self.stackStoppedRefusal)
        }

        if mode == .missingOnly, await isUp(serviceID) { return .alreadyHealthy }

        // Services outside the active profile are skipped. The verification
        // oneshots drive the local CDC evidence chain against the dev fixture, so
        // they run only in the full profile.
        if !isInProfile(serviceID) {
            state.phase = .skipped
            noteSkip(state, .notInProfile, "Not in the \(profile.displayName) profile.")
            return .skipped("not in the \(profile.displayName) profile")
        }

        // A service of an optional repo that is not there is skipped. The portals and
        // the rest of the stack start.
        if let reason = ServiceCatalog.missingOptionalRepo(definition) {
            await skipOptional(state, reason, actions: [.openSettingsPaths])
            return .skipped(reason)
        }

        // A dependency that failed, or is not up yet, holds the service back. It
        // starts when the dependency is up (`startBlockedDependents`).
        switch dependencyGate(serviceID) {
        case .met:
            break
        case .unavailable(let dependency):
            // The row names the reason of the dependency; a start of this one would skip again.
            let (detail, actions) = dependencySkipReason(dependency)
            await skipOptional(state, "Skipped: \(displayName(dependency)) is not available.", detail: detail, actions: actions)
            return .skipped("\(displayName(dependency)) is not available")
        case .blocked(let dependency):
            state.phase = .waiting
            let target = dependencyState(of: waitTarget(dependency))
            noteSkip(state, .waitingForDependency(dependency), "Waiting for \(target)")
            await logStore.append(serviceID: serviceID, entry: LogEntry(
                stream: .stdout, text: "[travel-runner] Waiting for \(target) before the start"
            ))
            return .blocked(by: dependency)
        }

        // QStash runs the CLI of the booking app's packages. Without it, QStash is
        // skipped before the port is freed: a skip leaves other processes alone. When
        // the packages are missing, the install below runs first.
        if serviceID == ServiceCatalog.qstashID, let cwd = definition.resolvedCwd, !Self.qstashCLIExists(cwd),
           await dependencyState(serviceID) != .missing {
            await skipOptional(state, ServiceCatalog.qstashMissing, actions: [.installDependencies])
            return .skipped(ServiceCatalog.qstashMissing)
        }

        // The install of the stream services runs only when their packages changed.
        if serviceID == ServiceCatalog.streamInstallID, let cwd = definition.resolvedCwd,
           await streamPackagesAreCurrent(cwd) {
            state.phase = .completed
            state.clearCondition()
            state.lastStarted = clock.date()
            state.readyAt = clock.date()
            state.exitCode = 0
            await logStore.append(serviceID: serviceID, entry: LogEntry(
                stream: .stdout, text: "[travel-runner] Stream Services packages are current — npm install skipped."
            ))
            startBlockedDependents(of: serviceID)
            return .reused
        }

        // A probe with a missing or wrong field: say so, and start nothing.
        if let problem = definition.probe?.problem {
            throw ServiceError.badProbe(name: definition.displayName, reason: problem)
        }

        // An unset folder is "". A process there would run in the app's own folder.
        if definition.resolvedCwd == "" {
            throw ServiceError.folderUnset(name: definition.displayName)
        }

        // Reuse-if-running: Docker-managed services (Supabase) persist between sessions.
        // If the port is already bound, skip starting and mark as running.
        if definition.shouldReuseIfRunning, let port = definition.probe?.port {
            var reuses = isPortBound(port)
            // The database port alone is not a working stack. Only the monorepo's own
            // healthy stack is reused. Another checkout's stack (the old
            // travel-booking-portal one, say) on the same port is a different DB.
            if reuses, serviceID == "supabase", let root = definition.resolvedCwd {
                switch await supabaseStackHealth(root: root, dbPort: port) {
                case .healthy:
                    break
                case .down:
                    reuses = false
                case .foreign(let occupant):
                    throw await otherStackHoldsPort(port, occupant: occupant, root: root)
                case .partial(let missing):
                    // db:start keeps a stack whose database runs as it is, so the
                    // repair stops the stack first. One repair for each start: a stack
                    // that stays partly up fails with the reason.
                    guard !supabaseRepairUsed else {
                        throw ServiceError.supabasePartlyUp(missing: missing)
                    }
                    supabaseRepairUsed = true
                    await logStore.append(serviceID: serviceID, entry: LogEntry(
                        stream: .stderr, text: SupabaseStackHealth.partialRepairLine(missing)
                    ))
                    state.phase = .starting
                    await stopSupabaseStack(definition)
                    reuses = false
                }
            }
            if reuses {
                state.phase = .running
                state.clearCondition()
                state.progressNote = nil
                notices.resolve(.service(serviceID))
                state.lastStarted = clock.date()
                state.readyAt = clock.date()
                startBlockedDependents(of: serviceID)
                return .reused
            }
        }

        // Skip Stripe if the CLI isn't installed or cannot call Stripe. It uses the
        // test key of the booking portal, or the login without one.
        var stripeKey: StripeKeyResolution?
        if serviceID == "stripe" {
            let resolution = stripeResolution()
            stripeKey = resolution
            stripeMode = resolution.mode
            state.modeNote = resolution.mode.rowText
            await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stdout, text: resolution.mode.logLine))
            let availability = await stripeAvailability(resolution)
            if let reason = StripeOffReason.unavailable(availability, mode: resolution.mode) {
                state.pid = nil
                await stripeOff(state, reason, cause: reason.headline)
                return .skipped(reason.headline)
            }
        }

        // The agent needs its packages and Node 24 or later. Without them it is
        // skipped, as Stripe is: the portals do not need the agent.
        var agentLaunch: AgentLauncher.Launch?
        if serviceID == ServiceCatalog.agentID {
            switch await prepareAgent(definition) {
            case .skip(let reason):
                state.phase = .skipped
                noteSkip(state, .optionalOff, "The agent is skipped.", detail: reason, actions: [.startService])
                await logStore.append(
                    serviceID: serviceID,
                    entry: LogEntry(stream: .stderr, text: "[travel-runner] The agent is skipped. \(reason)")
                )
                return .skipped(reason)
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
                noteSkip(state, .optionalOff, "Platform core is skipped.", detail: reason, actions: [.startService])
                await logStore.append(
                    serviceID: serviceID,
                    entry: LogEntry(stream: .stderr, text: "[travel-runner] Platform core is skipped. \(reason)")
                )
                return .skipped(reason)
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
                noteSkip(state, .optionalOff, "The event directory is skipped.", detail: reason, actions: [.startService])
                await logStore.append(
                    serviceID: serviceID,
                    entry: LogEntry(stream: .stderr, text: "[travel-runner] The event directory is skipped. \(reason)")
                )
                return .skipped(reason)
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

            // A stale process of the runner on the port is stopped. A process that
            // the runner did not start is not: the row asks first.
            if let port = definition.probe?.port, definition.resolvedType == .daemon, isPortBound(port) {
                if let foreign = await portOccupants(port).first(where: { $0.owner == .foreign }) {
                    throw ServiceError.portHeldByProcess(name: definition.displayName, port: port, occupant: foreign)
                }
                await freePort(port)
                // A container still has the port: the service would fail with
                // EADDRINUSE while its TCP probe passes against the container.
                if isPortBound(port),
                   let owner = await portOccupants(port).first(where: { $0.owner == .containerRuntime }) {
                    throw ServiceError.portHeldByContainer(
                        name: definition.displayName, port: port, owner: owner.listener.command
                    )
                }
            }
            try await checkOtherNextDev(definition)
        }

        // A Node service without its packages cannot run: install them first, in its
        // log. A stale install only gets the button of its row (decision 11).
        if await dependencyState(serviceID) == .missing, let cwd = definition.resolvedCwd {
            let command = DependencyWatcher.installTarget(for: cwd).command
            state.phase = .starting
            state.lastStarted = clock.date()
            let result = await installPackages(
                serviceID, cwd: cwd, announce: "[travel-runner] packages are not installed — running \(command)"
            )
            // Nil: a stop-all cancelled the install. A start after it has its own run.
            guard let result else {
                if state.phase == .starting || state.phase == .pending { state.phase = .stopped }
                return .refused(Self.stackStoppedRefusal)
            }
            guard result.succeeded else {
                throw ServiceError.installFailed(
                    name: definition.displayName, command: command,
                    why: Self.installFailure(result, folder: DependencyWatcher.installTarget(for: cwd).folder)
                )
            }
        }

        // The install did not bring the QStash CLI: QStash is skipped.
        if serviceID == ServiceCatalog.qstashID, let cwd = definition.resolvedCwd, !Self.qstashCLIExists(cwd) {
            await skipOptional(state, ServiceCatalog.qstashMissing, actions: [.installDependencies])
            return .skipped(ServiceCatalog.qstashMissing)
        }

        // The verification services fail without their seed: their log says which one.
        if let hint = verificationSeedHint(serviceID) {
            await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stdout, text: "[travel-runner] \(hint)"))
        }

        // A start during a read of the shell waits for the new PATH. The wait is
        // here, before the last check for a stop: the process runner must not
        // wait, or a stop-all in that time sees no process and the start runs one.
        await tools.settled()

        // The waits above can outlast a stop-all.
        guard !isShuttingDown, health != .stopped else {
            if state.phase == .starting || state.phase == .pending { state.phase = .stopped }
            return .refused(Self.stackStoppedRefusal)
        }

        state.phase = .starting
        state.clearCondition()
        state.progressNote = nil
        state.lastProbe = nil
        state.lastStarted = clock.date()
        state.readyAt = nil
        state.exitCode = nil
        // No pid until the new process has one: handleTermination compares it.
        state.pid = nil

        // The portal does not wait for Stripe. Without a secret it says why
        // payments will not confirm; a secret that comes later restarts it.
        if serviceID == "travel-portal" {
            warnedNoWebhookSecret = false
            await warnIfNoWebhookSecret()
        }

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
        let eventDefinition = EventDirectoryLauncher.definition(agentDefinition, env: eventDirectoryEnv)
        // The key goes to the process env only: the command and the state keep no copy.
        let effectiveDefinition = stripeKey.map { StripeLauncher.definition(eventDefinition, resolution: $0) } ?? eventDefinition

        let sid = serviceID
        // A cold start of Supabase pulls images for minutes: the row shows its output.
        let showsProgress = serviceID == "supabase" && definition.shouldReuseIfRunning
        let pid = try await processRunner.start(
            service: effectiveDefinition,
            onStdout: { [weak self] lines in
                if showsProgress { Task { @MainActor in self?.noteStartProgress(sid, lines) } }
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
                }
            },
            onStderr: { [weak self] lines in
                if showsProgress { Task { @MainActor in self?.noteStartProgress(sid, lines) } }
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
            onTermination: { [weak self, ledger = self.ledger] termination in
                let ended = ledger.entries.first { $0.pid == termination.pid }
                ledger.remove(pids: [termination.pid])
                Task { @MainActor in
                    if let ended { self?.noteEndedLaunch(ended) }
                    self?.handleTermination(serviceID: sid, termination: termination)
                }
            }
        )

        recordLaunch(sid, pid: pid, definition: definition)
        state.pid = pid
        await logStore.markStart(serviceID: sid, name: definition.displayName, pid: pid)
        return .launched(ServiceLaunch(
            pid: pid, definition: effectiveDefinition, stdoutProbe: capturedProbe, artifactName: artifactName
        ))
    }

    /// Waits until the process that `spawnService` started is ready, then marks the
    /// service as running. It holds no lock.
    private func awaitReady(_ serviceID: String, _ launch: ServiceLaunch) async throws {
        guard let state = serviceStates[serviceID] else { return }

        // Oneshots: wait for exit, up to the deadline
        if launch.definition.resolvedType == .oneshot {
            let deadline = clock.uptime() + oneshotDeadline
            while true {
                if state.phase == .completed {
                    startBlockedDependents(of: serviceID)
                    return
                }
                if state.phase == .failed {
                    throw ServiceError.oneshotFailed(name: state.definition.displayName)
                }
                // Stopped before it finished: stop-all, or a new run replaced this one.
                if isShuttingDown || state.phase == .stopping || state.phase == .stopped { return }
                if let exit = await processRunner.exit(of: launch.pid), exit.stoppedByRunner { return }
                // It throws when it stopped the run. A run that ended at this
                // moment gets its phase from handleTermination.
                if clock.uptime() >= deadline { try await stopOverdueOneshot(serviceID, launch) }
                try await clock.sleep(for: .milliseconds(250))
            }
        }

        // Daemons: wait for the probe (the launch's definition has the LAN-aware host).
        // The probe timeout is a soft limit: a process that still runs keeps its
        // start, and the row says so. At the hard cap the process is stopped.
        if let probeConfig = launch.definition.probe {
            let probe: Probe = if let sp = launch.stdoutProbe { sp } else { try ProbeFactory.makeProbe(for: probeConfig) }
            let began = clock.uptime()
            let softDeadline = began + probeConfig.resolvedTimeout
            defer { if slowStartDeadlines[serviceID]?.pid == launch.pid { slowStartDeadlines[serviceID] = nil } }
            var slowSince: Date?
            while true {
                let outcome = await probe.outcome()
                // The newest process of the service owns the field.
                if state.pid == launch.pid, state.lastProbe != outcome { state.lastProbe = outcome }
                if outcome.isReady {
                    // The database port of Supabase opens before the rest of its stack answers.
                    guard let waiting = try await supabaseStackNotReady(serviceID, launch) else { break }
                    if state.pid == launch.pid { state.lastProbe = .other(waiting) }
                }
                if let exit = await processRunner.exit(of: launch.pid) {
                    // The automatic restart gives the verdict, not this waiter.
                    if isReplaced(serviceID, launch) { return }
                    if try await !shouldKeepWaiting(for: state, after: exit) { return }
                    if isReplaced(serviceID, launch) { return }
                }
                let now = clock.uptime()
                if slowSince == nil, now >= softDeadline {
                    // A newer process of the service runs, or its restart is due: its own
                    // waiter says whether it started. This one marks nothing failed.
                    if isReplaced(serviceID, launch) { return }
                    if serviceID == "stripe" {
                        // Stripe is optional: a slow `stripe listen` turns it off, not red.
                        await stripeDidNotConnect(state, launch: launch, seconds: probeConfig.timeout ?? 120)
                        return
                    }
                    try await passSoftLimit(serviceID, launch, seconds: probeConfig.timeout ?? 120)
                    slowStartDeadlines[serviceID] = (launch.pid, began + max(startHardCap, probeConfig.resolvedTimeout))
                    slowSince = clock.date()
                }
                if let since = slowSince {
                    if isReplaced(serviceID, launch) { return }
                    if let cap = slowStartDeadlines[serviceID], cap.pid == launch.pid, now >= cap.deadline {
                        try await stopSlowStart(serviceID, launch, limit: cap.deadline - began)
                        return
                    }
                    if state.phase == .starting {
                        state.condition = ServiceCondition(
                            kind: .slowStart,
                            headline: HealthMonitor.slowStartHeadline(
                                name: state.definition.displayName, elapsed: now - began,
                                lastProbe: state.lastProbe, port: probeConfig.port
                            ),
                            actions: [.keepWaiting, .restart], since: since
                        )
                    }
                }
                try await clock.sleep(for: .seconds(2))
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
        state.clearCondition()
        state.progressNote = nil
        notices.resolve(.service(state.id))
        if state.readyAt == nil { state.readyAt = clock.date() }
        startBlockedDependents(of: serviceID)
    }

    /// The start of a daemon passed the probe timeout of its service. It files the
    /// issue of a startup probe timeout. A process that still runs keeps its start;
    /// one that ended throws.
    private func passSoftLimit(_ serviceID: String, _ launch: ServiceLaunch, seconds: Int) async throws {
        guard let state = serviceStates[serviceID] else { return }
        // An automatic restart can replace this launch's process during the wait,
        // so the answer comes from the service's current process.
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
        guard alive == "yes" else {
            throw ServiceError.probeTimeout(name: name, seconds: seconds, processAlive: false, lastProbe: state.lastProbe)
        }
        await logStore.append(serviceID: serviceID, entry: LogEntry(
            stream: .stdout,
            text: "[travel-runner] \(name) did not answer in \(seconds)s but still runs — waiting up to "
                + "\(Self.durationText(startHardCap)) in all"
        ))
    }

    /// A start that reached its hard cap: stop the process, say so in its log, and
    /// fail it. Returns without an error when a new run replaced it, or a stop won.
    private func stopSlowStart(_ serviceID: String, _ launch: ServiceLaunch, limit: Duration) async throws {
        let error = ServiceError.startTimedOut(name: displayName(serviceID), limit: limit)
        await lifecycle.withLock(serviceID) {
            guard serviceStates[serviceID]?.pid == launch.pid,
                  await processRunner.exit(of: launch.pid) == nil else { return }
            await processRunner.stop(serviceID: serviceID)
        }
        guard let state = serviceStates[serviceID], state.pid == launch.pid, !isShuttingDown,
              state.phase != .stopping, state.phase != .stopped else { return }
        state.phase = .failed
        await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stderr, text: "[travel-runner] \(error)"))
        throw error
    }

    /// "Keep waiting": the start that passed its soft limit gets the hard cap again, from now.
    func keepWaiting(_ serviceID: String) {
        guard let state = serviceStates[serviceID], state.phase == .starting,
              let cap = slowStartDeadlines[serviceID] else { return }
        slowStartDeadlines[serviceID] = (cap.pid, clock.uptime() + startHardCap)
        let text = "Waiting up to \(Self.durationText(startHardCap)) more for \(state.definition.displayName)"
        Task { await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stdout, text: "[travel-runner] \(text)")) }
        onActionFeedback?(text, true)
    }

    /// True when the process of `launch` is no longer the one of the service: a
    /// newer process runs, or an automatic restart is due.
    private func isReplaced(_ serviceID: String, _ launch: ServiceLaunch) -> Bool {
        if pendingRestarts[serviceID] != nil { return true }
        guard let pid = serviceStates[serviceID]?.pid else { return false }
        return pid != launch.pid
    }

    /// "15 min", or "90 s" for a deadline that is not whole minutes.
    nonisolated static func durationText(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        return seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }

    /// A oneshot that ran past its deadline: stop it, say so in its log, and fail it.
    /// Returns without an error when the run ended by itself, or a new run replaced it.
    private func stopOverdueOneshot(_ serviceID: String, _ launch: ServiceLaunch) async throws {
        let error = ServiceError.oneshotTimedOut(
            name: displayName(serviceID), limit: Self.durationText(oneshotDeadline)
        )
        await lifecycle.withLock(serviceID) {
            // A new run replaced this one, or it ended at this moment.
            guard serviceStates[serviceID]?.pid == launch.pid,
                  await processRunner.exit(of: launch.pid) == nil else { return }
            await processRunner.stop(serviceID: serviceID)
        }
        guard serviceStates[serviceID]?.pid == launch.pid, serviceStates[serviceID]?.phase != .completed,
              !isShuttingDown else { return }
        serviceStates[serviceID]?.phase = .failed
        await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stderr, text: "[travel-runner] \(error)"))
        throw error
    }

    /// The process of a launch ended before its probe passed. Returns true to keep
    /// waiting and false to stop without an error. Throws when the start failed.
    private func shouldKeepWaiting(for state: ServiceState, after exit: ProcessRunner.Termination) async throws -> Bool {
        // Each exit of Stripe is for handleTermination: it retries, or turns Stripe off.
        if state.id == "stripe" { return false }
        switch ServiceTermination.classify(exit) {
        case .stoppedByRunner:
            // Stop-all, or another operation replaced this process and owns the state.
            return false
        case .cleanExit:
            // The launcher of a container-managed service ends while the stack still starts.
            if state.definition.shouldReuseIfRunning { return true }
            if isShuttingDown || state.phase == .stopping || state.phase == .stopped { return false }
            // The daemon gets one automatic restart, and that restart gives the verdict.
            if state.definition.resolvedRestart == .onFailure, !state.cleanExitRestarted { return true }
            throw ServiceError.exitedDuringStartup(name: state.definition.displayName)
        case .commandNotRunnable(let code):
            let finding = await commandFinding(forExit: code, pid: exit.pid, of: state)
            // The question takes time. A stop, or a newer launch, owns the state now.
            if isShuttingDown || state.phase == .stopping || state.phase == .stopped { return false }
            if let current = state.pid, current != exit.pid { return false }
            throw ServiceError.commandNotRunnable(name: state.definition.displayName, finding: finding)
        case .killedExternally, .crashed:
            // A stop-all or another operation took over after the failure.
            if isShuttingDown || health == .stopped || state.phase == .stopped { return false }
            if state.isCircuitBroken {
                // The reason is in its notice: a crash loop, or a container runtime that is down.
                throw ServiceError.autoRestartStopped(
                    notices.text(.service(state.id))
                        ?? "\(state.definition.displayName) keeps failing — auto-restart stopped; see its log"
                )
            }
            // The supervisor restarts a failed daemon, and the new process can pass this probe.
            if state.definition.resolvedRestart == .onFailure { return true }
            throw ServiceError.exitedDuringStartup(name: state.definition.displayName)
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

    /// What exit 126 or 127 of this launch means: the tool, the packages, the
    /// script or the file that is missing.
    private func commandFinding(
        forExit code: Int32, pid: Int32, of state: ServiceState
    ) async -> CommandDiagnosis.Finding {
        let definition = state.definition
        let tool = await missingTool(forExit: code, pid: pid, of: definition)
        // The log keeps the lines of earlier launches; they are not the cause of this one.
        let launched = state.lastStarted ?? .distantPast
        let tail = await logStore.entries(for: definition.id)
            .filter { $0.timestamp >= launched }
            .suffix(FailureAdvisor.logWindow).map(\.text)
        return CommandDiagnosis.diagnose(
            code: code, command: definition.cmd, cwd: definition.resolvedCwd, logTail: Array(tail), tool: tool
        )
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

        // Stripe is optional: an exit never makes the stack red. Its cause decides
        // between a retry and off (see `handleStripeExit`).
        if serviceID == "stripe" {
            handleStripeExit(state, termination)
            return
        }

        if state.definition.resolvedType == .oneshot {
            state.phase = kind == .cleanExit ? .completed : .failed
            state.exitCode = termination.status
            if kind == .cleanExit { state.clearCondition() }
            return
        }

        state.exitCode = termination.status
        // Time in the ready state. A service that never became ready has none, so a
        // slow failure (two minutes to give up) does not start a new series each time.
        let stableFor = state.readyAt.map { clock.date().timeIntervalSince($0) }
        let restarts = state.definition.resolvedRestart == .onFailure
        // While Start All runs, the first failure keeps the banner.
        let owns = ownsBanner(serviceID)

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
            // One automatic restart for each series: a daemon can end once by itself
            // (a watcher that reloads). A second clean exit fails it.
            if AutoRestart.startsNewSeries(uptime: stableFor) { state.cleanExitRestarted = false }
            if restarts, !state.cleanExitRestarted {
                state.cleanExitRestarted = true
                state.phase = .failed
                state.lastStopped = clock.date()
                noteSkip(state, .retrying, "\(name) exited (code 0) — restarting it once.")
                Task { await logStore.append(serviceID: serviceID, entry: LogEntry(
                    stream: .stderr, text: "[travel-runner] \(name) exited (code 0) — restarting it once"
                ))}
                scheduleRestart(serviceID: serviceID)
                recalculateHealth()
                return
            }
            // The daemon ended by itself and nothing starts it again. "Failed" makes
            // the environment degraded; "stopped" left it at "starting" with no end.
            // It is not a crash: no notification and no debug issue.
            state.phase = .failed
            state.lastStopped = clock.date()
            // The header shows the notice only with a text: say which service ended.
            postNotice(.service(serviceID), Self.cleanExitMessage(name), first: owns)
            recordFailure(serviceID, kind: .cleanExit, ownsBanner: owns)
            Task { await logStore.append(serviceID: serviceID, entry: LogEntry(
                stream: .stderr, text: "[travel-runner] \(name) exited (code 0) — not restarted"
            ))}

        case .killedExternally(let signal):
            // Someone stopped it from outside: `kill`, a script that frees the port.
            // The service did not fail, so there is no crash notification and no
            // debug issue. It still counts toward the circuit breaker: three kills
            // in a minute mean that something else keeps stopping it.
            state.phase = .failed
            state.lastStopped = clock.date()
            noteFailure(state, stableFor: stableFor)
            state.killTimestamps.append(clock.date())
            state.lastKillSignal = signal
            recordFailure(serviceID, kind: .killed(signal: signal), ownsBanner: owns)
            // SIGKILL (exit 137) is how macOS ends a process when memory runs low.
            // It gets one notification in each series.
            let notifiesKill = signal == SIGKILL && !state.memoryNotified
            if notifiesKill { state.memoryNotified = true }
            let action = restarts ? "restarting it" : "it stays stopped"
            let killed = "\(name) was stopped from outside \(Flavor.current.displayName) (\(ServiceTermination.signalName(signal))) — \(action)"
            let hint = ServiceTermination.killHint(signal)
            Task {
                await logStore.append(serviceID: serviceID, entry: LogEntry(
                    stream: .stderr, text: "[travel-runner] \(killed)"
                ))
                if let hint {
                    await logStore.append(serviceID: serviceID, entry: LogEntry(
                        stream: .stderr, text: "[travel-runner] \(hint)"
                    ))
                }
                await recordDebugEvent(kind: "outside_kill", serviceID: serviceID, message: killed)
            }
            if restarts {
                scheduleRestart(serviceID: serviceID)
            }
            // After the schedule: the notification says whether a restart comes.
            if notifiesKill {
                let next: CrashAlert.Next = state.isCircuitBroken ? .autoRestartStopped
                    : restarts && state.phase == .failed ? .restarting(attempt: state.restartCount + 1) : .none
                alertCrash(state, code: 128 + SIGKILL, next: next)
            }

        case .commandNotRunnable(let code):
            // Exit 126/127: the shell could not run the command. The same command
            // fails again, so there is no automatic restart.
            state.phase = .failed
            state.lastStopped = clock.date()
            let unknown = CommandDiagnosis.Finding.unknown(command: state.definition.cmd.first ?? "its command", code: code)
            let plain = CommandDiagnosis.message(unknown, name: name)
            postNotice(.service(serviceID), plain, first: owns)
            recordFailure(serviceID, kind: .cannotRun(unknown), ownsBanner: owns)
            let record = state.failureRecordCount
            Task {
                let finding = await commandFinding(forExit: code, pid: termination.pid, of: state)
                alertCrash(state, code: code, next: .none, cause: CommandDiagnosis.message(finding, name: name))
                guard finding != unknown else { return }
                let full = CommandDiagnosis.message(finding, name: name)
                await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stderr, text: "[travel-runner] \(full)"))
                // A newer error stays.
                if notices.text(.service(serviceID)) == plain { postNotice(.service(serviceID), full, first: owns) }
                if state.failureRecordCount == record, state.phase == .failed {
                    recordFailure(serviceID, kind: .cannotRun(finding), ownsBanner: owns)
                }
            }
            Task { await captureDebugIssue(
                trigger: "service_crash",
                serviceID: serviceID,
                summary: "\(name) \(ServiceTermination.describe(termination))"
            )}

        case .crashed:
            state.phase = .failed
            state.lastStopped = clock.date()
            noteFailure(state, stableFor: stableFor)
            let alerts = !state.isCircuitBroken
            if alerts {
                Task { await captureDebugIssue(
                    trigger: "service_crash",
                    serviceID: serviceID,
                    summary: "\(name) \(ServiceTermination.describe(termination))"
                )}
            }
            if restarts {
                scheduleRestart(serviceID: serviceID)
            }
            // After the schedule: the notification says whether a restart comes.
            if alerts {
                let next: CrashAlert.Next = state.isCircuitBroken ? .autoRestartStopped
                    : restarts && state.phase == .failed ? .restarting(attempt: state.restartCount + 1) : .none
                alertCrash(state, code: termination.status, next: next)
            }
            // A tripped breaker recorded its own reason.
            if state.phase == .failed, !state.isCircuitBroken {
                recordFailure(serviceID, kind: .exited(code: termination.status), ownsBanner: owns)
            }
        }
        recalculateHealth()
    }

    /// Records one failure of a daemon. A service that ran for a while before it
    /// failed starts a new series: the restart count, the backoff and the memory
    /// notification start again.
    private func noteFailure(_ state: ServiceState, stableFor: TimeInterval?, countsTowardBreaker: Bool = true) {
        if AutoRestart.startsNewSeries(uptime: stableFor) {
            state.restartCount = 0
            state.memoryNotified = false
        }
        if countsTowardBreaker {
            state.failureTimestamps.append(clock.date())
        }
    }

    private func scheduleRestart(serviceID: String) {
        guard let state = serviceStates[serviceID] else { return }
        let name = state.definition.displayName

        state.failureTimestamps = AutoRestart.recentFailures(state.failureTimestamps, now: clock.date())
        state.killTimestamps = AutoRestart.recentFailures(state.killTimestamps, now: clock.date())
        let baseDelay: TimeInterval
        switch AutoRestart.decide(
            recentFailureCount: state.failureTimestamps.count, restartCount: state.restartCount,
            recentKillCount: state.killTimestamps.count
        ) {
        case .crashLoop:
            state.haltReason = .crashLoop
            let tripped = "\(name) failed \(AutoRestart.failuresToTrip) times in a minute — auto-restart stopped"
            postNotice(.service(serviceID), tripped)
            recordFailure(serviceID, kind: .crashLoop)
            Task { await recordDebugEvent(kind: "breaker_trip", serviceID: serviceID, message: tripped) }
            Task { await captureDebugIssue(
                trigger: "circuit_breaker",
                serviceID: serviceID,
                summary: "\(name) failed \(AutoRestart.failuresToTrip) times in a minute — circuit breaker tripped"
            )}
            return
        case .killedRepeatedly:
            // The service did not crash: something else stops it. No debug issue.
            let signal = state.lastKillSignal ?? SIGTERM
            let times = state.killTimestamps.count
            state.haltReason = .killedRepeatedly(signal: signal, times: times)
            let tripped = "Something else keeps stopping \(name) (\(ServiceTermination.signalName(signal)) \(times) times) — auto-restart stopped"
            postNotice(.service(serviceID), tripped)
            recordFailure(serviceID, kind: .killedRepeatedly(signal: signal, times: times))
            Task { await recordDebugEvent(kind: "breaker_trip", serviceID: serviceID, message: tripped) }
            return
        case .exhausted:
            state.haltReason = .exhausted(restarts: AutoRestart.maxRestarts)
            postNotice(.service(serviceID), "\(name) did not come back after \(AutoRestart.maxRestarts) restarts — auto-restart stopped")
            recordFailure(serviceID, kind: .exhausted(restarts: AutoRestart.maxRestarts))
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

        // While the restart is due, the waiter of the old process gives no verdict.
        pendingRestarts[serviceID, default: 0] += 1
        Task {
            var due = true
            defer { if due { releasePendingRestart(serviceID) } }
            try? await clock.sleep(for: .seconds(baseDelay))
            guard serviceStates[serviceID]?.phase == .failed else { return }

            // A service that failed because the container runtime is down fails again
            // at once. Start the runtime first; if it does not come up, say so and stop.
            let recentLines = await logStore.entries(for: serviceID).map(\.text)
            if CrashCause.showsContainerRuntimeDown(recentLines) {
                let logStore = logStore
                let probe = await ContainerRuntime.ensureRunning(shell: shell, clock: clock) { line in
                    Task { await logStore.append(serviceID: serviceID, entry: LogEntry(
                        stream: .stdout, text: "[travel-runner] \(line) before the restart of \(name)"
                    )) }
                }
                // The user can stop or restart the service during the wait.
                guard serviceStates[serviceID]?.phase == .failed else { return }
                if let reason = probe.failureText(waited: ContainerRuntime.startTimeout) {
                    let runtime = probe.runtime
                    guard case .daemonDown = probe else {
                        // No docker CLI, or a socket that refuses: a wait does not fix it.
                        // A refused socket names the next step and opens the runtime.
                        var reason = reason
                        var kind = FailureAdvisor.Kind.message(reason)
                        if case .permissionDenied = probe {
                            reason += " — quit and reopen \(runtime.appName), then restart \(name)"
                            kind = .blocked(reason, action: .openContainerRuntime)
                        }
                        state.haltReason = .runtimeUnusable(reason)
                        postNotice(.service(serviceID), reason)
                        recordFailure(serviceID, kind: kind)
                        await recordDebugEvent(
                            kind: "breaker_trip", serviceID: serviceID, message: "\(reason) — the restart of \(name) stopped"
                        )
                        return
                    }
                    state.haltReason = .runtimeDown(runtime: runtime.displayName, waiting: true)
                    postNotice(.service(serviceID), Self.runtimeWaitText(runtime, name))
                    recordFailure(serviceID, kind: .runtimeDown(waiting: true))
                    await recordDebugEvent(
                        kind: "breaker_trip", serviceID: serviceID,
                        message: "\(runtime.displayName) is not running — the restart of \(name) waits for it"
                    )
                    waitForContainerRuntime(serviceID, runtime: runtime)
                    return
                }
            }

            // The restart releases it once the phase has changed.
            due = false
            await autoRestart(serviceID)
        }
    }

    /// The banner while a service waits for the container runtime.
    nonisolated static func runtimeWaitText(_ runtime: ContainerRuntime, _ name: String) -> String {
        "\(runtime.displayName) is not running — waiting for it, then restarting \(name)"
    }

    /// Asks the container runtime every 5 s for 10 minutes. When it answers, the
    /// service starts again. A restart, a stop or a new failure ends the wait.
    /// A check of a hung runtime can take 10 s, so the wait also ends at a deadline.
    private func waitForContainerRuntime(_ serviceID: String, runtime: ContainerRuntime) {
        guard let state = serviceStates[serviceID] else { return }
        let name = state.definition.displayName
        let reason = HaltReason.runtimeDown(runtime: runtime.displayName, waiting: true)
        let waiting = { () -> Bool in
            state.haltReason == reason && state.phase == .failed && !self.isShuttingDown && self.health != .stopped
        }
        Task {
            let deadline = clock.uptime() + AutoRestart.runtimeWaitLimit
            for _ in 0..<AutoRestart.runtimeChecks {
                try? await clock.sleep(for: AutoRestart.runtimeCheckInterval)
                guard waiting() else { return }
                guard await ContainerRuntime.probe(shell: shell).isRunning else {
                    if clock.uptime() >= deadline { break }
                    continue
                }
                guard waiting() else { return }
                await logStore.append(serviceID: serviceID, entry: LogEntry(
                    stream: .stdout, text: "[travel-runner] \(runtime.displayName) is back — starting \(name)"
                ))
                notices.resolve(.service(serviceID), ifText: Self.runtimeWaitText(runtime, name))
                restartService(serviceID)
                return
            }
            // It did not come back: the row stops saying that it waits.
            guard waiting() else { return }
            state.haltReason = .runtimeDown(runtime: runtime.displayName, waiting: false)
            if notices.text(.service(serviceID)) == Self.runtimeWaitText(runtime, name) {
                postNotice(.service(serviceID), "\(runtime.displayName) is not running — open \(runtime.appName), then restart \(name)")
            }
            recordFailure(serviceID, kind: .runtimeDown(waiting: false))
            await logStore.append(serviceID: serviceID, entry: LogEntry(
                stream: .stderr,
                text: "[travel-runner] \(runtime.displayName) did not come back in 10 min — open it, then restart \(name)"
            ))
        }
    }

    private func releasePendingRestart(_ serviceID: String) {
        let count = (pendingRestarts[serviceID] ?? 1) - 1
        pendingRestarts[serviceID] = count > 0 ? count : nil
    }

    // MARK: - Private: Health

    /// Recomputes the health and its reason. `startInFlight` defaults to whether a
    /// start runs; the end of a start passes false before its time ends.
    func recalculateHealth(startInFlight: Bool? = nil) {
        refreshWaitingConditions()
        let summaryService = { (state: ServiceState) in
            HealthSummary.Service(
                id: state.id, name: state.definition.displayName, phase: state.phase,
                conditionKind: state.condition?.kind, headline: state.condition?.headline,
                dependsOn: self.graph?.nodes[state.id]?.dependsOn ?? state.definition.dependsOn,
                isCircuitBroken: state.isCircuitBroken
            )
        }
        // The order of the rows; a state outside the graph comes last.
        let ordered = sortedServiceIDs + serviceStates.keys.filter { !sortedServiceIDs.contains($0) }.sorted()
        let services = ordered.compactMap { serviceStates[$0] }
            .filter { $0.definition.resolvedType != .oneshot }
            .map(summaryService)
        // A service that waits for a failed one (a oneshot, say) is a failure too.
        let waitedOn = Set(serviceStates.values.compactMap { state -> String? in
            guard state.phase == .waiting, case .waitingForDependency(let id)? = state.condition?.kind else { return nil }
            return waitTarget(id)
        })
        let waitedOnFailures = ordered.compactMap { serviceStates[$0] }
            .filter { $0.phase == .failed && waitedOn.contains($0.id) && $0.definition.resolvedType == .oneshot }
            .map(summaryService)
        let dbSetupFailure = dbSetupFailedAtStart
            ? "Database setup failed" + (dbSetupPipeline?.firstFailed.map { " at \($0.name)" } ?? "")
            : nil
        let summary = HealthSummary.compute(HealthSummary.Input(
            services: services,
            // While Start All runs, services that are not started yet do not make it stopped.
            startInFlight: startInFlight ?? (startupBeganAt != nil),
            restarting: Set(restartsInFlight.keys),
            refusal: startRefusal,
            dbSetupFailure: dbSetupFailure,
            waitedOnFailures: waitedOnFailures,
            firstFailure: startFailure
        ))
        // A service ran or failed after the refusal: the refusal is over.
        if services.contains(where: { $0.phase != .stopped && $0.phase != .pending }) { startRefusal = nil }
        applyHealth(summary)
    }

    private func applyHealth(_ summary: HealthSummary) {
        health = summary.status
        healthSummary = summary
        rootCauseServiceID = summary.rootCauseID
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
                // Stripe reconnects while the portals are probed.
                async let stripe: Void = reconnectStripeAfterWake()
                await runWakeChecks()
                await stripe
            } while wakePending && (health == .healthy || health == .degraded)
            isHandlingWake = false
            wakePassStartedAt = nil
        }
    }

    private func runWakeChecks() async {
        let timing = wakeTiming
        try? await clock.sleep(for: timing.settle)

        // LAN mode binds all addresses, so a new network after sleep breaks no
        // probe. The network observer moves the LAN URLs to a new address.

        // In start order, Supabase first: the services that need it fail while its
        // containers wake. The services that were down before the wake get one start.
        let order = sortedServiceIDs.filter { isInProfile($0) }
        let downBefore = order.filter { id in serviceStates[id].map(retriesAfterWake) == true }
        let checks = order.filter(isSupabaseStack) + order.filter { !isSupabaseStack($0) }
        var checked = 0
        // The services that were restarted, in order.
        var restarted: [String] = []
        healthMonitor = HealthMonitor()

        // A failed pass alone restarts nothing: a dev server compiles its first
        // request after a wake, and the network can take a while.
        var failing: [String] = []
        for serviceID in checks {
            guard let state = serviceStates[serviceID], state.phase == .running,
                  let (probe, _) = livenessProbe(serviceID) else { continue }
            checked += 1
            let window = isSupabaseStack(serviceID) ? timing.supabaseWindow : timing.window
            let outcome = try? await waitForProbe(probe, timeout: window, interval: timing.interval, clock: clock)
            if outcome?.isReady == true {
                if state.phase == .running { await clearUnhealthy(state) }
            } else {
                failing.append(serviceID)
            }
        }
        if !failing.isEmpty { try? await clock.sleep(for: timing.passGap) }
        for serviceID in failing {
            guard let state = serviceStates[serviceID], state.phase == .running,
                  let (probe, path) = livenessProbe(serviceID) else { continue }
            let window = isSupabaseStack(serviceID) ? timing.supabaseWindow : timing.window
            let outcome = try? await waitForProbe(probe, timeout: window, interval: timing.interval, clock: clock)
            // A restart or a stop can start while the probe runs; it owns the state then.
            guard state.phase == .running else { continue }
            if outcome?.isReady == true {
                await clearUnhealthy(state)
                continue
            }
            let name = state.definition.displayName
            state.lastProbe = outcome
            if isSupabaseStack(serviceID) {
                // The liveness loop never restarts Supabase by itself (plan rule L4):
                // the row offers Restart, and a person decides.
                noteFailure(state, stableFor: state.readyAt.map { clock.date().timeIntervalSince($0) }, countsTowardBreaker: false)
                state.phase = .failed
                recordFailure(serviceID, kind: .wakeCheck(lastProbe: outcome))
                recalculateHealth()
            } else if needsDownSupabase(serviceID) {
                // A new process would fail the same way while Supabase is down.
                await logStore.append(serviceID: serviceID, entry: LogEntry(
                    stream: .stderr, text: "[travel-runner] \(name) did not answer after wake — Supabase is down, so it is not restarted"
                ))
                continue
            } else if let outcome, HealthMonitor.isErrorAnswer(outcome) {
                // The server answers, so it runs: a restart does not fix a 500.
                await markUnhealthy(state, outcome: outcome, path: path, since: clock.date())
            } else {
                let last = outcome.map { " (last check: \($0.summary))" } ?? ""
                let didRestart = await restartUnanswering(
                    serviceID, kind: .wakeCheck(lastProbe: outcome),
                    line: "\(name) did not answer after wake\(last) — stopping it and restarting"
                )
                if didRestart { restarted.append(serviceID) }
            }
            Task { await self.captureDebugIssue(
                trigger: "probe_timeout",
                serviceID: serviceID,
                summary: "\(name) failed wake probe"
            )}
        }

        // Down before the wake: the cause may be gone now (the network, the runtime).
        for serviceID in downBefore {
            guard let state = serviceStates[serviceID], retriesAfterWake(state) else { continue }
            checked += 1
            restarted.append(serviceID)
            await logStore.append(serviceID: serviceID, entry: LogEntry(
                stream: .stdout, text: "[travel-runner] \(state.definition.displayName) was down before the wake — starting it again"
            ))
            restartService(serviceID)
        }
        // Stripe reconnects on its own, beside these checks (`reconnectStripeAfterWake`).

        let summary = HealthMonitor.wakeSummary(checked: checked, restarted: restarted.map(displayName))
        lastWakeSummary = summary
        for serviceID in restarted {
            await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stdout, text: summary))
        }
        await recordDebugEvent(kind: "wake_check", serviceID: nil, message: summary)
    }

    /// A failed service that a wake check starts again: a daemon that the runner
    /// would start, with no restart, wait or action of its own. Supabase is never
    /// restarted by itself. A skip (missing packages or env) stays; Stripe has its
    /// own reconnect after a wake.
    private func retriesAfterWake(_ state: ServiceState) -> Bool {
        guard state.definition.resolvedType != .oneshot, !isSupabaseStack(state.id), state.id != "stripe",
              pendingRestarts[state.id] == nil, !actionsInFlight.contains(state.id),
              !queuedRestarts.contains(state.id) else { return false }
        guard state.phase == .failed else { return false }
        if case .runtimeDown(_, true)? = state.haltReason { return false }
        return true
    }

    /// The probe of a liveness check: the service's own probe with a limit of 5 s
    /// per request, or an HTTP check of a route that must answer for a web
    /// service with a TCP probe. A stdout probe cannot check a running process.
    private func livenessProbe(_ serviceID: String) -> (probe: Probe, path: String?)? {
        if let livenessProbeOverride { return livenessProbeOverride(serviceID).map { ($0, nil) } }
        guard let state = serviceStates[serviceID], state.definition.resolvedType != .oneshot,
              let config = lanAwareDefinition(for: state.definition, serviceID: serviceID).probe ?? state.definition.probe,
              config.type != .stdoutRegex else { return nil }
        if config.type == .tcp, let path = Self.wakeHealthPaths[serviceID], let port = config.port {
            let url = "http://\(config.host ?? "127.0.0.1"):\(port)\(path)"
            return (HttpProbe(url: url, requestTimeout: HealthMonitor.requestTimeout, acceptsClientErrors: true), path)
        }
        guard let probe = try? ProbeFactory.makeProbe(for: config, requestTimeout: HealthMonitor.requestTimeout) else {
            return nil
        }
        let path = config.type == .http ? config.url.flatMap { URL(string: $0)?.path }.flatMap { $0.isEmpty ? nil : $0 } : nil
        return (probe, path)
    }

    /// A service that runs but does not answer: mark it failed, stop its process and
    /// whatever holds its port (an orphaned dev server), and let the automatic
    /// restart start it again. False when a stop or a restart got there first and
    /// this did nothing.
    @discardableResult
    private func restartUnanswering(_ serviceID: String, kind: FailureAdvisor.Kind, line: String) async -> Bool {
        guard let state = serviceStates[serviceID], state.phase == .running else { return false }
        await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stderr, text: "[travel-runner] \(line)"))
        // The log write lets other work run first.
        guard state.phase == .running else { return false }
        noteFailure(state, stableFor: state.readyAt.map { clock.date().timeIntervalSince($0) }, countsTowardBreaker: false)
        state.phase = .failed
        recordFailure(serviceID, kind: kind)
        recalculateHealth()
        await lifecycle.withLock(serviceID) {
            await processRunner.stop(serviceID: serviceID)
            if let port = state.definition.probe?.port { await killPortOccupants(port) }
        }
        scheduleRestart(serviceID: serviceID)
        return true
    }

    /// True when the service needs Supabase and Supabase is down: a restart of the
    /// service cannot help then.
    private func needsDownSupabase(_ serviceID: String) -> Bool {
        guard isSupabaseStack("supabase"), serviceStates["supabase"]?.phase != .running,
              let graph else { return false }
        return graph.dependents(of: "supabase").contains(serviceID)
    }

    /// A running service that answers with an error: the row says what it answers
    /// and since when, and offers Restart. The time of an earlier mark stays.
    private func markUnhealthy(_ state: ServiceState, outcome: ProbeOutcome, path: String?, since: Date) async {
        let isNew = state.condition?.kind != .unhealthy
        let since = isNew ? since : (state.condition?.since ?? since)
        let headline = HealthMonitor.unhealthyHeadline(
            name: state.definition.displayName, outcome: outcome, path: path,
            port: state.definition.probe?.port, since: since
        )
        state.condition = ServiceCondition(
            kind: .unhealthy, headline: headline, detail: "It still runs. Restart it if it does not recover.",
            actions: [.restart, .openLog], since: since
        )
        if isNew {
            await logStore.append(serviceID: state.id, entry: LogEntry(stream: .stderr, text: "[travel-runner] \(headline)"))
            await recordDebugEvent(kind: "unhealthy", serviceID: state.id, message: headline)
        }
    }

    /// A service marked unhealthy passed a check: the mark goes. It does not need
    /// the failure series, which a wake check or an action resets.
    private func clearUnhealthy(_ state: ServiceState) async {
        guard state.condition?.kind == .unhealthy else { return }
        state.clearCondition()
        await logStore.append(serviceID: state.id, entry: LogEntry(
            stream: .stdout, text: "[travel-runner] \(state.definition.displayName) answers again"
        ))
    }

    /// Checks the running daemons every `livenessInterval` while the app runs.
    private func startLivenessLoop() {
        guard !livenessLoopStarted else { return }
        livenessLoopStarted = true
        Task { [weak self] in
            while true {
                // Awake time: a check right after a wake belongs to the wake check.
                let interval = self?.livenessInterval ?? HealthMonitor.interval
                try? await SuspendingClock().sleep(for: interval)
                guard let self else { return }
                if livenessInterval != nil { await runLivenessPass() }
            }
        }
    }

    /// One liveness check of each running daemon. Three failed checks in a row mark
    /// a service unhealthy and offer Restart; only a zombie server is restarted by
    /// itself (decision 16).
    func runLivenessPass() async {
        guard !isShuttingDown, !isHandlingWake, health != .stopped else { return }
        for serviceID in sortedServiceIDs {
            guard let state = serviceStates[serviceID], state.phase == .running, isInProfile(serviceID),
                  !actionsInFlight.contains(serviceID), pendingRestarts[serviceID] == nil,
                  let (probe, path) = livenessProbe(serviceID) else {
                healthMonitor.forget(serviceID)
                continue
            }
            let pid = state.pid
            let outcome = await probe.outcome()
            // A restart, a stop or a wake check can start while the probe runs; it owns the state then.
            guard !isShuttingDown, !isHandlingWake, state.phase == .running, state.pid == pid,
                  !actionsInFlight.contains(serviceID) else { continue }
            if state.lastProbe != outcome { state.lastProbe = outcome }
            let name = state.definition.displayName
            switch healthMonitor.record(serviceID, outcome, at: clock.date()) {
            case .answering:
                // The series may be gone (a wake check, an action), the mark is not.
                await clearUnhealthy(state)
            case .failing:
                break
            case .unhealthy(let since):
                await markUnhealthy(state, outcome: outcome, path: path, since: since)
            case .zombie:
                await restartUnanswering(
                    serviceID, kind: .message("\(name) answered 404 on every route — it was restarted."),
                    line: "\(name) answers 404 on every route (an old server holds the port) — stopping it and restarting"
                )
            }
        }
    }

    // MARK: - Debug Tracking

    /// Starts issue capture. A config reload comes here again: the tracker, its
    /// poll and the launch prune stay single.
    func initDebugTracking() async {
        let tracker = currentIssueTracker()
        let launch = !issueLaunchPruneDone
        issueLaunchPruneDone = true
        startIssueCapturePoll()
        await refreshIssueCapture()
        guard launch else { return }
        let previous = await tracker.beginRun(pid: getpid())
        if debugTracker != nil {
            await tracker.pruneClosedIssues()
        }
        if let previous {
            // The new run's logs say nothing about the crash; the runner log of
            // the last run on disk can.
            let runnerID = LogFileSink.runnerLogID
            let lastRun = logStore.earlierRunTail(for: runnerID, maxLines: Self.uncleanExitLogLines)
            await captureDebugIssue(
                trigger: "unclean_exit",
                serviceID: nil,
                summary: Self.uncleanExitText(
                    previous,
                    runnerLog: logStore.fileURL(for: runnerID).map { DiagnosticsSnapshot.tilde($0.path, home: NSHomeDirectory()) }
                ),
                signature: "unclean exit",
                extraLog: lastRun.map {
                    DebugTracker.LogEntry(timestamp: $0.timestamp, serviceId: Self.lastRunLogID, line: $0.text)
                }
            )
        }
    }

    /// The id of the last run's runner log in the issue logs.
    static let lastRunLogID = "runner-last-run"
    /// How many lines of the last run's runner log an unclean-exit issue gets.
    static let uncleanExitLogLines = 200

    /// The issue text of a run that left its marker behind. Its start says where
    /// to look: the issue summary keeps only the first 120 characters.
    static func uncleanExitText(
        _ marker: DebugTracker.RunMarker,
        appName: String = Flavor.current.displayName,
        runnerLog: String? = nil
    ) -> String {
        let version = marker.appVersion.map { "v\($0)" } ?? "version unknown"
        var text = "The last run did not quit cleanly. Look in "
            + (runnerLog == nil ? "" : "logs-all.txt [\(lastRunLogID)] and ")
            + "~/Library/Logs/DiagnosticReports. "
            + "It was \(appName) \(version), pid \(marker.pid), started \(marker.startedAt). "
            + "It crashed, was force-quit, or the Mac lost power."
        if let runnerLog {
            text += " Its full runner log: \(runnerLog)"
        }
        return text
    }

    /// A clean quit: the next launch finds no marker of this run.
    func markCleanExit() {
        issueTracker?.endRun()
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
        log: [LogEntry]? = nil,
        extraLog: [DebugTracker.LogEntry] = []
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
            likelyCause = stripeAwareCause(
                CrashCause.likelyCause(in: raw.map(\.text), serviceID: sid, redactor: redactor), serviceID: sid
            )
        }
        // The combined log has every service, the DB steps and the runner too.
        for id in await logStore.serviceIDs() where id != serviceID {
            logEntries += await logStore.entries(for: id).map {
                DebugTracker.LogEntry(timestamp: $0.timestamp, serviceId: id, line: $0.text)
            }
        }
        logEntries += extraLog

        // The state of the failure, read now. The tools are read after the
        // issue is filed, so the caller does not wait for them.
        let state = diagnosticsState()
        let _ = await tracker.captureIssue(
            trigger: trigger,
            serviceId: serviceID,
            errorMessage: errorMessage ?? summary,
            signatureText: signature,
            likelyCause: likelyCause,
            logEntries: logEntries,
            stateSnapshots: snapshots,
            redactor: redactor,
            diagnostics: { [weak self] in await self?.withDiagnosticsTools(state) }
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

    /// How long the tools of the last snapshot stay good. A crash loop files many
    /// issues; the tools are read once for them.
    static let diagnosticsToolsMaxAge: TimeInterval = 600

    /// This Mac and the stack now, for the `diagnostics.json` of an issue. The
    /// state is read first: the tools take some seconds and the state can change
    /// meanwhile.
    func diagnosticsSnapshot(home: String = NSHomeDirectory()) async -> DiagnosticsSnapshot {
        await withDiagnosticsTools(diagnosticsState(home: home), home: home)
    }

    /// The snapshot without its tools: the stack, read at once.
    private func diagnosticsState(home: String = NSHomeDirectory()) -> DiagnosticsSnapshot {
        let now = clock.date()
        let services = sortedServiceIDs.compactMap { serviceStates[$0] }
            + serviceStates.values.filter { !sortedServiceIDs.contains($0.id) }.sorted { $0.id < $1.id }
        let pipeline = dbSetupPipeline.map { pipeline in
            DiagnosticsSnapshot.DbPipeline(
                profile: pipeline.profile,
                seedScenario: pipeline.seedScenario.id,
                running: pipeline.isRunning,
                steps: pipeline.steps.map {
                    DiagnosticsSnapshot.DbStep(
                        id: $0.id, name: $0.name, status: $0.status.rawValue,
                        optional: $0.isOptional, error: $0.errorMessage
                    )
                }
            )
        }
        return DiagnosticsSnapshot(
            generatedAt: ISO8601DateFormatter().string(from: now),
            app: DiagnosticsSnapshot.App(.current),
            machine: .current,
            tools: [],
            toolPath: nil,
            profile: profile.rawValue,
            dbMode: dbMode.rawValue,
            health: health.rawValue,
            lastError: lastError,
            preflight: preflightChecks.map { DiagnosticsSnapshot.Check(id: $0.id, name: $0.name, result: $0.result) },
            dbPipeline: pipeline,
            pendingMigrations: pendingMigrations,
            repoPaths: DiagnosticsSnapshot.repoPaths(config?.paths, home: home),
            gitBranches: gitBranches,
            services: services.map { state in
                DiagnosticsSnapshot.Service(
                    id: state.id,
                    phase: state.phase.rawValue,
                    inProfile: isInProfile(state.id),
                    pid: state.pid,
                    exitCode: state.exitCode,
                    restartCount: state.restartCount,
                    circuitBroken: state.isCircuitBroken,
                    uptimeSeconds: state.lastStarted.map { Int(now.timeIntervalSince($0)) }
                )
            }
        )
    }

    /// The snapshot with the tools of this Mac.
    private func withDiagnosticsTools(
        _ state: DiagnosticsSnapshot, home: String = NSHomeDirectory()
    ) async -> DiagnosticsSnapshot {
        var snapshot = state
        let tools = await diagnosticsToolReports()
        snapshot.tools = tools.map { DiagnosticsSnapshot.Tool($0, home: home) }
        snapshot.toolPath = tools.map(\.searchedPath).first { !$0.isEmpty }
            .map { DiagnosticsSnapshot.tilde($0, home: home) }
        return snapshot
    }

    /// The tools report of the diagnostics, read again when it is old or has a
    /// tool that was not read.
    private func diagnosticsToolReports() async -> [ToolReport] {
        if let cached = cachedDiagnosticsTools,
           clock.date().timeIntervalSince(cached.at) < Self.diagnosticsToolsMaxAge {
            return cached.reports
        }
        let cwd = monorepoPath.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let reports: [ToolReport] = if let diagnosticsTools {
            await diagnosticsTools(cwd)
        } else {
            await tools.report(runner: shell, cwd: cwd)
        }
        if !reports.contains(where: \.isUnread) {
            cachedDiagnosticsTools = (clock.date(), reports)
        }
        return reports
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

    /// "Copy Diagnostics Bundle": the snapshot and the last
    /// `DiagnosticsBundle.maxLogLines` lines of each failed service and DB step,
    /// redacted, as JSON.
    func diagnosticsBundleJSON(home: String = NSHomeDirectory()) async -> String {
        let snapshot = await diagnosticsSnapshot(home: home)
        var logs: [String: [LogEntry]] = [:]
        for id in DiagnosticsBundle.failedLogIDs(in: snapshot) {
            logs[id] = await logStore.entries(for: id)
        }
        return DiagnosticsBundle.make(
            snapshot: snapshot,
            redactor: makeRedactor(),
            logs: logs,
            rootCause: rootCauseDescription,
            controlAPIError: controlAPIError,
            configIssues: configIssues
        ).json()
    }

    // MARK: - Problem report

    /// Saves the problem report to Downloads (`ReportExporter`): the snapshot of
    /// this Mac, the log files, the newest open issues and the events. Capture
    /// can be off; the issues that exist still go in.
    func exportReport(focus: ReportExporter.Focus = .general) async throws -> ReportExporter.Report {
        guard !reportExportRunning else { throw ReportExporter.ExportError.alreadyRunning }
        reportExportRunning = true
        defer { reportExportRunning = false }

        let tracker = currentIssueTracker()
        var issueFolders: [(status: String, folder: URL)] = []
        for issue in await tracker.listIssues(status: "open").prefix(ReportExporter.maxIssues) {
            issueFolders.append(("open", URL(fileURLWithPath: await tracker.issueFolderPath(id: issue.id))))
        }
        if case .issue(let id, let status) = focus,
           !issueFolders.contains(where: { $0.folder.lastPathComponent == id }) {
            issueFolders.append((status, URL(fileURLWithPath: await tracker.issueFolderPath(id: id, status: status))))
        }
        var memoryLogs: [String: [LogEntry]] = [:]
        for id in await logStore.serviceIDs() {
            memoryLogs[id] = await logStore.entries(for: id)
        }
        let redactor = makeRedactor()
        let input = ReportExporter.Input(
            snapshot: await diagnosticsSnapshot(),
            redactor: redactor,
            focus: focus,
            focusText: await reportFocusText(focus, redactor: redactor),
            logDirectory: logStore.fileDirectory,
            memoryLogs: memoryLogs,
            issueFolders: issueFolders,
            eventsFile: URL(fileURLWithPath: await tracker.eventsFilePath)
        )
        return try await makeReportExporter().export(input)
    }

    /// One line about what the report was made from.
    private func reportFocusText(_ focus: ReportExporter.Focus, redactor: Redactor) async -> String? {
        switch focus {
        case .general:
            return lastError ?? rootCauseDescription
        case .service(let id):
            guard let state = serviceStates[id] else { return nil }
            let lines = await logStore.entries(for: id).map(\.text)
            let cause = stripeAwareCause(CrashCause.likelyCause(in: lines, serviceID: id, redactor: redactor), serviceID: id)
            let exit = state.exitCode.map { " (exit code \($0))" } ?? ""
            return "\(state.definition.displayName) \(state.phase.rawValue)\(exit)" + (cause.map { " — \($0)" } ?? "")
        case .dbStep(let id):
            guard let step = dbSetupPipeline?.steps.first(where: { $0.id == id }) else { return nil }
            return "\(step.name): \(step.errorMessage ?? step.status.rawValue)"
        case .issue(let id, let status):
            return await currentIssueTracker().listIssues(status: status).first { $0.id == id }?.summary
        }
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

    /// A cause of the log line as a sentence of the row: first letter up.
    nonisolated static func capitalized(_ cause: String) -> String {
        cause.prefix(1).uppercased() + cause.dropFirst()
    }

    /// The cause of a failure. In test-key mode a Stripe 401 is a rejected key, not
    /// an expired login.
    private func stripeAwareCause(_ cause: String?, serviceID: String) -> String? {
        serviceID == "stripe" ? StripeLauncher.exitCause(known: cause, mode: stripeMode) : cause
    }

    /// The Stripe mode for the booking portal of this stack.
    private func stripeResolution() -> StripeKeyResolution {
        StripeLauncher.resolve(bookingPortal: graph?.nodes["travel-portal"]?.resolvedCwd ?? config?.paths?.bookingPortal)
    }

    // MARK: - Stripe state machine (S3)

    /// What the Stripe CLI can do now. The preflight of Start All and the start of
    /// Stripe share one answer for 60 s; a start by a person or a retry asks again.
    func stripeAvailability(_ resolution: StripeKeyResolution) async -> StripeAvailability {
        if let cached = stripeAvailabilityCache.value(for: resolution, now: clock.date()) { return cached }
        let value = await (stripeTooling ?? StripeCLI(shell: shell)).availability(resolution)
        stripeAvailabilityCache.store(value, for: resolution, at: clock.date())
        return value
    }

    private func isStripeNetworkUp() async -> Bool {
        if let stripeNetworkUp { return await stripeNetworkUp() }
        return await canReachHost("api.stripe.com")
    }

    /// A start by a person: the probe asks again, and the retries start over.
    /// Start All keeps the probe answer that its preflight or `/api/preflight` got.
    private func resetStripeRetries(keepingAvailability: Bool = false) {
        stripeGeneration += 1
        stripeNetworkAttempts = 0
        stripeCrashRestarts = 0
        stripeReconnectingAfterWake = false
        stripeWakeStalePID = nil
        stripeWaitAnnounced = nil
        if !keepingAvailability { stripeAvailabilityCache.invalidate() }
    }

    /// Stripe is off, or waits for the network. The row, the log and `events.jsonl`
    /// say why; no issue is filed. A wait for the network, or a check that gave no
    /// answer, tries again by itself.
    private func stripeOff(_ state: ServiceState, _ reason: StripeOffReason, cause: String) async {
        stripeGeneration += 1
        let generation = stripeGeneration
        let shown = reason == .offline && stripeReconnectingAfterWake ? StripeOffReason.afterWake : reason
        // A retry that finds the same cause again says nothing new.
        let repeated = shown.retries && stripeWaitAnnounced == shown.headline
        stripeWaitAnnounced = shown.retries ? shown.headline : nil
        state.phase = .skipped
        noteSkip(
            state, shown.kind, shown.headline,
            detail: cause == shown.headline ? nil : Self.capitalized(cause), actions: shown.actions
        )
        recalculateHealth()
        if !repeated {
            await logStore.append(serviceID: "stripe", entry: LogEntry(stream: .stderr, text: Self.stripeStoppedLine(cause)))
            await recordDebugEvent(kind: "stripe_skip", serviceID: "stripe", message: cause)
        }
        if reason.retries {
            scheduleStripeReconnect(generation)
        } else {
            stripeReconnectingAfterWake = false
            await warnIfNoWebhookSecret()
        }
    }

    /// An exit of `stripe listen`. Its log decides: a rejected key or login turns
    /// Stripe off; no network waits for the network; a crash gets two restarts,
    /// then Stripe is off and one issue is filed.
    private func handleStripeExit(_ state: ServiceState, _ termination: ProcessRunner.Termination) {
        let stableFor = state.readyAt.map { clock.date().timeIntervalSince($0) }
        if AutoRestart.startsNewSeries(uptime: stableFor) {
            stripeCrashRestarts = 0
            stripeNetworkAttempts = 0
            stripeWaitAnnounced = nil
        }
        state.phase = .skipped
        state.exitCode = termination.status
        state.pid = nil
        state.lastStopped = clock.date()
        state.failureTimestamps.removeAll()
        stripeGeneration += 1
        let generation = stripeGeneration
        let exit = "the Stripe CLI \(ServiceTermination.describe(termination))"
        // The stale CLI exited before the wake reconnect stopped it. That is part of
        // the reconnect, not a crash: start it again, or wait for the network.
        if stripeReconnectingAfterWake, termination.pid == stripeWakeStalePID {
            stripeWakeStalePID = nil
            Task {
                if await isStripeNetworkUp() {
                    await retryStripe(generation)
                } else if stripeGeneration == generation {
                    await stripeOff(state, .offline, cause: "\(exit) after wake — no network; Stripe reconnects when the network is back")
                }
            }
            recalculateHealth()
            return
        }
        // The log keeps the lines of earlier launches. An old 401 is not the cause of this exit.
        let launched = state.lastStarted ?? .distantPast
        let mode = stripeMode
        Task {
            let output = await logStore.entries(for: "stripe").filter { $0.timestamp >= launched }.map(\.text)
            // A new start can begin while the log is read; it owns the row then.
            guard stripeGeneration == generation, state.phase == .skipped, state.pid == nil else { return }
            switch StripeExitClassifier.classify(logTail: output) {
            case .auth:
                let known = StripeLauncher.exitCause(known: CrashCause.stripeSessionExpired, mode: mode)
                    ?? CrashCause.stripeSessionExpired
                await stripeOff(state, .notAuthenticated(mode), cause: "\(exit) — \(known)")
            case .network:
                await stripeOff(state, .offline, cause: "\(exit) — no network; Stripe reconnects when the network is back")
            case .cliCrash, .unknown:
                let total = stripeRetryPolicy.crashRestarts
                if stripeCrashRestarts < total {
                    stripeCrashRestarts += 1
                    let reason = StripeOffReason.restarting(stripeCrashRestarts, of: total)
                    noteSkip(state, reason.kind, reason.headline, actions: [])
                    await logStore.append(serviceID: "stripe", entry: LogEntry(
                        stream: .stderr, text: "[travel-runner] Stripe: \(exit) — restarting it (\(stripeCrashRestarts) of \(total))"
                    ))
                    let delay = stripeRetryPolicy.crashDelay
                    Task {
                        try? await clock.sleep(for: delay)
                        await retryStripe(generation)
                    }
                } else {
                    await stripeOff(state, .keptCrashing(restarts: total), cause: "\(exit) — \(StripeLauncher.unknownExitHint(mode))")
                    await captureDebugIssue(
                        trigger: "service_crash",
                        serviceID: "stripe",
                        summary: "Stripe CLI \(ServiceTermination.describe(termination)) after \(total) restarts — webhooks are off"
                    )
                }
            }
        }
        recalculateHealth()
    }

    /// Starts Stripe again for a retry, unless something newer happened to it.
    private func retryStripe(_ generation: Int) async {
        guard stripeGeneration == generation else { return }
        stripeAvailabilityCache.invalidate()
        do {
            try await replaceProcess("stripe", stoppedPhase: .pending, keepsFailureHistory: true, onlyIf: {
                guard self.stripeGeneration == generation, !self.isShuttingDown, self.health != .stopped,
                      let state = self.serviceStates["stripe"] else { return false }
                return state.phase == .skipped && state.pid == nil
            })
        } catch {
            recordFailure("stripe", error: error, lastError: "\(error)")
        }
        if serviceStates["stripe"]?.phase == .running { stripeReconnectingAfterWake = false }
        recalculateHealth()
    }

    /// No network: try again after 5 s, then twice as long each time, up to 60 s.
    /// A try starts Stripe only when the network is back.
    private func scheduleStripeReconnect(_ generation: Int) {
        let delay = stripeRetryPolicy.networkDelay(attempt: stripeNetworkAttempts)
        stripeNetworkAttempts += 1
        Task {
            try? await clock.sleep(for: delay)
            guard stripeGeneration == generation, !isShuttingDown, health != .stopped else { return }
            if await isStripeNetworkUp() {
                await retryStripe(generation)
            } else if stripeGeneration == generation {
                scheduleStripeReconnect(generation)
            }
        }
    }

    /// `stripe listen` gave no webhook secret in time. Stripe is optional: it is
    /// stopped and off, not failed. Without a network it waits for the network.
    private func stripeDidNotConnect(_ state: ServiceState, launch: ServiceLaunch, seconds: Int) async {
        // A stop, or a newer launch, owns the state.
        guard state.pid == launch.pid, state.phase == .starting, !isShuttingDown else { return }
        let generation = stripeGeneration
        await lifecycle.withLock("stripe") { await processRunner.stop(serviceID: "stripe") }
        let online = await isStripeNetworkUp()
        guard stripeGeneration == generation, state.pid == launch.pid, !isShuttingDown else { return }
        state.pid = nil
        if online {
            await stripeOff(state, .didNotConnect(seconds: seconds), cause: "stripe listen did not connect within \(seconds)s")
        } else {
            await stripeOff(state, .offline, cause: "stripe listen did not connect — no network; Stripe reconnects when the network is back")
        }
    }

    /// After a wake the CLI's connection is stale. The runner stops it (its own
    /// stop, so no crash) and starts it again while the portals are probed. With no
    /// network it waits for the network: no issue, and the stack stays green.
    private func reconnectStripeAfterWake() async {
        guard isInProfile("stripe"), let state = serviceStates["stripe"] else { return }
        let waits = state.phase == .skipped && state.condition?.kind == .retrying
        guard state.phase == .running || state.phase == .starting || state.phase == .failed || waits else { return }
        stripeGeneration += 1
        let generation = stripeGeneration
        stripeNetworkAttempts = 0
        stripeReconnectingAfterWake = true
        stripeWakeStalePID = state.pid
        stripeAvailabilityCache.invalidate()
        noteSkip(state, StripeOffReason.afterWake.kind, StripeOffReason.afterWake.headline)
        await logStore.append(serviceID: "stripe", entry: LogEntry(stream: .stdout, text: "[travel-runner] Reconnecting Stripe after wake"))
        await stripeBeforeWakeStop?()
        do {
            try await replaceProcess("stripe", stoppedPhase: .pending, keepsFailureHistory: true, onlyIf: {
                self.stripeGeneration == generation && !self.isShuttingDown && self.health != .stopped
            })
        } catch {
            recordFailure("stripe", error: error, lastError: "\(error)")
        }
        if state.phase == .running { stripeReconnectingAfterWake = false }
        recalculateHealth()
    }

    /// The Install and Update buttons of the Stripe row: Homebrew, then a start.
    private func runStripeSetup(_ command: String) {
        Task {
            beginAction("stripe")
            defer { endAction("stripe") }
            await logStore.append(serviceID: "stripe", entry: LogEntry(stream: .stdout, text: "[travel-runner] Running: \(command)"))
            let result = await shell.run(command, timeout: EnvironmentChecker.installTimeout)
            let output = (result.stdout + "\n" + result.stderr).split(whereSeparator: \.isNewline).suffix(20)
            await logStore.appendBatch(serviceID: "stripe", entries: output.map { LogEntry(stream: .stdout, text: String($0)) })
            if result.succeeded {
                restartService("stripe")
            } else {
                onActionFeedback?("\(command) failed — see the Stripe log", false)
            }
        }
    }

    /// The "Log in…" button of the Stripe row: `stripe login` in Terminal.
    private func openStripeLogin() {
        let shell = shell
        Task {
            let opened = await shell.run(EnvironmentChecker.terminalCommand("stripe login")).succeeded
            onActionFeedback?(
                opened ? "Finish stripe login in Terminal, then start Stripe from its row" : "Could not open Terminal — run: stripe login",
                opened
            )
        }
    }

    /// The "Import…" button of the Stripe row: the shared `.env` of the booking
    /// portal, then a start of Stripe on its key.
    func importSharedEnvForStripe() {
        guard let monorepo = supabaseCwd ?? monorepoPath else {
            onActionFeedback?("No monorepo path — set it in Settings > Paths, then import the .env again", false)
            return
        }
        let checker = EnvironmentChecker(
            monorepoPath: monorepo, loginPath: "", streamServicesPath: "", shell: shell, tools: tools
        )
        Task {
            // Nil is a cancel: the person chose not to import.
            switch await checker.importSharedEnv(.booking) {
            case true?:
                restartService("stripe")
            case false?:
                onActionFeedback?("The .env was not imported — check the file and that apps/booking-portal can be written, then try again", false)
            case nil:
                break
            }
        }
    }

    private func canReachHost(_ host: String) async -> Bool {
        await runShellCommand("nc -z -w 2 \(host) 443 >/dev/null 2>&1", timeout: .seconds(10))
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
            postNotice(.dbSetup, message)
            return .notRun
        case .none, .offerMigrate, .offerReset:
            return .notRun
        case .autoSetup:
            reason = Self.emptyDatabaseProgressText(scenario: selectedDbSeedScenario?.name ?? selectedDbSeedScenarioID)
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

    /// The progress notice of the setup of an empty database.
    nonisolated static func emptyDatabaseProgressText(scenario: String?) -> String {
        "Empty database — running the reset now" + (scenario.map { " (seed: \($0))" } ?? "")
    }

    /// A query that hangs counts as a failed query, never as an empty database.
    nonisolated static let databaseQueryTimeout: Duration = .seconds(20)

    nonisolated static let dbResetCancelledMessage =
        "The database reset stopped before it finished. Open DB Tools and click Reset Database to run it again."

    /// A pipeline for the manifest profile with the selected seed scenario, or nil (and
    /// a db-setup notice) when no valid scenario is selected.
    private func makeDbSetupPipeline(cwd: String, profile: String) -> DbSetupPipeline? {
        if let dbPipelineFactory {
            guard let pipeline = dbPipelineFactory(cwd, profile) else {
                postNotice(.dbSetup, "No DB setup pipeline for the profile \(profile).")
                return nil
            }
            return pipeline
        }
        let manifestPath = (cwd as NSString).appendingPathComponent("scripts/db/manifest.json")
        // The loader runs `reset` for a profile it does not find. Apply must never reset,
        // and a reset without hotels must not load them.
        if profile == DbResetPolicy.migrateProfile,
           DbManifestLoader.profileNames(from: manifestPath)?.contains(profile) != true {
            postNotice(.dbSetup, DbResetPolicy.noMigrateProfileText)
            return nil
        }
        if profile == HotelCatalog.withoutHotelsProfile,
           DbManifestLoader.profileNames(from: manifestPath)?.contains(profile) != true {
            postNotice(.dbSetup, HotelCatalog.noWithoutHotelsProfileText)
            return nil
        }
        reloadDbSeedScenarios()
        // Apply migrations seeds nothing, so it needs no scenario.
        let scenario = selectedDbSeedScenario
            ?? (profile == DbResetPolicy.migrateProfile ? DbResetPolicy.noScenario : nil)
        guard let seedScenario = scenario else {
            postNotice(.dbSetup, dbSeedScenarioLoadError
                ?? "Choose a valid seed scenario before resetting the database.")
            return nil
        }
        // A bad manifest or a profile it lacks runs nothing. Only a checkout with no
        // manifest runs the built-in steps, and the pipeline says so.
        let steps: [DbSetupStep]
        do {
            steps = try DbManifestLoader.load(from: manifestPath, profile: profile)
        } catch {
            postNotice(.dbSetup, error.localizedDescription)
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
            profile: pipeline.profile, tools: tools, shell: shell, launcher: dbStepLauncher,
            killGrace: dbStepKillGrace
        )
    }

    /// LAN mode binds all addresses, so loopback answers for it too. A connect to
    /// the LAN address is not used: after a network change that address is gone,
    /// and the connect blocks the main actor for the TCP timeout.
    private func isPortBound(_ port: Int) -> Bool {
        if isPortBoundOnAddress(port, address: UInt32(INADDR_LOOPBACK).bigEndian) { return true }
        // Node binds `localhost` to ::1 only: an IPv4 connect does not see it.
        return isPortBoundOnIPv6Loopback(port)
    }

    private func isPortBoundOnIPv6Loopback(_ port: Int) -> Bool {
        guard let portNumber = UInt16(exactly: port) else { return false }
        let sock = Darwin.socket(AF_INET6, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = portNumber.bigEndian
        addr.sin6_addr = in6addr_loopback
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        return result == 0
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

    /// Kills the listeners of the port and waits up to five seconds for it to free.
    /// The port frees only when a listener was killed. With none killed (a container
    /// holds it) there is nothing to wait for. `includingForeign` is for a button
    /// that the person pressed.
    private func freePort(_ port: Int, includingForeign: Bool = false) async {
        guard await killPortOccupants(port, includingForeign: includingForeign) else { return }
        for _ in 0..<10 {
            try? await clock.sleep(for: .milliseconds(500))
            if !isPortBound(port) { break }
        }
    }

    /// Kills the process that listens on the port. `lsof -i :port` alone also matches
    /// the clients of the port (a browser tab, the Stripe CLI that forwards to the
    /// portal, another dev server), and those must stay alive.
    /// A container runtime is never killed: its port helper serves every container.
    /// A process that the runner did not start is killed only with `includingForeign`.
    /// True when it killed a listener.
    @discardableResult
    private func killPortOccupants(_ port: Int, includingForeign: Bool = false) async -> Bool {
        var killed = false
        for occupant in await portOccupants(port) {
            let listener = occupant.listener
            switch occupant.owner {
            case .containerRuntime:
                await logPortLine(port, "Port \(port) is published by \(listener.command) (a container). Not killed.")
                continue
            case .foreign where !includingForeign:
                await logPortLine(
                    port, "Port \(port) is in use by \(listener.command) (PID \(listener.pid)), which \(Flavor.current.displayName) did not start. Not killed."
                )
                continue
            case .ownLaunch, .ownLeftover, .foreign:
                break
            }
            portTools.kill(listener.pid)
            killed = true
        }
        return killed
    }

    /// A line in the log of the service of the port.
    private func logPortLine(_ port: Int, _ text: String) async {
        guard let serviceID = sortedServiceIDs.first(where: { serviceStates[$0]?.definition.probe?.port == port }) else { return }
        await logStore.append(serviceID: serviceID, entry: LogEntry(stream: .stderr, text: "[travel-runner] \(text)"))
    }

    // MARK: - Process ownership

    /// What the ownership rules know now: the live ledger entries, and the folders
    /// of the services (decision 15).
    private func ownershipKnowledge() -> PortOwner.Knowledge {
        let tools = portTools
        return PortOwner.Knowledge(
            ledger: ledger.live(facts: tools.facts),
            sessionPIDs: ledger.sessionPIDs,
            roots: PortOwner.roots(serviceStates.values.compactMap { $0.definition.resolvedCwd }),
            facts: tools.facts,
            ancestors: tools.ancestors
        )
    }

    /// Who listens on the port. Empty: the port is free.
    func portOccupants(_ port: Int) async -> [PortOwner.Occupant] {
        let listeners = await portTools.listeners(port)
        return PortOwner.classify(listeners, ownershipKnowledge())
    }

    /// Records a process that this run started.
    private func recordLaunch(_ serviceID: String, pid: pid_t, definition: ServiceDefinition) {
        // The command of the service, never its environment.
        ledger.record(
            serviceID: serviceID, pid: pid, cwd: definition.resolvedCwd, command: definition.cmd, facts: portTools.facts
        )
    }

    /// At launch, also after a relaunch for an update: the processes of the last
    /// session that still run. The ledger forgets the ones that are gone.
    func reconcileLeftovers() {
        let facts = portTools.facts
        ledger.prune(facts: facts)
        leftoverNotice = Self.leftoverText(ledger.leftovers(facts: facts).map(\.serviceID), states: serviceStates)
    }

    /// "3 services from the last session are still running (Travel Portal :3002, …)."
    static func leftoverText(_ serviceIDs: [String], states: [String: ServiceState]) -> String? {
        var ids: [String] = []
        for id in serviceIDs where !ids.contains(id) { ids.append(id) }
        guard !ids.isEmpty else { return nil }
        let names = ids.map { id -> String in
            let definition = states[id]?.definition
            let name = definition?.displayName ?? id
            return definition?.probe?.port.map { "\(name) :\($0)" } ?? name
        }
        let one = ids.count == 1
        return "\(ids.count) service\(one ? "" : "s") from the last session \(one ? "is" : "are") still running (\(names.joined(separator: ", ")))."
    }

    /// Stops the processes of the last session with their children. Start does it
    /// first, without asking: they are the runner's own.
    func stopLeftovers() async {
        let leftovers = ledger.leftovers(facts: portTools.facts)
        for entry in leftovers {
            await portTools.stopTree(entry.pid)
            let name = serviceStates[entry.serviceID]?.definition.displayName ?? entry.serviceID
            await logStore.append(serviceID: entry.serviceID, entry: LogEntry(
                stream: .stdout, text: "[travel-runner] Stopped \(name) (PID \(entry.pid)) from the last session."
            ))
        }
        ledger.remove(pids: leftovers.map(\.pid))
        leftoverNotice = nil
    }

    /// The "Stop them" button of the banner.
    func stopLeftoversFromBanner() {
        Task {
            await stopLeftovers()
            onActionFeedback?("Stopped the services of the last session", true)
        }
    }

    /// The processes that the quit stops: each live ledger entry with its children.
    /// The tree is read before the first signal.
    func ledgerTreesForQuit() -> [pid_t] {
        let tools = portTools
        return ledger.live(facts: tools.facts).flatMap { tools.tree($0.pid) }
    }

    /// The listeners of the ports that the runner owns, for the quit. A process of
    /// a stranger and a container runtime stay alive.
    func ownListenersNow(on ports: [Int]) -> [pid_t] {
        let knowledge = ownershipKnowledge()
        let tools = portTools
        return ports.flatMap { port in
            PortOwner.classify(tools.listenersNow(port), knowledge)
                .filter { $0.owner.isOwn }.map(\.listener.pid)
        }
    }

    /// True while the pid names the process that a button names: the same start
    /// time, and a listener of the port when the button has one. Without a start
    /// time the process is not known, and nothing is stopped.
    static func isSameProcess(_ pid: pid_t, startTime: Int64?, port: Int?, tools: PortTools) async -> Bool {
        guard let startTime, tools.facts(pid)?.startTime == startTime else { return false }
        guard let port else { return true }
        return await tools.listeners(port).contains { $0.pid == pid }
    }

    /// A launch of this session ended: its root left the ledger. A `next dev` that
    /// it started can outlive it, with no parent in the ledger.
    private func noteEndedLaunch(_ entry: LaunchLedger.Entry) {
        let earliest = endedLaunchStarts[entry.serviceID].map { min($0, entry.startTime) } ?? entry.startTime
        endedLaunchStarts[entry.serviceID] = earliest
    }

    /// The quit stopped the processes of the ledger: the next launch has nothing to report.
    func forgetLaunches() {
        ledger.remove(pids: ledger.entries.map(\.pid))
    }

    /// A `next dev` of the person in the folder of the service. Next allows one dev
    /// server per folder, so the start would fail in a loop. The runner's own (in
    /// the ledger) do not count: the port cleanup and Start stop those.
    ///
    /// A `next dev` that started after a launch of this service that has ended is
    /// the runner's own too: a crash of the root (pnpm) left it. It is stopped
    /// without a question. Decision 15 (a folder of the repos is the runner's) does
    /// not apply here: the folder of the service always is, and the plan asks
    /// before it stops a `next dev` that the person started there.
    private func checkOtherNextDev(_ definition: ServiceDefinition) async throws {
        guard definition.resolvedType == .daemon, let cwd = definition.resolvedCwd, !cwd.isEmpty else { return }
        let tools = portTools
        let processes = await Task.detached { tools.processesIn(cwd) }.value
        guard !processes.isEmpty else { return }
        let knowledge = ownershipKnowledge()
        let others = PortOwner.otherNextDevs(processes, knowledge)
        let endedSince = endedLaunchStarts[definition.id]
        for orphan in others {
            guard let endedSince, orphan.startTime >= endedSince else { continue }
            await tools.stopTree(orphan.pid)
            await logStore.append(serviceID: definition.id, entry: LogEntry(
                stream: .stdout,
                text: "[travel-runner] Stopped a next dev (PID \(orphan.pid)) that an earlier start of \(definition.displayName) left."
            ))
        }
        guard let other = others.first(where: { process in endedSince.map { process.startTime < $0 } ?? true }) else { return }
        let port = await tools.listeningPorts(other.pid).first
        let folder = PortOwner.folderName(cwd, roots: knowledge.roots)
        throw ServiceError.otherNextDev(pid: other.pid, port: port, folder: folder, startTime: other.startTime)
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

    /// The web services, and a route that must answer on each. A liveness check of a
    /// TCP probe asks this route. "/" is wrong for universal-login, which
    /// legitimately 404s at root (app lives at /frontdoor).
    static let wakeHealthPaths: [String: String] = [
        "travel-portal": "/",
        "universal-login": "/frontdoor",
        "partner-portal": "/",
    ]

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
    /// and to services outside the profile. `kept` are services that run and stay
    /// ("Retry failed"): their ports and processes are left alone.
    func cleanupStaleProcesses(sparing kept: Set<String> = []) async {
        // Kill by port — only non-reuse services of the profile (skip Docker-managed ports)
        let killablePorts = killableServices.filter { !kept.contains($0.id) }.compactMap { $0.probe?.port }

        var didKill = false
        for port in killablePorts {
            if isPortBound(port) {
                await killPortOccupants(port)
                didKill = true
            }
        }

        // Kill a Stripe listener that an earlier session left. The pattern is the
        // command of the service, so any other `stripe listen` stays alive.
        if isInProfile("stripe"), !kept.contains("stripe"), let stripe = serviceStates["stripe"]?.definition {
            for pattern in StripeLauncher.stalePatterns(for: stripe.cmd) {
                await portTools.killCommands(pattern)
            }
        }

        if didKill {
            try? await clock.sleep(for: .milliseconds(500))
        }
    }
}
