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

    /// The fix that the fix sheet shows. Nil when the sheet is closed.
    var activeFix: FixRun?

    /// Runs the commands of the checks and the fixes.
    private let commandRunner: any CommandRunning
    private let tools: ToolEnvironment
    /// The time stamps of a fix, and the waits of a fix that polls its check.
    private let clock: RunnerClock

    /// A check command that hangs fails after this time.
    nonisolated static let checkTimeout: Duration = .seconds(20)
    /// An install of packages or of a tool stops after this time.
    nonisolated static let installTimeout: Duration = .seconds(15 * 60)
    /// Another fix that runs a command (the hotel download) stops after this time.
    nonisolated static let fixTimeout: Duration = .seconds(20 * 60)
    /// A fix that waits for the person (`stripe login`) or for an app checks again this often.
    nonisolated static let fixPollInterval: Duration = .seconds(3)
    /// How long the runner waits for `stripe login` in Terminal.
    nonisolated static let stripeLoginWait: Duration = .seconds(3 * 60)
    /// How long the runner waits for the container app to accept connections.
    nonisolated static let containerRuntimeWait: Duration = .seconds(60)

    init(
        monorepoPath: String, loginPath: String, streamServicesPath: String, flavor: Flavor = .current,
        shell: any CommandRunning = LoginShell(), tools: ToolEnvironment = .shared, clock: RunnerClock = .live
    ) {
        self.commandRunner = shell
        self.tools = tools
        self.clock = clock
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
        ToolVersion.parse(output)
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
    /// `failure` is the text of a fix that failed, nil when the fix succeeded.
    nonisolated static func pnpmStatusAfterFix(recheck: CheckStatus, failure: String?, firstOnPath: String?) -> CheckStatus {
        guard case .failing(let detail) = recheck else { return recheck }
        if detail.hasPrefix("v"), let firstOnPath, !firstOnPath.isEmpty {
            return .failing("\(detail). Another pnpm is first on the PATH: \(firstOnPath) — remove it, then re-check")
        }
        return statusAfterFix(recheck: recheck, failure: failure)
    }

    /// The result of a row after its fix ran: a check that passes now passes, whatever the
    /// fix returned. Otherwise a failed fix shows why it failed.
    nonisolated static func statusAfterFix(recheck: CheckStatus, failure: String?) -> CheckStatus {
        if case .passing = recheck { return recheck }
        return failure.map(CheckStatus.failing) ?? recheck
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
                        fixLabel: "How to install",
                        checkCommand: "node --version",
                        checkDescription: "Next.js 16 requires Node.js 22 or higher"),
            HealthCheck(id: "pnpm", name: "pnpm \(pnpmMajor)", section: .prerequisites,
                        fixLabel: "Install pnpm \(pnpmMajor)",
                        checkCommand: "pnpm --version",
                        checkDescription: "The monorepo pins pnpm \(pnpmPin ?? "\(pnpmMajor)") (packageManager in package.json). The check runs in the monorepo."),
            HealthCheck(id: "python-jwt", name: "Python 3 + PyJWT", section: .prerequisites,
                        isRequired: false, fixLabel: "Install PyJWT",
                        checkCommand: "python3 -c 'import jwt'",
                        checkDescription: "Optional — this checkout is from before the .env dump scripts, and its contract data copy (copy-remote-data.py) still needs PyJWT. A newer checkout does not."),
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
                        fixLabel: "Add missing keys",
                        checkCommand: "grep ALLOW_LOCALHOST_REDIRECTS .env.local",
                        checkDescription: "Must contain ALLOW_LOCALHOST_REDIRECTS=true for the local auth flow. The runner adds the local Supabase keys when it starts the login. The fix adds only the keys that are missing, keeps your values, and saves a copy of the file first.",
                        checkPath: (loginPath as NSString).appendingPathComponent(".env.local")),
            HealthCheck(id: "hotel-data", name: "Hotel data cached", section: .supabase,
                        isRequired: false, fixLabel: "Download hotels",
                        checkCommand: "ls \(ShellQuote.quote(DbSetupRunner.hotelDumpPath()))",
                        checkDescription: "~200K hotel records cached locally. First db:setup pulls from remote (~3-5 min). Reused on subsequent runs. The fix downloads the file only; it does not reset the database. \(Self.hotelDataFixNeeds)",
                        checkPath: DbSetupRunner.hotelDumpPath()),

            // Optional
            HealthCheck(id: "sb-linked", name: "Supabase project linked", section: .optional,
                        isRequired: false, fixLabel: "Link Project",
                        checkCommand: "cat supabase/.temp/project-ref",
                        checkDescription: "Links to the remote Supabase project. Only needed for drift detection and pulling remote schema changes.",
                        checkPath: (monorepoPath as NSString).appendingPathComponent("supabase/.temp/project-ref")),
        ]
        if !Self.checkoutNeedsPyJWT(monorepo: monorepoPath) {
            checks.removeAll { $0.id == "python-jwt" }
        }
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

    /// True when the database scripts of the checkout still ask for PyJWT. The newer
    /// scripts sign the token with Node, and then the row is not shown.
    nonisolated static func checkoutNeedsPyJWT(monorepo: String) -> Bool {
        let path = (monorepo as NSString).appendingPathComponent("scripts/db/check-prerequisites.mjs")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return content.contains("PyJWT")
    }

    /// A Homebrew Python refuses a plain `pip install`, so the second try passes the flag for that.
    nonisolated static let pyJWTFixCommand =
        "python3 -m pip install --user pyjwt || python3 -m pip install --user --break-system-packages pyjwt"

    /// pnpm prints this when GitHub Packages rejects the token of `~/.npmrc`.
    nonisolated static let registryRejectedMarker = "ERR_PNPM_FETCH_401"
    nonisolated static let registryRejectedText =
        "GitHub Packages rejected your token — fix the 'GitHub Packages auth' row, then retry."

    /// What the hotel row adds to a failure: the download needs the stack.
    nonisolated static let hotelDataFixHint =
        "start the stack first (the download needs the local Supabase and the shared apps/booking-portal/.env), then retry"

    /// What a row and the fix sheet show when the command of a fix failed:
    /// "Fix failed (exit N): <last error line>".
    nonisolated static func fixFailedText(for checkID: String, result: CommandResult, timeout: Duration) -> String {
        let output = result.stdout + "\n" + result.stderr
        if output.contains(registryRejectedMarker) { return registryRejectedText }
        var text: String
        if result.timedOut {
            text = "Fix stopped after \(durationText(timeout)): it did not finish"
        } else if let line = lastErrorLine(result) {
            text = "Fix failed (exit \(result.exitCode)): \(line)"
        } else {
            text = "Fix failed (exit \(result.exitCode))"
        }
        if checkID == "hotel-data" { text += " — \(hotelDataFixHint)" }
        return text
    }

    /// The last line of the error output that has text, or of the output when the error output has none.
    nonisolated static func lastErrorLine(_ result: CommandResult) -> String? {
        func last(_ text: String) -> String? {
            text.components(separatedBy: .newlines).reversed()
                .map { TerminalLineBuffer.stripAnsiEscapes($0).trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
        }
        guard let line = last(result.stderr) ?? last(result.stdout) else { return nil }
        return line.count > 200 ? String(line.prefix(200)) + "…" : line
    }

    /// "15 min" or "20 s".
    nonisolated static func durationText(_ duration: Duration) -> String {
        let seconds = duration.components.seconds
        return seconds >= 60 && seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
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

    /// "Re-check All": reads the shell of the user again, then runs the checks. A
    /// tool that was installed a moment ago, or a new line in `~/.zshrc`, counts.
    func recheckAll() async {
        await tools.resolve(runner: commandRunner)
        await runAllChecks()
    }

    /// Runs the fix of a check. A fix that runs something shows it in the fix sheet
    /// (`activeFix`): its output, the time, Cancel. Then the check runs again.
    /// One fix runs at a time.
    func fix(_ checkID: String) async {
        guard let check = checks.first(where: { $0.id == checkID }),
              let action = fixAction(for: checkID) else { return }
        if let activeFix, activeFix.isRunning { return }

        switch action {
        case .guidance:
            activeFix = FixRun(checkID: checkID, checkName: check.name, action: action, startedAt: clock.date(), state: .guidance)
            return
        case .importFile:
            check.status = .fixing
            let imported = await runImport(checkID)
            let recheck = await runCheck(checkID)
            // Nil: the developer cancelled and nothing changed.
            check.status = imported == false
                ? Self.statusAfterFix(recheck: recheck, failure: "Import failed — the file was not copied")
                : recheck
            return
        default:
            break
        }

        check.status = .fixing
        let run = FixRun(checkID: checkID, checkName: check.name, action: action, startedAt: clock.date())
        activeFix = run
        let task = Task { await self.perform(action, checkID: checkID, run: run) }
        run.task = task
        let outcome = await task.value
        run.finish(outcome, at: clock.date())

        // The check runs again outside the task of the fix, so a cancel does not stop it.
        let failure: String? = if case .failed(let text) = outcome { text } else { nil }
        let recheck = await runCheck(checkID)
        if checkID == "pnpm" {
            // The fix can add pnpm to a folder that only a new shell has on its PATH.
            await tools.resolve(runner: commandRunner)
            let (path, _) = await shellOutput("command -v pnpm")
            check.status = Self.pnpmStatusAfterFix(
                recheck: recheck, failure: failure,
                firstOnPath: path.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else {
            check.status = Self.statusAfterFix(recheck: recheck, failure: failure)
        }
    }

    /// Closes the fix sheet. A fix that still runs keeps the sheet.
    func closeFixSheet() {
        if let activeFix, activeFix.isRunning { return }
        activeFix = nil
    }

    // MARK: - Check implementations

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    /// The command of a check was killed after the timeout. `label` is the short
    /// form of the command that the row shows.
    private struct CheckTimedOut: Error {
        let label: String
    }

    /// The status of one check. A command that hangs says so on its row: it is
    /// not "not installed" and not "not found". A required check fails; an
    /// optional one warns.
    private func runCheck(_ id: String) async -> CheckStatus {
        do {
            return try await status(of: id)
        } catch {
            let label = (error as? CheckTimedOut)?.label ?? "The check"
            let isRequired = checks.first { $0.id == id }?.isRequired ?? true
            return Self.timedOutStatus(label: label, isRequired: isRequired)
        }
    }

    nonisolated static func timedOutStatus(label: String, isRequired: Bool) -> CheckStatus {
        let text = Shell.timeoutText(label, after: checkTimeout)
        return isRequired ? .failing(text) : .warning(text)
    }

    private func status(of id: String) async throws -> CheckStatus {
        switch id {
        case "docker":
            let runtime = ContainerRuntime.detect()
            let result = try await check("docker ps >/dev/null 2>&1", label: "docker ps")
            return result.succeeded ? .passing(runtime.displayName) : .failing("\(runtime.displayName) not responding")

        case "node":
            let result = try await check("node --version", label: "node --version")
            let (output, ok) = (result.stdout, result.succeeded)
            if !ok { return .failing("Node.js not found") }
            let version = output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "")
            if let major = Int(version.split(separator: ".").first ?? "0"), major >= 22 {
                return .passing("v\(version)")
            }
            return .failing("v\(version) — need 22+")

        case "pnpm":
            let result = try await check(Self.pnpmCheckCommand(monorepo: monorepoPath), label: "pnpm --version")
            return Self.pnpmStatus(output: result.stdout, ok: result.succeeded, pin: Self.pnpmPin(monorepo: monorepoPath))

        case "python-jwt":
            let ok = try await check("python3 -c 'import jwt' 2>/dev/null", label: "python3 -c 'import jwt'").succeeded
            return ok ? .passing("Installed") : .warning("Not installed — only monolith checkouts from before the .env dump script need it")

        case "registry-auth":
            let ok = try await check(
                "grep -q '^//npm.pkg.github.com/:_authToken=.' ~/.npmrc 2>/dev/null", label: "grep ~/.npmrc"
            ).succeeded
            return ok ? .passing("Configured") : .failing("No token in ~/.npmrc — see the description")

        case "stripe-cli":
            let ok = try await check("which stripe >/dev/null 2>&1", label: "which stripe").succeeded
            return ok ? .passing("Found") : .warning("Not installed — webhooks won't work")

        case "stripe-auth":
            let result = try await check("stripe balance retrieve >/dev/null 2>&1", label: "stripe balance retrieve")
            return result.succeeded ? .passing("Authenticated") : .warning("Session invalid or expired — run: stripe login")

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
            let result = try await check(
                SharedEnvFiles.command(monorepo: monorepoPath, app: app), label: "The check of the .env file"
            )
            return SharedEnvFiles.status(SharedEnvFiles.decode(result.stdout, app: app))

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
            // The dump of the app, or one still in the checkout: the next fetch moves it.
            let cached = exists(DbSetupRunner.hotelDumpPath())
                || exists(DbSetupRunner.checkoutHotelDumpPath(root: monorepoPath))
            return cached ? .passing("Cached") : .warning("Not cached — will be slow on first db:setup")

        case "sb-linked":
            let path = (monorepoPath as NSString).appendingPathComponent("supabase/.temp/project-ref")
            return exists(path) ? .passing("Linked") : .warning("Not linked — needed for remote sync only")

        case "agent-node":
            let minimum = ServiceCatalog.agentNodeMajor
            let result = try await check("node --version", label: "node --version")
            let (output, ok) = (result.stdout, result.succeeded)
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
    /// The dump goes where the DB setup of the app looks for it.
    nonisolated static var hotelDataFixCommand: String {
        "TRAVEL_HOTEL_DUMP=\(ShellQuote.quote(DbSetupRunner.hotelDumpPath())) pnpm db:hotels"
    }
    /// `pnpm db:hotels` stops when one of these is absent.
    nonisolated static let hotelDataFixNeeds = "The fix needs the local Supabase running and the shared apps/booking-portal/.env."

    /// The command that opens Terminal with `command` in a new window.
    nonisolated static func terminalCommand(_ command: String) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "osascript -e \(ShellQuote.quote("tell application \"Terminal\" to do script \"\(escaped)\""))"
    }

    nonisolated static let nodeGuidance = "Install Node 22: `brew install node@22` or `nvm install 22`"

    /// What the fix button of a check does. Nil when the check has no fix.
    /// No fix resets the database or replaces a file without a copy.
    func fixAction(for id: String) -> FixAction? {
        func inFolder(_ folder: String, _ command: String) -> String {
            "cd \(ShellQuote.quote(folder)) && \(command)"
        }
        switch id {
        case "docker":
            return .navigate(app: ContainerRuntime.detect().appName, waitFor: Self.containerRuntimeWait)
        case "node":
            return .guidance(
                text: Self.nodeGuidance, copyCommand: "brew install node@22",
                url: URL(string: "https://nodejs.org/en/download")
            )
        case "pnpm":
            return .command(Self.pnpmFixCommand(pin: Self.pnpmPin(monorepo: monorepoPath), monorepo: monorepoPath), timeout: Self.installTimeout)
        case "python-jwt":
            return .command(Self.pyJWTFixCommand, timeout: Self.installTimeout)
        case "stripe-auth":
            return .terminal(command: "stripe login", waitFor: Self.stripeLoginWait)
        case "workspace-modules":
            return .command(inFolder(monorepoPath, "pnpm install --frozen-lockfile"), timeout: Self.installTimeout)
        case "login-modules":
            return .command(inFolder(loginPath, "npm install"), timeout: Self.installTimeout)
        case "stream-modules":
            return .command(inFolder(streamServicesPath, "npm install"), timeout: Self.installTimeout)
        case "booking-env", "partner-env", "platform-env", "event-env", "agent-env":
            return .importFile
        case "login-env":
            return .inApp
        case "hotel-data":
            return .command(inFolder(monorepoPath, Self.hotelDataFixCommand), timeout: Self.fixTimeout)
        case "agent-node":
            return .command("brew install node@\(ServiceCatalog.agentNodeMajor)", timeout: Self.installTimeout)
        case "sb-linked":
            let script = (monorepoPath as NSString).appendingPathComponent("scripts/setup/link-project.sh")
            return .command(inFolder(monorepoPath, "bash \(ShellQuote.quote(script))"), timeout: Self.fixTimeout)
        default:
            return nil
        }
    }

    /// The work of a fix that shows the sheet. It runs in the task that Cancel stops.
    private func perform(_ action: FixAction, checkID: String, run: FixRun) async -> FixRun.State {
        switch action {
        case .command(let command, let timeout):
            run.append("$ \(command)")
            let result = await streamCommand(command, timeout: timeout, into: run)
            if Task.isCancelled { return .cancelled }
            return result.succeeded
                ? .succeeded
                : .failed(Self.fixFailedText(for: checkID, result: result, timeout: timeout))

        case .terminal(let command, let waitFor):
            let opened = await runCommand(Self.terminalCommand(command))
            if Task.isCancelled { return .cancelled }
            guard opened.succeeded else {
                return .failed(Self.fixFailedText(for: checkID, result: opened, timeout: Self.checkTimeout))
            }
            run.append("Opened Terminal: \(command)")
            run.append("Finish it in Terminal. Travel Runner checks again every \(Self.durationText(Self.fixPollInterval)) for \(Self.durationText(waitFor)).")
            return await waitForCheck(
                checkID, upTo: waitFor,
                notDone: "Not done after \(Self.durationText(waitFor)) — finish `\(command)` in Terminal, then re-check"
            )

        case .navigate(let app, let waitFor):
            let opened = await runCommand("open -a \(ShellQuote.quote(app))")
            if Task.isCancelled { return .cancelled }
            guard opened.succeeded else {
                return .failed(Self.fixFailedText(for: checkID, result: opened, timeout: Self.checkTimeout))
            }
            run.append("Opened \(app). Waiting for it to accept connections…")
            return await waitForCheck(
                checkID, upTo: waitFor,
                notDone: "\(app) did not answer in \(Self.durationText(waitFor)) — wait for it to start, then re-check"
            )

        case .inApp:
            return performInApp(checkID, run: run)

        case .importFile, .guidance:
            return .succeeded
        }
    }

    /// Runs a command and gives each line of its output to the sheet, in order.
    private func streamCommand(_ command: String, timeout: Duration, into run: FixRun) async -> CommandResult {
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        let reader = Task { @MainActor in
            for await line in lines { run.append(line) }
        }
        let result = await commandRunner.run(command, cwd: commandCwd, environment: [:], timeout: timeout) { line, _ in
            continuation.yield(line)
        }
        continuation.finish()
        await reader.value
        return result
    }

    /// Runs the check again every `fixPollInterval` until it passes or `limit` is over.
    private func waitForCheck(_ checkID: String, upTo limit: Duration, notDone: String) async -> FixRun.State {
        let deadline = clock.uptime() + limit
        while clock.uptime() < deadline {
            do {
                try await clock.sleep(for: Self.fixPollInterval)
            } catch {
                return .cancelled
            }
            if case .passing = await runCheck(checkID) { return .succeeded }
            if Task.isCancelled { return .cancelled }
        }
        return .failed(notDone)
    }

    private func performInApp(_ checkID: String, run: FixRun) -> FixRun.State {
        guard checkID == "login-env" else { return .failed("This check has no fix") }
        let path = (loginPath as NSString).appendingPathComponent(".env.local")
        do {
            let report = try Self.addMissingLoginEnvKeys(at: path, now: clock.date())
            if let backup = report.backup { run.append("Saved a copy: \(backup)") }
            run.append(report.added.isEmpty
                ? "Every key is there. Nothing was changed."
                : "Added: \(report.added.joined(separator: ", "))")
            if !report.kept.isEmpty {
                run.append("Kept your values: \(report.kept.joined(separator: ", ")). Set them as below by hand if sign-in fails:")
                for key in report.kept {
                    if let value = Self.loginEnvTemplate.first(where: { $0.key == key })?.value { run.append("  \(key)=\(value)") }
                }
            }
            return .succeeded
        } catch {
            return .failed("Fix failed: \(error.localizedDescription)")
        }
    }

    /// Runs the import of a check. Nil when the developer cancelled and nothing changed.
    private func runImport(_ id: String) async -> Bool? {
        switch id {
        case "booking-env": await importSharedEnv(.booking)
        case "partner-env": await importSharedEnv(.partner)
        case "platform-env": importPlatformCoreEnv()
        case "event-env": importEventDirectoryEnv()
        case "agent-env": importAgentEnv()
        default: false
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
    nonisolated static let loginEnvTemplate: [(key: String, value: String)] = [
        ("NEXT_PUBLIC_SITE_URL", "http://localhost:3000"),
        ("NEXT_PUBLIC_AMATEUR_LOCAL_UNIVERSAL_LOGIN_URL", "http://localhost:3000"),
        ("ALLOW_LOCALHOST_REDIRECTS", "true"),
        ("EMAIL_CONFIRMATION_REQUIRED", "false"),
    ]

    struct LoginEnvReport: Equatable, Sendable {
        /// The name of the copy of the file, or nil when nothing was copied.
        var backup: String?
        /// The keys the fix wrote.
        var added: [String]
        /// The keys of the template that the file sets to another value. They stay.
        var kept: [String]
    }

    /// Adds the keys of `loginEnvTemplate` that the file does not set. A key that is
    /// there keeps its value. Before it changes a file, it copies it to
    /// `.env.local.bak-<timestamp>` next to it. A missing file is created.
    nonisolated static func addMissingLoginEnvKeys(at path: String, now: Date) throws -> LoginEnvReport {
        let fileManager = FileManager.default
        let content = fileManager.fileExists(atPath: path) ? try String(contentsOfFile: path, encoding: .utf8) : nil
        let values = content.map { AgentEnv.parse($0, dialect: .node) } ?? [:]
        let missing = loginEnvTemplate.filter { values[$0.key] == nil }
        let kept = loginEnvTemplate.compactMap { pair in
            values[pair.key].flatMap { $0 == pair.value ? nil : pair.key }
        }
        guard !missing.isEmpty else { return LoginEnvReport(backup: nil, added: [], kept: kept) }

        var backup: String?
        if content != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let base = "\(path).bak-\(formatter.string(from: now))"
            var target = base
            var counter = 2
            while fileManager.fileExists(atPath: target) {
                target = "\(base)-\(counter)"
                counter += 1
            }
            try fileManager.copyItem(atPath: path, toPath: target)
            backup = (target as NSString).lastPathComponent
        }
        let added = try EnvCompatLayer(envFilePaths: [path]).addMissing(missing)
        return LoginEnvReport(backup: backup, added: added, kept: kept)
    }

    /// The folder of the commands: the `.nvmrc` of the monorepo picks the Node,
    /// as it does for the services. Nil before the folder exists.
    private var commandCwd: String? {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: monorepoPath, isDirectory: &isDirectory) && isDirectory.boolValue
            ? monorepoPath : nil
    }

    /// One command of a check. The checks and the fixes get the PATH that the
    /// services get (see `ToolEnvironment`).
    private func runCommand(_ command: String, timeout: Duration = EnvironmentChecker.checkTimeout) async -> CommandResult {
        await commandRunner.run(command, cwd: commandCwd, timeout: timeout)
    }

    /// The command of a check. It throws when the command was killed after the timeout.
    private func check(_ command: String, label: String) async throws -> CommandResult {
        let result = await runCommand(command)
        if result.timedOut { throw CheckTimedOut(label: label) }
        return result
    }

    private func shellOutput(_ command: String) async -> (String, Bool) {
        let result = await runCommand(command)
        return (result.stdout, result.succeeded)
    }
}
