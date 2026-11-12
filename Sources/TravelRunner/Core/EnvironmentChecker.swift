import AppKit
import Foundation

enum CheckSection: String, Sendable, CaseIterable {
    case prerequisites = "Prerequisites"
    case dependencies = "Project Dependencies"
    case supabase = "Supabase & Database"
    case optional = "Optional"
}

enum CheckStatus: Sendable {
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
    private var bookingPath: String { (monorepoPath as NSString).appendingPathComponent("apps/booking-portal") }
    private var partnerPath: String { (monorepoPath as NSString).appendingPathComponent("apps/partner-portal") }

    private(set) var checks: [HealthCheck] = []

    init(monorepoPath: String, loginPath: String, streamServicesPath: String, flavor: Flavor = .current) {
        self.flavor = flavor
        self.monorepoPath = NSString(string: monorepoPath).expandingTildeInPath
        self.loginPath = NSString(string: loginPath).expandingTildeInPath
        self.streamServicesPath = NSString(string: streamServicesPath).expandingTildeInPath
    }

    var allRequiredPassing: Bool {
        checks.filter(\.isRequired).allSatisfy {
            if case .passing = $0.status { return true }
            return false
        }
    }

    func buildChecks() {
        let runtime = ContainerRuntime.detect()
        checks = [
            // Prerequisites
            HealthCheck(id: "docker", name: runtime.displayName, section: .prerequisites,
                        fixLabel: "Open \(runtime.appName)",
                        checkCommand: "docker ps",
                        checkDescription: "Verifies \(runtime.displayName) is running and accepting connections"),
            HealthCheck(id: "node", name: "Node.js 22+", section: .prerequisites,
                        checkCommand: "node --version",
                        checkDescription: "Next.js 16 requires Node.js 22 or higher"),
            HealthCheck(id: "pnpm", name: "pnpm 10", section: .prerequisites,
                        fixLabel: "brew install pnpm",
                        checkCommand: "pnpm --version",
                        checkDescription: "The monorepo pins pnpm 10 (packageManager in package.json)"),
            HealthCheck(id: "python-jwt", name: "Python 3 + PyJWT", section: .prerequisites,
                        fixLabel: "pip3 install pyjwt",
                        checkCommand: "python3 -c 'import jwt'",
                        checkDescription: "Required by the contract data copy script (copy-remote-data.py)"),
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
                        isRequired: false, fixLabel: "Run db:setup",
                        checkCommand: "ls data/travel_organizations.sql",
                        checkDescription: "~200K hotel records cached locally. First db:setup pulls from remote (~3-5 min). Reused on subsequent runs.",
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
                        isRequired: false,
                        checkCommand: "cat \(RepoDetector.agentDirectory)/.env.local",
                        checkDescription: "The agent needs AMATEUR_SUPABASE_URL, AMATEUR_SUPABASE_ANON_KEY and AMATEUR_SUPABASE_SIGNING_KEY, and a model credential (\(AgentEnv.gatewayKey)). Without a model credential in its files, the agent gets the token of the event directory's Vercel project, and that project pays for the model calls. For a Supabase key that \(RepoDetector.agentDirectory)/.env.local does not set, the runner gives the agent the value of apps/booking-portal/.env. The runner writes no file for the agent.",
                        checkPath: (agentPath as NSString).appendingPathComponent(".env.local")),
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
        if success {
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
            let (output, ok) = await shellOutput("pnpm --version")
            if !ok { return .failing("Not installed") }
            let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return version.hasPrefix("10.") ? .passing("v\(version)") : .failing("v\(version) — need 10.x")

        case "python-jwt":
            let ok = await shell("python3 -c 'import jwt' 2>/dev/null")
            return ok ? .passing("Installed") : .failing("Run: pip3 install pyjwt")

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
            let plan = AgentEnv.plan(agentDirectory: agentPath, sharedEnvFile: shared)
            // Without a credential in a file, the runner gives the agent the token of
            // the event directory's Vercel project at the start of the agent.
            let eventPath = eventDirectoryPath
            let eventProjectUsable = await Task.detached {
                let values = EventDirectoryEnv.values(directory: eventPath)
                guard EventDirectoryEnv.missingKeys(values).isEmpty else { return false }
                let claims = EventDirectoryEnv.claims(ofToken: values[EventDirectoryEnv.tokenKey])
                return (EventDirectoryEnv.isLinked(directory: eventPath) || claims != nil)
                    && EventDirectoryEnv.hasVercelLogin()
            }.value
            let summary = AgentEnv.summary(plan, eventProjectUsable: eventProjectUsable)
            let hasModel = plan.hasModelCredential || eventProjectUsable
            return plan.missing.isEmpty && hasModel ? .passing(summary) : .warning(summary)

        default:
            return .passing("OK")
        }
    }

    // MARK: - Fix implementations

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
            return await shell("brew install pnpm")

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
            return await shellInDir(monorepoPath, "pnpm db:setup:reset")

        case "agent-node":
            return await shell("brew install node@\(ServiceCatalog.agentNodeMajor)")

        case "event-env":
            return importEventDirectoryEnv()

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

    /// Copies the env file of the event directory that the developer picks to
    /// `apps/event-directory/.env.local`, after a check that it is that app's file.
    private func importEventDirectoryEnv() -> Bool? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "Choose the env file of the event directory (the file of `vercel env pull`, for example env.local)"
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
        let missing = EventDirectoryEnv.missingKeys(AgentEnv.parse(content, dialect: .node))
        guard missing.isEmpty else {
            alert.messageText = "This is not the env of the event directory"
            alert.informativeText = "\(source.lastPathComponent) does not set \(missing.joined(separator: " and ")). Nothing was changed."
            alert.runModal()
            return nil
        }
        let target = (eventDirectoryPath as NSString).appendingPathComponent(".env.local")
        alert.messageText = exists(target) ? "Replace the env of the event directory?" : "Import the env of the event directory?"
        alert.informativeText = "\(source.lastPathComponent) goes to \(RepoDetector.eventDirectory)/.env.local."
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
