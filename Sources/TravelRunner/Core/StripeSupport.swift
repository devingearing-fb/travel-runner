import Foundation

/// How the Stripe CLI signs in to Stripe.
enum StripeMode: Equatable, Sendable {
    /// The `sk_test_` key of the booking portal. `source` is the file, relative to
    /// the monorepo, for example "apps/booking-portal/.env".
    case testKey(source: String)
    /// The developer's own `stripe login`. `reason` says why the test key is not used.
    case login(reason: String)

    var isTestKey: Bool {
        if case .testKey = self { return true }
        return false
    }

    /// The line under the Stripe row.
    var rowText: String {
        switch self {
        case .testKey(let source): "Test key from \(source)"
        case .login: "Your stripe login"
        }
    }

    /// The line in the Stripe log at each start.
    var logLine: String {
        switch self {
        case .testKey(let source):
            "[travel-runner] Stripe uses the test key from \(source) (STRIPE_SECRET_KEY)."
        case .login(let reason):
            "[travel-runner] Stripe uses your stripe login: \(reason)."
        }
    }
}

/// The mode of the Stripe CLI and the values for its process. The key is only in
/// `environment`; the text of this value never shows it.
struct StripeKeyResolution: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let mode: StripeMode
    /// `STRIPE_API_KEY` in test-key mode, empty in login mode.
    let environment: [String: String]

    var description: String { "StripeKeyResolution(\(mode.rowText))" }
    var debugDescription: String { description }
}

/// Starts `stripe listen` on the test key of the booking portal, so a teammate
/// needs no `stripe login`. Without a usable key it uses the login, as before.
enum StripeLauncher {
    /// The variable of the booking portal that holds its Stripe key.
    static let secretKeyName = "STRIPE_SECRET_KEY"
    /// The Stripe CLI reads its key from this variable, before its stored login.
    static let apiKeyVariable = "STRIPE_API_KEY"
    static let testKeyPrefix = "sk_test_"
    static let liveKeyPrefix = "sk_live_"

    /// The booking portal, relative to the monorepo.
    static let bookingPortalDirectory = "apps/booking-portal"
    /// Read in this order; a value in a later file wins, as in Next.js.
    static let envFiles = [".env", ".env.local"]

    /// IPv4 on purpose: with `localhost` the CLI can dial `[::1]:3002`, where the
    /// portal does not listen.
    static let forwardURL = "http://127.0.0.1:3002/api/webhooks/stripe"
    /// No update check at each start. The key is never an argument: it would show in `ps`.
    static let command = ["stripe", "listen", "--skip-update", "--forward-to", forwardURL]
    /// The command of the runner before S1. The cleanup also kills a listener with
    /// this command that an older runner left, so the portal gets no event twice.
    /// Remove it one release after S1.
    static let legacyCommand = ["stripe", "listen", "--forward-to", "http://localhost:3002/api/webhooks/stripe"]

    /// The `pkill -f` patterns of the listeners that an earlier session left.
    static func stalePatterns(for cmd: [String]) -> [String] {
        let current = PortOwner.commandPattern(for: cmd)
        guard cmd == command else { return [current] }
        return [current, PortOwner.commandPattern(for: legacyCommand)]
    }

    /// Installs the Stripe CLI.
    static let installCommand = "brew install stripe/stripe-cli/stripe"
    /// Updates the Stripe CLI.
    static let updateCommand = "brew upgrade stripe/stripe-cli/stripe"
    /// Proves that the CLI can call Stripe: `stripe config --list` exits 0 also for an
    /// expired key. Its output tells a rejected key from no network.
    static let authCheckCommand = "stripe balance retrieve"
    static let installedCommand = "which stripe >/dev/null 2>&1"
    static let versionCommand = "stripe version"
    /// Seconds for `stripe listen` to print its webhook secret. Then Stripe is off,
    /// not failed.
    static let connectTimeout = 25
    /// The oldest CLI that the runner starts. Nil until decision 27 names one: then
    /// no version is checked.
    static let minimumVersion: StripeVersion? = nil

