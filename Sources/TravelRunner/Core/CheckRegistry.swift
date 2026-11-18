import Foundation

/// What a check costs to run. The preflight of a start runs only the fast ones.
enum CheckCost: String, Sendable {
    /// Reads a file, or runs a local command that answers at once.
    case fast
    /// Asks the network, or runs a script that can take seconds.
    case slow
}

/// What a failure of a check stops.
enum CheckSeverity: String, Sendable {
    /// Start All cannot work: a failure fails the preflight.
    case blocksStart
    /// The setup needs it. A part of the stack does not work, but the start runs.
    case required
    /// An optional part is off.
    case optional
}

/// The one list of setup checks. The rows of Health, the wizard's Environment
/// Check and the preflight of a start are the same checks: each id has its cost,
/// its severity, what fails without it, and the profiles it applies to.
/// `EnvironmentChecker` runs them.
enum CheckRegistry {
    /// Each command of a check in the preflight stops after this time. The checks
    /// run in parallel, so the preflight waits about this long at most.
    static let preflightLimit: Duration = .seconds(3)

    /// The time limit of each command of a check in this task. The preflight of a
    /// start sets `preflightLimit`; Health and the wizard keep `EnvironmentChecker.checkTimeout`.
    @TaskLocal static var commandLimit: Duration = EnvironmentChecker.checkTimeout

    /// The checks that the preflight runs as its own start step, with the service
    /// graph: it opens the container runtime, and it asks for the backend clone
    /// only when the stack starts the database.
    static let startSteps: Set<String> = ["docker", "backend-baseline"]

    /// The checks whose failure stops Start All.
    static let blocksStart: Set<String> = ["docker", "node"]

    /// The checks that ask the network or run a script that can take seconds.
    static let slow: Set<String> = [
        // `pnpm --version` in the monorepo can download the pinned pnpm first.
        "pnpm",
        "registry-auth",
        "stripe-auth",
        // The booking row reads the hotel dump with `fetch-hotels.mjs --verify`.
        "booking-env",
        "partner-env",
        "backend-baseline",
        "hotel-data",
    ]

    static let bookingProfiles: Set<RunProfile> = [.booking, .both, .full]
    static let partnerProfiles: Set<RunProfile> = [.partner, .both, .full]

    /// The profiles of a check. Nil: every profile.
    static func profiles(of id: String) -> Set<RunProfile>? {
        switch id {
        case "stripe-cli", "stripe-auth", "booking-env": bookingProfiles
        case "partner-env": partnerProfiles
        case "stream-modules": [.full]
        default: nil
        }
    }

    static func cost(of id: String) -> CheckCost {
        slow.contains(id) ? .slow : .fast
    }

    static func severity(of id: String, isRequired: Bool) -> CheckSeverity {
        if blocksStart.contains(id) { return .blocksStart }
        return isRequired ? .required : .optional
    }

    /// What does not work when the check fails.
    static func impact(of id: String) -> String? {
        switch id {
        case "docker": "the local database will not start"
        case "folder-access": "the runner cannot read the checkout, so nothing will start"
        case "node": "the portals and the login will not run"
        case "pnpm": "installs and both portals will not run"
        case "python-jwt": "the database setup of this checkout stops at its first step"
        case "registry-auth": "pnpm install cannot download the @fastbreak-amateur packages"
        case "stripe-cli", "stripe-auth": "Stripe webhooks do not reach the booking portal"
        case "workspace-modules": "both portals will not run"
        case "login-modules": "the login will not run"
        case "stream-modules": "the stream services of the full profile will not run"
        case "login-env": "sign-in on localhost will not work"
        case "booking-env": "the first reset cannot download the hotels"
        case "partner-env": "remote mode of the partner portal has no hosted values"
        case "backend-baseline": "a database reset cannot replay the backend migrations"
        case "hotel-data": "a reset has no hotels to load"
        case "sb-linked": "drift detection and remote schema pulls do not work"
        case "agent-node", "agent-env": "the agent is skipped"
        case "platform-env": "platform core is skipped"
        case "event-env": "the event directory is skipped"
        default: nil
        }
    }

