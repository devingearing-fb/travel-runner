import AppKit
import Foundation

enum CheckSection: String, Sendable, CaseIterable {
    case prerequisites = "Prerequisites"
    case dependencies = "Project Dependencies"
    case supabase = "Supabase & Database"
    case optional = "Optional"
}

enum CheckStatus: Sendable, Equatable {
    case pending
    case passing(String)
    case failing(String)
    case warning(String)
    case fixing
}

@Observable
@MainActor
final class HealthCheck: Identifiable {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated let section: CheckSection
    nonisolated let isRequired: Bool
    nonisolated let fixLabel: String?
    nonisolated let checkCommand: String
    nonisolated let checkDescription: String
    nonisolated let checkPath: String?
    var status: CheckStatus = .pending

    nonisolated init(
        id: String, name: String, section: CheckSection,
        isRequired: Bool = true, fixLabel: String? = nil,
        checkCommand: String = "", checkDescription: String = "",
        checkPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.section = section
        self.isRequired = isRequired
        self.fixLabel = fixLabel
        self.checkCommand = checkCommand
        self.checkDescription = checkDescription
        self.checkPath = checkPath
    }
}

@Observable
@MainActor
final class EnvironmentChecker {
    let monorepoPath: String
    let loginPath: String
    let streamServicesPath: String
    let flavor: Flavor

    private var agentPath: String { (monorepoPath as NSString).appendingPathComponent(RepoDetector.agentDirectory) }
    private var eventDirectoryPath: String { (monorepoPath as NSString).appendingPathComponent(RepoDetector.eventDirectory) }
    private var platformCorePath: String { (monorepoPath as NSString).appendingPathComponent(RepoDetector.platformCoreDirectory) }
    private var bookingPath: String { (monorepoPath as NSString).appendingPathComponent("apps/booking-portal") }
    private var partnerPath: String { (monorepoPath as NSString).appendingPathComponent("apps/partner-portal") }

    private(set) var checks: [HealthCheck] = []

    init(monorepoPath: String, loginPath: String, streamServicesPath: String, flavor: Flavor = .current) {
        self.flavor = flavor
        self.monorepoPath = NSString(string: monorepoPath).expandingTildeInPath
        self.loginPath = NSString(string: loginPath).expandingTildeInPath
        self.streamServicesPath = NSString(string: streamServicesPath).expandingTildeInPath
    }

    /// False only when a required check fails. A warning does not block.
    var allRequiredPassing: Bool { blockers.isEmpty }

    /// The required checks that fail.
    var blockers: [HealthCheck] { Self.blockers(in: checks) }

    /// True when the wizard can finish without a question. See `unresolved(in:)`.
    var canFinish: Bool { unresolved.isEmpty }

    /// The required checks that fail or have no result yet.
    var unresolved: [HealthCheck] { Self.unresolved(in: checks) }

    static func blockers(in checks: [HealthCheck]) -> [HealthCheck] {
        checks.filter { check in
            guard check.isRequired, case .failing = check.status else { return false }
            return true
        }
    }

    /// The required checks that fail, or that a check or a fix still works on.
    /// An optional check is never here: it must not hold the wizard, also when it hangs.
    static func unresolved(in checks: [HealthCheck]) -> [HealthCheck] {
        checks.filter { check in
            guard check.isRequired else { return false }
            switch check.status {
            case .failing, .pending, .fixing: return true
            case .passing, .warning: return false
            }
        }
    }

    /// What does not work when a required check fails. Shown before "Continue anyway".
    nonisolated static func impact(of checkID: String) -> String? {
        switch checkID {
        case "docker": "the local database will not start"
        case "node": "the portals and the login will not run"
        case "pnpm": "installs and both portals will not run"
        case "python-jwt": "the contract data copy of the database setup will fail"
        case "registry-auth": "pnpm install cannot download the @fastbreak-amateur packages"
        case "workspace-modules": "both portals will not run"
        case "login-modules": "the login will not run"
        case "login-env": "sign-in on localhost will not work"
        default: nil
        }
    }

    /// One line per failing required check, for example "pnpm 10 — installs and both portals will not run".
    /// A check without a result says so: "Docker (check not finished) — if it fails, the local database will not start".
    static func impactLines(for checks: [HealthCheck]) -> [String] {
        checks.map { check in
            let impact = impact(of: check.id)
            switch check.status {
            case .pending, .fixing:
                let name = "\(check.name) (check not finished)"
                return impact.map { "\(name) — if it fails, \($0)" } ?? name
            default:
                return impact.map { "\(check.name) — \($0)" } ?? check.name
            }
        }
    }