    static let noKeyReason = "no \(secretKeyName) in \(bookingPortalDirectory)/.env"

    /// The mode for the booking portal at `bookingPortal` (its folder).
    static func resolve(bookingPortal: String?) -> StripeKeyResolution {
        guard let bookingPortal, !bookingPortal.isEmpty else {
            return resolve(values: [])
        }
        // The dotenv parser of the shared `.env`: it drops a ` # comment` and takes
        // the last line of a key, as Next.js does.
        let values = envFiles.map { file in
            (file: "\(bookingPortalDirectory)/\(file)",
             value: AgentEnv.sharedValues(file: (bookingPortal as NSString).appendingPathComponent(file))[secretKeyName])
        }
        return resolve(values: values)
    }

    /// The mode for the values of `STRIPE_SECRET_KEY`, one per env file in read
    /// order. An empty value does not count. Only an `sk_test_` key is used, never a live key.
    static func resolve(values: [(file: String, value: String?)]) -> StripeKeyResolution {
        let found = values.last { !($0.value ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard let found, let key = found.value?.trimmingCharacters(in: .whitespaces) else {
            return StripeKeyResolution(mode: .login(reason: noKeyReason), environment: [:])
        }
        if key.hasPrefix(testKeyPrefix) {
            return StripeKeyResolution(mode: .testKey(source: found.file), environment: [apiKeyVariable: key])
        }
        let kind = key.hasPrefix(liveKeyPrefix) ? "a live key" : "not a secret test key (sk_test_…)"
        return StripeKeyResolution(
            mode: .login(reason: "\(secretKeyName) in \(found.file) is \(kind), and the runner uses only test keys"),
            environment: [:]
        )
    }

    /// The service with the key for its process, in test-key mode.
    static func definition(_ definition: ServiceDefinition, resolution: StripeKeyResolution) -> ServiceDefinition {
        EventDirectoryLauncher.definition(definition, env: resolution.environment)
    }

    /// A 401 from the CLI in test-key mode: the key is wrong, and `stripe login` does not help.
    static func keyRejected(source: String) -> String {
        "Stripe rejected \(secretKeyName) from \(source) — import a current .env."
    }

    /// The cause of an exit of the CLI, from the cause that its log shows.
    static func exitCause(known: String?, mode: StripeMode?) -> String? {
        guard case .testKey(let source) = mode else { return known }
        return known == CrashCause.stripeSessionExpired ? keyRejected(source: source) : known
    }

    /// The text when an exit has no known cause.
    static func unknownExitHint(_ mode: StripeMode?) -> String {
        if case .testKey(let source) = mode {
            return "see the lines above. If they show 401, import a current \(source). Then start it from its row."
        }
        return "see the lines above. If they show 401, run: stripe login. Then start it from its row."
    }

    /// The status of the setup row "Stripe CLI Auth". `loggedIn` is nil in test-key
    /// mode, where the row does not ask the CLI.
    static func authStatus(_ mode: StripeMode, loggedIn: Bool?) -> CheckStatus {
        switch mode {
        case .testKey(let source):
            return .passing("Using the test key from \(source)")
        case .login(let reason):
            if loggedIn == true { return .passing("Authenticated (your stripe login)") }
            if reason == noKeyReason { return .warning("Session invalid or expired — run: stripe login") }
            return .warning("Session invalid or expired — run: stripe login. Or import a .env with a test key: \(reason)")
        }
    }

    /// The setup fix "Log in…" when the CLI is missing: Terminal is not opened.
    static let notInstalledForLoginText =
        "The Stripe CLI is not installed — install it with: \(installCommand), then log in"
}

// MARK: - S3: one Stripe state machine

/// A version of the Stripe CLI, from `stripe version` ("stripe version 1.21.8").
struct StripeVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init(_ parts: [Int]) { self.parts = parts }

    /// The first "1.2.3" in the text.
    init?(parsing text: String) {
        let pattern = try! NSRegularExpression(pattern: #"(\d+)\.(\d+)(?:\.(\d+))?"#)
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        parts = (1...3).compactMap { index in
            Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
        }
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (lhs: StripeVersion, rhs: StripeVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        let left = lhs.parts + Array(repeating: 0, count: count - lhs.parts.count)
        let right = rhs.parts + Array(repeating: 0, count: count - rhs.parts.count)
        return left.lexicographicallyPrecedes(right)
    }
}

/// What the Stripe CLI can do now. One probe gives one of these.
enum StripeAvailability: Equatable, Sendable {
    case ok(StripeMode)
    case notInstalled
    /// No network, or Stripe did not answer.
    case offline
    /// Stripe rejected the test key, or the login expired.
    case notAuthenticated
    case outdated(version: String)

    var isOK: Bool {
        if case .ok = self { return true }
        return false
    }

    /// The answer of `stripe balance retrieve`. Its output says why it failed; a
    /// failure without a known line counts as a rejected key or login.
    static func classify(authCheck result: CommandResult, mode: StripeMode) -> StripeAvailability {
        if result.succeeded { return .ok(mode) }
        if result.timedOut { return .offline }
        let lines = (result.stdout + "\n" + result.stderr).components(separatedBy: .newlines)
        switch StripeExitClassifier.classify(logTail: lines) {
        case .network: return .offline
        case .auth, .cliCrash, .unknown: return .notAuthenticated
        }
    }
}

/// Asks the Stripe CLI whether it can run. Tests give a fake.
protocol StripeTooling: Sendable {
    func availability(_ resolution: StripeKeyResolution) async -> StripeAvailability
}

/// The live probe: is the CLI there, is it new enough, and can it call Stripe.
/// Each command has a timeout.
struct StripeCLI: StripeTooling {
    let shell: any CommandRunning
    var timeout: Duration = .seconds(15)
    var minimumVersion: StripeVersion? = StripeLauncher.minimumVersion

    func availability(_ resolution: StripeKeyResolution) async -> StripeAvailability {
        let installed = await shell.run(StripeLauncher.installedCommand, timeout: timeout)
        if !installed.succeeded { return installed.timedOut ? .offline : .notInstalled }
        if let minimumVersion {
            let output = await shell.run(StripeLauncher.versionCommand, timeout: timeout)
            if let version = StripeVersion(parsing: output.stdout), version < minimumVersion {
                return .outdated(version: version.description)
            }
        }
        // The test key goes in the env of the check, as it does for the listener.
        let auth = await shell.run(StripeLauncher.authCheckCommand, environment: resolution.environment, timeout: timeout)
        return StripeAvailability.classify(authCheck: auth, mode: resolution.mode)
    }
}

/// The last answer of the probe, for 60 s. Start All asks in its preflight and
/// again at the start of Stripe; the second ask reads this.
struct StripeAvailabilityCache {
    static let lifetime: TimeInterval = 60
    private var entry: (resolution: StripeKeyResolution, at: Date, value: StripeAvailability)?

    func value(for resolution: StripeKeyResolution, now: Date) -> StripeAvailability? {
        guard let entry, entry.resolution == resolution,
              now.timeIntervalSince(entry.at) < Self.lifetime, now >= entry.at else { return nil }
        return entry.value
    }

    mutating func store(_ value: StripeAvailability, for resolution: StripeKeyResolution, at date: Date) {
        entry = (resolution, date, value)
    }

    mutating func invalidate() { entry = nil }
}

/// Why `stripe listen` ended, from the lines of its log.
enum StripeExitClassifier {
    enum Kind: Equatable, Sendable {
        case auth
        case network
        case cliCrash
        case unknown
    }

    static let authMarkers = ["status=401", "Authorization failed", "api_key_expired", "Invalid API Key",
                              "have not configured API keys"]
    static let networkMarkers = ["no such host", "dial tcp"]
    static let crashMarkers = ["panic:"]
    /// The lines of the log that count.
    static let window = 40

    static func classify(logTail: [String]) -> Kind {
        let tail = logTail.suffix(window)
        func shows(_ markers: [String]) -> Bool {
            tail.contains { line in markers.contains { line.localizedCaseInsensitiveContains($0) } }
        }
        if shows(authMarkers) { return .auth }
        if shows(networkMarkers) { return .network }
        if shows(crashMarkers) { return .cliCrash }
        return .unknown
    }
}

/// How long the runner waits before it tries Stripe again.
struct StripeRetryPolicy: Sendable {
    /// No network: 5 s, then twice as long each time, up to 60 s.
    var networkBase: Duration = .seconds(5)
    var networkCap: Duration = .seconds(60)
    /// A crash or an exit with no known cause: this many restarts, then Stripe is off.
    var crashRestarts = 2
    var crashDelay: Duration = .seconds(5)

    func networkDelay(attempt: Int) -> Duration {
        var delay = networkBase
        for _ in 0..<max(0, min(attempt, 16)) {
            delay = delay * 2
            if delay >= networkCap { return networkCap }
        }
        return min(delay, networkCap)
    }
}

/// Why Stripe is off or waits, for its row: the text and the button.
struct StripeOffReason: Equatable, Sendable {
    let headline: String
    var actions: [RecoveryAction] = []
    /// The runner tries again by itself (no network, after wake, after a crash).
    var retries = false

    static let notInstalled = StripeOffReason(
        headline: "Stripe CLI not installed — webhooks are off. Run: \(StripeLauncher.installCommand)",
        actions: [.installStripe]
    )
    static let loginExpired = StripeOffReason(
        headline: "Stripe CLI login expired — webhooks are off.", actions: [.stripeLogin]
    )
    static func keyRejected(source: String) -> StripeOffReason {
        StripeOffReason(headline: StripeLauncher.keyRejected(source: source), actions: [.importSharedEnv])
    }
    static let offline = StripeOffReason(
        headline: "No network — Stripe reconnects when the network is back.", retries: true
    )
    static let afterWake = StripeOffReason(headline: "Reconnecting Stripe after wake…", retries: true)
    static func didNotConnect(seconds: Int) -> StripeOffReason {
        StripeOffReason(headline: "Stripe did not connect within \(seconds)s — webhooks are off.", actions: [.startService])
    }
    static let crashedTwice = StripeOffReason(
        headline: "Stripe CLI crashed twice (see log) — webhooks are off.", actions: [.startService, .openLog]
    )
    static func restarting(_ attempt: Int, of total: Int) -> StripeOffReason {
        StripeOffReason(headline: "Stripe CLI exited — restarting it (\(attempt) of \(total)).", retries: true)
    }
    static func outdated(version: String) -> StripeOffReason {
        let needed = StripeLauncher.minimumVersion.map { " (needs \($0) or newer)" } ?? ""
        return StripeOffReason(
            headline: "Stripe CLI \(version) is too old\(needed) — webhooks are off. Run: \(StripeLauncher.updateCommand)",
            actions: [.updateStripe]
        )
    }

    /// A rejected key in test-key mode, an expired login otherwise.
    static func notAuthenticated(_ mode: StripeMode?) -> StripeOffReason {
        if case .testKey(let source) = mode { return keyRejected(source: source) }
        return loginExpired
    }

    /// The reason for an answer of the probe. Nil when Stripe can run.
    static func unavailable(_ availability: StripeAvailability, mode: StripeMode) -> StripeOffReason? {
        switch availability {
        case .ok: nil
        case .notInstalled: notInstalled
        case .offline: offline
        case .notAuthenticated: notAuthenticated(mode)
        case .outdated(let version): outdated(version: version)
        }
    }

    /// The condition kind of the row: a retry, or off until someone acts.
    var kind: ServiceCondition.Kind { retries ? .retrying : .optionalOff }
}