    /// The checks that the preflight of a start runs: the fast checks of the
    /// profile that the setup needs. An optional check is left out: its own
    /// service says why it skips. A check of a folder that is not set is left out.
    @MainActor
    static func preflightSubset(of checks: [HealthCheck], profile: RunProfile) -> [HealthCheck] {
        checks.filter { check in
            check.cost == .fast
                && check.severity != .optional
                && check.applies(to: profile)
                && !startSteps.contains(check.id)
                && (check.checkPath.map { $0.hasPrefix("/") } ?? true)
        }
    }

    /// The setup items that need attention for this profile: a check that fails,
    /// and a warning of a check that the setup needs.
    @MainActor
    static func needsAttention(_ checks: [HealthCheck], profile: RunProfile) -> [HealthCheck] {
        checks.filter { check in
            guard check.applies(to: profile) else { return false }
            switch check.status {
            case .failing: return true
            case .warning: return check.isRequired
            case .passing, .pending, .fixing: return false
            }
        }
    }

    /// The Status banner: "3 setup items need attention — Open Health".
    static func attentionText(count: Int) -> String {
        count == 1
            ? "1 setup item needs attention — Open Health"
            : "\(count) setup items need attention — Open Health"
    }

    /// A check of the registry as a row of the preflight. Only a check that
    /// blocks the start fails it; any other problem warns.
    static func preflightResult(_ status: CheckStatus, severity: CheckSeverity, fixLabel: String?) -> PreflightResult {
        switch status {
        case .passing(let detail):
            return .passed(detail: detail)
        case .warning(let message):
            return .warning(message: message)
        case .failing(let message):
            guard severity == .blocksStart else { return .warning(message: message) }
            return .failed(message: message, fix: fixLabel.map { "Open Health → \($0)" } ?? "Open Health")
        case .pending, .fixing:
            return .warning(message: "Not checked")
        }
    }
}

/// The Node that the monorepo asks for, from `engines.node` in its package.json.
/// The Health row and the preflight use this one threshold.
enum NodeRequirement {
    /// The major to ask for when package.json names none.
    static let defaultMinimum = 22

    /// The lowest major that a range allows: ">=22" and "^22.11.0" give 22,
    /// "20 || 22" gives 20. An upper bound ("<23") and a minor or patch do not count.
    static func minimumMajor(engines: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(<=?|>=?|\^|~|=)?\s*v?(?<![\d.])(\d+)"#) else { return nil }
        let range = NSRange(engines.startIndex..., in: engines)
        let majors = regex.matches(in: engines, range: range).compactMap { match -> Int? in
            let op = Range(match.range(at: 1), in: engines).map { String(engines[$0]) } ?? ""
            if op.hasPrefix("<") { return nil }
            return Range(match.range(at: 2), in: engines).flatMap { Int(engines[$0]) }
        }
        return majors.min()
    }

    /// `engines.node` of the monorepo's package.json, or nil.
    static func engines(monorepo: String) -> String? {
        let path = (monorepo as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let engines = root["engines"] as? [String: Any] else { return nil }
        return engines["node"] as? String
    }

    static func minimumMajor(monorepo: String) -> Int {
        engines(monorepo: monorepo).flatMap(minimumMajor(engines:)) ?? defaultMinimum
    }

    /// The row of `node --version`. A login profile can print lines first
    /// ("Now using node v22.3.0"): the version is the last line that is only a version.
    static func status(_ result: CommandResult, minimum: Int) -> CheckStatus {
        guard let version = ToolVersion.parse(result.stdout) else {
            let printed = result.trimmedOutput
            if printed.isEmpty || result.exitCode == 127 {
                return .failing("Node.js not found")
            }
            // Something answered (nvm: "N/A version is not installed"): show what it said.
            let lastLine = printed.components(separatedBy: .newlines).last ?? printed
            return .failing("node --version printed no version: \(lastLine)")
        }
        guard let major = EnvironmentChecker.major(of: version), major >= minimum else {
            return .failing("v\(version) — need \(minimum)+")
        }
        return .passing("v\(version)")
    }
}
