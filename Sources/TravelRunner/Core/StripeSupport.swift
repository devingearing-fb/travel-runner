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
    /// Proves that the CLI can call Stripe: `stripe config --list` exits 0 also for an expired key.
    static let authCheckCommand = "stripe balance retrieve >/dev/null 2>&1"
    static let installedCommand = "which stripe >/dev/null 2>&1"
    static let availabilityCommand = "\(installedCommand) && \(authCheckCommand)"

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

    /// Why Stripe is skipped when its availability check fails.
    static func unavailableCause(_ mode: StripeMode) -> String {
        switch mode {
        case .testKey(let source):
            "the Stripe CLI is not installed (\(installCommand)), or Stripe did not accept \(secretKeyName) from \(source) "
                + "(import a current .env), or there is no network — then start it from its row"
        case .login:
            "the Stripe CLI is not installed or not logged in — run: stripe login, then start it from its row"
        }
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