    // MARK: - pnpm pin

    /// The pnpm major to ask for when package.json has no pin.
    nonisolated static let defaultPnpmMajor = 10

    /// The pnpm version that package.json pins: `"packageManager": "pnpm@10.34.5+sha512.…"` gives "10.34.5".
    nonisolated static func pnpmPin(packageJSON: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(packageJSON.utf8)) as? [String: Any],
              let manager = root["packageManager"] as? String,
              manager.hasPrefix("pnpm@") else { return nil }
        // The part after "+" is the hash of the package.
        let version = manager.dropFirst("pnpm@".count).prefix { $0 != "+" }
        return toolVersion(String(version))
    }

    nonisolated static func pnpmPin(monorepo: String) -> String? {
        let path = (monorepo as NSString).appendingPathComponent("package.json")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return pnpmPin(packageJSON: content)
    }

    /// The last line of the output that is only a version, without the "v". Other lines are notices.
    /// A prerelease such as "11.0.0-rc.1" is a version.
    nonisolated static func toolVersion(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.range(of: #"^v?\d+\.\d+(\.\d+)?(-[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil }
            .map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
    }

    nonisolated static func major(of version: String) -> Int? {
        version.split(separator: ".").first.flatMap { Int($0) }
    }

    /// The check prints this line when there is no pnpm on the PATH.
    nonisolated static let pnpmNotFoundMarker = "travel-runner: pnpm not found"

    /// The pnpm check passes when the major of `pnpm --version`, run in the monorepo, is the pinned major.
    nonisolated static func pnpmStatus(output: String, ok: Bool, pin: String?) -> CheckStatus {
        if output.contains(pnpmNotFoundMarker) { return .failing("Not installed") }
        guard ok, let version = toolVersion(output), let major = major(of: version) else {
            // pnpm is there but gave no version: in the monorepo it may have to download the pin first.
            let wanted = pin.map { "pnpm \($0)" } ?? "another version"
            return .failing("pnpm could not report its version in the monorepo (it may need to download \(wanted)) — check the network and re-run")
        }
        guard let pin, let pinnedMajor = Self.major(of: pin) else {
            return major == defaultPnpmMajor
                ? .passing("v\(version)")
                : .failing("v\(version) — need \(defaultPnpmMajor).x")
        }
        guard major == pinnedMajor else {
            return .failing("v\(version) — the monorepo pins \(pin)")
        }
        return version == pin
            ? .passing("v\(version) (pinned by the monorepo)")
            : .passing("v\(version) (the monorepo pins \(pin))")
    }

    /// The command of the pnpm check. In the monorepo, pnpm and corepack follow the pin.
    nonisolated static func pnpmCheckCommand(monorepo: String) -> String {
        "command -v pnpm >/dev/null 2>&1 || { echo '\(pnpmNotFoundMarker)'; exit 1; }; "
            + "cd \(ShellQuote.quote(monorepo)) 2>/dev/null; COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm --version"
    }

    /// Installs the pinned pnpm with the first tool that gives the pinned major in the monorepo: corepack, Homebrew, npm.
    /// A plain `brew install pnpm` gives the newest major, which the check does not accept.
    /// An install that exits 0 is not enough: another pnpm earlier on the PATH can still win. So each
    /// step but the last also asks pnpm for its version, and the next step runs when the major is wrong.
    nonisolated static func pnpmFixCommand(pin: String?, monorepo: String) -> String {
        let major = pin.flatMap(Self.major(of:)) ?? defaultPnpmMajor
        let version = pin ?? "\(major)"
        let verify = "(cd \(ShellQuote.quote(monorepo)) 2>/dev/null; COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm --version 2>/dev/null | grep -q '^\(major)\\.')"
        return [
            "(command -v corepack >/dev/null 2>&1 && corepack enable pnpm && corepack prepare pnpm@\(version) --activate && \(verify))",
            "(command -v brew >/dev/null 2>&1 && brew install pnpm@\(major) && brew link --overwrite --force pnpm@\(major) && \(verify))",
            "npm install -g pnpm@\(version)",
        ].joined(separator: " || ")
    }

    /// The result of the pnpm row after its fix ran. When pnpm still reports another version, the fix
    /// installed the pin but another pnpm comes first on the PATH: the row names that one.
    nonisolated static func pnpmStatusAfterFix(recheck: CheckStatus, fixSucceeded: Bool, firstOnPath: String?) -> CheckStatus {
        guard case .failing(let detail) = recheck else { return recheck }
        if detail.hasPrefix("v"), let firstOnPath, !firstOnPath.isEmpty {
            return .failing("\(detail). Another pnpm is first on the PATH: \(firstOnPath) — remove it, then re-check")
        }
        return fixSucceeded ? recheck : .failing("Fix failed — try manually")
    }

    func buildChecks() {
        let runtime = ContainerRuntime.detect()
        let pnpmPin = Self.pnpmPin(monorepo: monorepoPath)
        let pnpmMajor = pnpmPin.flatMap(Self.major(of:)) ?? Self.defaultPnpmMajor
        checks = [
            // Prerequisites
            HealthCheck(id: "docker", name: runtime.displayName, section: .prerequisites,
                        fixLabel: "Open \(runtime.appName)",
                        checkCommand: "docker ps",
                        checkDescription: "Verifies \(runtime.displayName) is running and accepting connections"),
            HealthCheck(id: "node", name: "Node.js 22+", section: .prerequisites,
                        checkCommand: "node --version",
                        checkDescription: "Next.js 16 requires Node.js 22 or higher"),
            HealthCheck(id: "pnpm", name: "pnpm \(pnpmMajor)", section: .prerequisites,
                        fixLabel: "Install pnpm \(pnpmMajor)",
                        checkCommand: "pnpm --version",
                        checkDescription: "The monorepo pins pnpm \(pnpmPin ?? "\(pnpmMajor)") (packageManager in package.json). The check runs in the monorepo."),
            HealthCheck(id: "python-jwt", name: "Python 3 + PyJWT", section: .prerequisites,
                        isRequired: false, fixLabel: "pip3 install pyjwt",
                        checkCommand: "python3 -c 'import jwt'",
                        checkDescription: "Optional — only the contract data copy script (copy-remote-data.py) needs it"),
            HealthCheck(id: "registry-auth", name: "GitHub Packages auth", section: .prerequisites,
                        checkCommand: "grep //npm.pkg.github.com/:_authToken ~/.npmrc",
                        checkDescription: "User-level token for @fastbreak-amateur packages. Set it once with: pnpm config set --location=user \"//npm.pkg.github.com/:_authToken\" <token>"),
            HealthCheck(id: "stripe-cli", name: "Stripe CLI", section: .prerequisites,
                        isRequired: false,
                        checkCommand: "which stripe",
                        checkDescription: "Optional — needed only for webhook/payment testing"),
            HealthCheck(id: "stripe-auth", name: "Stripe CLI Auth", section: .prerequisites,
                        isRequired: false, fixLabel: "stripe login",
                        checkCommand: "stripe config --list",
                        checkDescription: "Optional — Stripe CLI must be authenticated to forward webhook events"),

            // Dependencies
            HealthCheck(id: "workspace-modules", name: "Monorepo dependencies", section: .dependencies,
                        fixLabel: "pnpm install",
                        checkCommand: "ls node_modules/.modules.yaml",
                        checkDescription: "One pnpm install at the monorepo root covers both apps and travel-data",
                        checkPath: (monorepoPath as NSString).appendingPathComponent("node_modules/.modules.yaml")),
            HealthCheck(id: "login-modules", name: "Login node_modules", section: .dependencies,
                        fixLabel: "npm install",
                        checkCommand: "ls node_modules/",
                        checkDescription: "npm dependencies for universal-login",
                        checkPath: (loginPath as NSString).appendingPathComponent("node_modules")),
            HealthCheck(id: "stream-modules", name: "Stream Services node_modules", section: .dependencies,
                        isRequired: false, fixLabel: "npm install",
                        checkCommand: "ls node_modules/",
                        checkDescription: "Only for the full profile — pinned QStash CLI and stream-services dependencies",
                        checkPath: (streamServicesPath as NSString).appendingPathComponent("node_modules")),

            // Supabase & Database
            HealthCheck(id: "booking-env", name: "Booking .env (shared values)", section: .supabase,
                        isRequired: false, fixLabel: "Import…",
                        checkCommand: "pnpm env:check",
                        checkDescription: "apps/booking-portal/.env holds the shared dev values (Stripe, HotelPlanner, hosted Supabase…). Get it from a teammate and import it, or run pnpm env:pull with Doppler access. The runner writes local overrides into .env.local on top of it.",
                        checkPath: (bookingPath as NSString).appendingPathComponent(".env")),
            HealthCheck(id: "partner-env", name: "Partner .env (shared values)", section: .supabase,
                        isRequired: false, fixLabel: "Import…",
                        checkCommand: "pnpm env:check",
                        checkDescription: "apps/partner-portal/.env holds the shared dev values. Get it from a teammate and import it, or run pnpm env:pull with Doppler access.",
                        checkPath: (partnerPath as NSString).appendingPathComponent(".env")),
            HealthCheck(id: "backend-baseline", name: "Backend migration baseline", section: .supabase,
                        isRequired: false,
                        checkCommand: "ls ../fb-amateur-backend .backend-baseline",
                        checkDescription: "scripts/local-db.sh replays fb-amateur-backend's migrations. It uses a checkout beside the monorepo, or clones one into .backend-baseline/ on the first reset."),
            HealthCheck(id: "login-env", name: "Login .env.local", section: .supabase,
                        fixLabel: "Create from template",
                        checkCommand: "grep ALLOW_LOCALHOST_REDIRECTS .env.local",
                        checkDescription: "Must contain Supabase URL/keys and ALLOW_LOCALHOST_REDIRECTS=true for local auth flow",
                        checkPath: (loginPath as NSString).appendingPathComponent(".env.local")),
            HealthCheck(id: "hotel-data", name: "Hotel data cached", section: .supabase,
                        isRequired: false, fixLabel: "Download hotels",
                        checkCommand: "ls data/travel_organizations.sql",
                        checkDescription: "~200K hotel records cached locally. First db:setup pulls from remote (~3-5 min). Reused on subsequent runs. The fix downloads the file only; it does not reset the database.",
                        checkPath: (monorepoPath as NSString).appendingPathComponent("data/travel_organizations.sql")),

            // Optional
            HealthCheck(id: "sb-linked", name: "Supabase project linked", section: .optional,
                        isRequired: false, fixLabel: "Link Project",
                        checkCommand: "cat supabase/.temp/project-ref",
                        checkDescription: "Links to the remote Supabase project. Only needed for drift detection and pulling remote schema changes.",
                        checkPath: (monorepoPath as NSString).appendingPathComponent("supabase/.temp/project-ref")),
        ]
        if flavor.runsAgent { checks += agentChecks() }
    }

    /// The agent app of the hackathon fork. A failure here does not stop the portals.
    private func agentChecks() -> [HealthCheck] {
        let major = ServiceCatalog.agentNodeMajor
        return [
            HealthCheck(id: "agent-node", name: "Node.js \(major)+ (agent)", section: .prerequisites,
                        isRequired: false, fixLabel: "brew install node@\(major)",
                        checkCommand: "node --version",
                        checkDescription: "eve, the framework of the agent, needs Node \(major) or later. The runner looks for one from nvm, fnm, mise, Volta, asdf and Homebrew, and uses it only for the agent. The portals stay on your default Node."),
            HealthCheck(id: "agent-env", name: "Agent env", section: .supabase,
                        isRequired: false, fixLabel: "Import…",
                        checkCommand: "cat \(RepoDetector.agentDirectory)/.env.local",
                        checkDescription: "The agent needs AMATEUR_SUPABASE_URL, AMATEUR_SUPABASE_ANON_KEY and AMATEUR_SUPABASE_SIGNING_KEY, a model credential (\(AgentEnv.gatewayKey)), and for its event tools \(AgentEnv.pxiURLKey) and a Vercel token. For a value of these that its own files do not set, the runner gives the agent the value of the event directory's env, and a token of the event directory's Vercel project. Without a model credential in its files, that project pays for the model calls. For a Supabase key that \(RepoDetector.agentDirectory)/.env.local does not set, the runner gives the agent the value of apps/booking-portal/.env. The runner writes no file for the agent; Import… copies the env file of the agent that a teammate sent you into place.",
                        checkPath: (agentPath as NSString).appendingPathComponent(".env.local")),
            HealthCheck(id: "platform-env", name: "Platform core env", section: .supabase,
                        isRequired: false, fixLabel: "Import…",
                        checkCommand: "cat \(RepoDetector.platformCoreDirectory)/\(PlatformCoreApp.envFile(directory: platformCorePath))",
                        checkDescription: "Platform core needs its env file at \(RepoDetector.platformCoreDirectory)/\(PlatformCoreApp.envFile(directory: platformCorePath)), with \(PlatformCoreEnv.requiredKeys.joined(separator: " and ")). Get the file from a teammate: Import… copies it into place. The app uses the database and the login that this file names. The fork sets the port and the env file of the app in its script `\(PlatformCoreApp.script)`; the runner reads the two from there and writes no env for platform core.",
                        checkPath: (platformCorePath as NSString).appendingPathComponent(PlatformCoreApp.envFile(directory: platformCorePath))),
            HealthCheck(id: "event-env", name: "Event directory env", section: .supabase,
                        isRequired: false, fixLabel: "Import…",
                        checkCommand: "cat \(RepoDetector.eventDirectory)/.env.local",
                        checkDescription: "The event directory needs the env file of its Vercel project (`vercel env pull .env.local --environment=production` in \(RepoDetector.eventDirectory), or the file a teammate sent you: Import… copies it into place). The API token in that file stops after 12 hours. After that, the app gets a new one through your Vercel login (npx vercel login); the runner links the app to its Vercel project for that.",
                        checkPath: (eventDirectoryPath as NSString).appendingPathComponent(".env.local")),
        ]
    }

    func runAllChecks() async {
        for check in checks {
            check.status = .pending
        }
        await withTaskGroup(of: Void.self) { group in
            for check in checks {
                group.addTask { [self] in
                    let status = await self.runCheck(check.id)
                    await MainActor.run { check.status = status }
                }
            }
        }
    }

    func fix(_ checkID: String) async {
        guard let check = checks.first(where: { $0.id == checkID }) else { return }
        check.status = .fixing

        guard let success = await runFix(checkID) else {
            // Cancelled: nothing changed.
            check.status = await runCheck(checkID)
            return
        }
        if checkID == "pnpm" {
            let recheck = await runCheck(checkID)
            let (path, _) = await shellOutput("command -v pnpm")
            check.status = Self.pnpmStatusAfterFix(
                recheck: recheck, fixSucceeded: success,
                firstOnPath: path.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else if success {
            let newStatus = await runCheck(checkID)
            check.status = newStatus
        } else {
            check.status = .failing("Fix failed — try manually")
        }
    }

    // MARK: - Check implementations

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func runCheck(_ id: String) async -> CheckStatus {
        switch id {
        case "docker":
            let runtime = ContainerRuntime.detect()
            let ok = await shell("docker ps >/dev/null 2>&1")
            return ok ? .passing(runtime.displayName) : .failing("\(runtime.displayName) not responding")

        case "node":
            let (output, ok) = await shellOutput("node --version")
            if !ok { return .failing("Node.js not found") }
            let version = output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "")
            if let major = Int(version.split(separator: ".").first ?? "0"), major >= 22 {
                return .passing("v\(version)")
            }
            return .failing("v\(version) — need 22+")

        case "pnpm":
            let (output, ok) = await shellOutput(Self.pnpmCheckCommand(monorepo: monorepoPath))
            return Self.pnpmStatus(output: output, ok: ok, pin: Self.pnpmPin(monorepo: monorepoPath))

        case "python-jwt":
            let ok = await shell("python3 -c 'import jwt' 2>/dev/null")
            return ok ? .passing("Installed") : .warning("Not installed — only the contract data copy needs it")

        case "registry-auth":
            let ok = await shell("grep -q '^//npm.pkg.github.com/:_authToken=.' ~/.npmrc 2>/dev/null")
            return ok ? .passing("Configured") : .failing("No token in ~/.npmrc — see the description")

        case "stripe-cli":
            let ok = await shell("which stripe >/dev/null 2>&1")
            return ok ? .passing("Found") : .warning("Not installed — webhooks won't work")

        case "stripe-auth":
            let ok = await shell("stripe balance retrieve >/dev/null 2>&1")
            return ok ? .passing("Authenticated") : .warning("Session invalid or expired — run: stripe login")

        case "workspace-modules":
            let path = (monorepoPath as NSString).appendingPathComponent("node_modules/.modules.yaml")
            return exists(path) ? .passing("Installed") : .failing("Run pnpm install at the monorepo root")

        case "login-modules":
            let path = (loginPath as NSString).appendingPathComponent("node_modules")
            return exists(path) ? .passing("Installed") : .failing("Run npm install")

        case "stream-modules":
            let path = (streamServicesPath as NSString).appendingPathComponent("node_modules")
            return exists(path) ? .passing("Installed") : .warning("Run npm install (full profile only)")

        case "booking-env", "partner-env":
            let app: SharedEnvFiles.App = id == "booking-env" ? .booking : .partner
            let (output, _) = await shellOutput(SharedEnvFiles.command(monorepo: monorepoPath, app: app))
            return SharedEnvFiles.status(SharedEnvFiles.decode(output, app: app))

        case "backend-baseline":
            let sibling = ((monorepoPath as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("fb-amateur-backend")
            if exists(sibling) { return .passing("Sibling checkout") }
            let clone = (monorepoPath as NSString).appendingPathComponent(".backend-baseline")
            return exists(clone) ? .passing(".backend-baseline/") : .warning("Cloned on the first DB reset")

        case "login-env":
            let path = (loginPath as NSString).appendingPathComponent(".env.local")
            guard exists(path) else {
                return .failing("Missing")
            }
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               content.contains("ALLOW_LOCALHOST_REDIRECTS=true") {
                return .passing("Configured")
            }
            return .warning("Exists but may be incomplete")

        case "hotel-data":
            let path = (monorepoPath as NSString).appendingPathComponent("data/travel_organizations.sql")
            return exists(path) ? .passing("Cached") : .warning("Not cached — will be slow on first db:setup")

        case "sb-linked":
            let path = (monorepoPath as NSString).appendingPathComponent("supabase/.temp/project-ref")
            return exists(path) ? .passing("Linked") : .warning("Not linked — needed for remote sync only")

        case "agent-node":
            let minimum = ServiceCatalog.agentNodeMajor
            let (output, ok) = await shellOutput("node --version")
            if ok, let major = NodeLocator.major(ofVersionOutput: output), major >= minimum {
                return .passing("\(output.trimmingCharacters(in: .whitespacesAndNewlines)) (default)")
            }
            let installs = await Task.detached { NodeLocator.installs() }.value
            guard let install = NodeLocator.pick(installs, minimumMajor: minimum) else {
                return .warning("Not found — the agent is skipped. nvm install \(minimum), or brew install node@\(minimum)")
            }
            return .passing("v\(install.version.map(String.init).joined(separator: ".")) — used only for the agent")

        case "platform-env":
            guard exists((platformCorePath as NSString).appendingPathComponent("package.json")) else {
                return .warning("This checkout does not have \(RepoDetector.platformCoreDirectory) — pull the fork")
            }
            let directory = platformCorePath
            return await Task.detached {
                guard let launch = PlatformCoreApp.launch(directory: directory) else {
                    return CheckStatus.warning("\(RepoDetector.platformCoreDirectory) has no script `\(PlatformCoreApp.script)` — pull the fork")
                }
                let missing = PlatformCoreEnv.missingKeys(PlatformCoreEnv.values(directory: directory, envFiles: launch.envFiles))
                guard missing.isEmpty else {
                    return CheckStatus.warning("Not set: \(missing.joined(separator: ", ")) — platform core is skipped. Use Import…")
                }
                let port = launch.port.map { "port \($0)" } ?? "no port in its script"
                return CheckStatus.passing("The env of platform core is in place (\(port))")
            }.value

        case "event-env":
            guard exists((eventDirectoryPath as NSString).appendingPathComponent("package.json")) else {
                return .warning("This checkout does not have \(RepoDetector.eventDirectory) — pull the fork")
            }
            let directory = eventDirectoryPath
            return await Task.detached {
                let values = EventDirectoryEnv.values(directory: directory)
                let missing = EventDirectoryEnv.missingKeys(values)
                guard missing.isEmpty else {
                    return CheckStatus.warning("Not set: \(missing.joined(separator: ", ")) — the event directory is skipped. Use Import…")
                }
                let claims = EventDirectoryEnv.claims(ofToken: values[EventDirectoryEnv.tokenKey])
                // The runner writes the link at the start of the service, when the token names the project.
                let access = EventDirectoryEnv.access(
                    claims: claims,
                    linked: EventDirectoryEnv.isLinked(directory: directory) || claims != nil,
                    hasLogin: EventDirectoryEnv.hasVercelLogin()
                )
                let summary = EventDirectoryEnv.summary(access)
                return EventDirectoryEnv.isUsable(access) ? CheckStatus.passing(summary) : CheckStatus.warning(summary)
            }.value

        case "agent-env":
            let shared = (bookingPath as NSString).appendingPathComponent(".env")
            let agentPath = agentPath
            // Without its own values, the agent gets the PXI values of the event
            // directory's env, and the token of that app's Vercel project, at its start.
            let eventPath = eventDirectoryPath
            return await Task.detached {
                let event = EventDirectoryEnv.values(directory: eventPath)
                let plan = AgentEnv.withEventDirectoryValues(
                    AgentEnv.plan(agentDirectory: agentPath, sharedEnvFile: shared),
                    own: AgentEnv.ownValues(directory: agentPath),
                    event: event
                )
                let claims = EventDirectoryEnv.claims(ofToken: event[EventDirectoryEnv.tokenKey])
                let eventProjectUsable = EventDirectoryEnv.missingKeys(event).isEmpty
                    && (EventDirectoryEnv.isLinked(directory: eventPath) || claims != nil)
                    && EventDirectoryEnv.hasVercelLogin()
                let summary = AgentEnv.summary(plan, eventProjectUsable: eventProjectUsable)
                let hasModel = plan.hasModelCredential || eventProjectUsable
                let hasToken = plan.ownsProjectToken || eventProjectUsable
                let complete = plan.missing.isEmpty && hasModel && hasToken && !plan.pxiMissing
                return complete ? CheckStatus.passing(summary) : CheckStatus.warning(summary)
            }.value

        default:
            return .passing("OK")
        }
    }

    // MARK: - Fix implementations

    /// Downloads the hotel dump when it is missing. It never resets the database.
    nonisolated static let hotelDataFixCommand = "pnpm db:hotels"

    /// nil when the developer cancelled and nothing changed.
    private func runFix(_ id: String) async -> Bool? {
        switch id {
        case "docker":
            let runtime = ContainerRuntime.detect()
            _ = await shell("open -a '\(runtime.appName)'")
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(2))
                if await shell("docker ps >/dev/null 2>&1") { return true }
            }
            return false

        case "pnpm":
            return await shell(Self.pnpmFixCommand(pin: Self.pnpmPin(monorepo: monorepoPath), monorepo: monorepoPath))

        case "python-jwt":
            return await shell("pip3 install pyjwt")

        case "stripe-auth":
            // Can't run interactive login from here — open terminal
            _ = await shell("open -a Terminal")
            return false

        case "workspace-modules":
            return await shellInDir(monorepoPath, "pnpm install")

        case "login-modules":
            return await shellInDir(loginPath, "npm install")

        case "stream-modules":
            return await shellInDir(streamServicesPath, "npm install")

        case "booking-env":
            return await importSharedEnv(.booking)

        case "partner-env":
            return await importSharedEnv(.partner)

        case "login-env":
            return createLoginEnvLocal()

        case "hotel-data":
            return await shellInDir(monorepoPath, Self.hotelDataFixCommand)

        case "agent-node":
            return await shell("brew install node@\(ServiceCatalog.agentNodeMajor)")

        case "platform-env":
            return importPlatformCoreEnv()

        case "event-env":
            return importEventDirectoryEnv()

        case "agent-env":
            return importAgentEnv()

        case "sb-linked":
            let script = (monorepoPath as NSString).appendingPathComponent("scripts/setup/link-project.sh")
            return await shellInDir(monorepoPath, "bash \(ShellQuote.quote(script))")

        default:
            return false
        }
    }

    // MARK: - Helpers

    /// Copies a shared `.env` the developer picks into the monolith, after the monolith's
    /// env-check confirms it is this app's file. The runner keeps no copy.
    private func importSharedEnv(_ app: SharedEnvFiles.App) async -> Bool? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the \(app.label.lowercased()) portal .env a teammate sent you (their \(app.directory)/.env)"
        panel.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return nil }

        let (output, _) = await shellOutput(SharedEnvFiles.command(monorepo: monorepoPath, app: app, file: source.path))
        let alert = NSAlert()
        alert.window.level = .floating
        guard let report = SharedEnvFiles.decode(output, app: app) else {
            alert.messageText = "Could not check the file"
            alert.informativeText = "\(SharedEnvFiles.script) did not run. Pull the latest monorepo dev and try again."
            alert.runModal()
            return false
        }
        let target = ((monorepoPath as NSString).appendingPathComponent(app.directory) as NSString).appendingPathComponent(".env")
        let prompt = SharedEnvFiles.importPrompt(report, app: app, replacing: exists(target))
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        guard prompt.acceptable else {
            alert.runModal()
            return nil
        }
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        do {
            let data = try Data(contentsOf: source)
            try data.write(to: URL(fileURLWithPath: target), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
            return true
        } catch {
            return false
        }
    }

    /// Copies the env file of platform core that the developer picks to the file that
    /// the app's script reads (`apps/platform-core/.env.dev`), after a check that it
    /// is that app's file.
    private func importPlatformCoreEnv() -> Bool? {
        importEnvFile(
            appName: "platform core",
            message: "Choose the env file of platform core (for example the .env.dev a teammate sent you)",
            directory: platformCorePath,
            relativeFolder: RepoDetector.platformCoreDirectory,
            fileName: PlatformCoreApp.envFile(directory: platformCorePath),
            problem: PlatformCoreEnv.importProblem
        )
    }

    /// Copies the env file of the event directory that the developer picks to
    /// `apps/event-directory/.env.local`, after a check that it is that app's file.
    private func importEventDirectoryEnv() -> Bool? {
        importEnvFile(
            appName: "the event directory",
            message: "Choose the env file of the event directory (the file of `vercel env pull`, for example env.local)",
            directory: eventDirectoryPath,
            relativeFolder: RepoDetector.eventDirectory
        ) { values in
            let missing = EventDirectoryEnv.missingKeys(values)
            return missing.isEmpty ? nil : "It does not set \(missing.joined(separator: " and "))."
        }
    }

    /// Copies the env file of the agent that the developer picks to
    /// `apps/amateur-agent/.env.local`, after a check that it is that app's file.
    private func importAgentEnv() -> Bool? {
        importEnvFile(
            appName: "the agent",
            message: "Choose the env file of the agent (for example app/amateur-agent/.env.local of the file a teammate sent you)",
            directory: agentPath,
            relativeFolder: RepoDetector.agentDirectory,
            problem: AgentEnv.importProblem
        )
    }

    /// Asks for a file, checks with `problem` that it is the env of the app, and
    /// copies it to `fileName` of the app's folder. Returns nil when nothing changed.
    private func importEnvFile(
        appName: String,
        message: String,
        directory: String,
        relativeFolder: String,
        fileName: String = ".env.local",
        problem: ([String: String]) -> String?
    ) -> Bool? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = message
        panel.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return nil }

        let alert = NSAlert()
        alert.window.level = .floating
        guard let content = try? String(contentsOf: source, encoding: .utf8) else {
            alert.messageText = "Could not read the file"
            alert.runModal()
            return false
        }
        if let problem = problem(AgentEnv.parse(content, dialect: .node)) {
            alert.messageText = "This is not the env of \(appName)"
            alert.informativeText = "\(source.lastPathComponent): \(problem) Nothing was changed."
            alert.runModal()
            return nil
        }
        let target = (directory as NSString).appendingPathComponent(fileName)
        alert.messageText = exists(target) ? "Replace the env of \(appName)?" : "Import the env of \(appName)?"
        alert.informativeText = "\(source.lastPathComponent) goes to \(relativeFolder)/\(fileName)."
        alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        do {
            try Data(content.utf8).write(to: URL(fileURLWithPath: target), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
            return true
        } catch {
            return false
        }
    }

    /// The login's non-Supabase local values. The runner adds the local stack's Supabase keys
    /// (from scripts/local-db.sh status) when it starts the login, so none are written here.
    private func createLoginEnvLocal() -> Bool {
        let content = """
        NEXT_PUBLIC_SITE_URL=http://localhost:3000
        NEXT_PUBLIC_AMATEUR_LOCAL_UNIVERSAL_LOGIN_URL=http://localhost:3000
        ALLOW_LOCALHOST_REDIRECTS=true
        EMAIL_CONFIRMATION_REQUIRED=false

        """

        let path = (loginPath as NSString).appendingPathComponent(".env.local")
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private func shell(_ command: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { p in continuation.resume(returning: p.terminationStatus == 0) }
            do { try process.run() } catch { continuation.resume(returning: false) }
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

    private func shellInDir(_ dir: String, _ command: String) async -> Bool {
        await shell("cd \(ShellQuote.quote(dir)) && \(command)")
    }
}
