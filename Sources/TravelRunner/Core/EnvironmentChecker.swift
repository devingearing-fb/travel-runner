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

    private var bookingPath: String { (monorepoPath as NSString).appendingPathComponent("apps/booking-portal") }
    private var partnerPath: String { (monorepoPath as NSString).appendingPathComponent("apps/partner-portal") }

    private(set) var checks: [HealthCheck] = []

    init(monorepoPath: String, loginPath: String, streamServicesPath: String) {
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
            HealthCheck(id: "doppler", name: "Doppler CLI", section: .prerequisites,
                        isRequired: false,
                        checkCommand: "doppler me",
                        checkDescription: "Pulls the shared dev values into apps/*/.env (pnpm env:pull). Log in once with: doppler login"),

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
            HealthCheck(id: "app-env", name: "App .env files (Doppler)", section: .supabase,
                        isRequired: false, fixLabel: "pnpm env:pull",
                        checkCommand: "ls apps/booking-portal/.env apps/partner-portal/.env",
                        checkDescription: "Shared dev values from Doppler. travel-runner writes the local overrides into .env.local on top of them.",
                        checkPath: (bookingPath as NSString).appendingPathComponent(".env")),
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

        let success = await runFix(checkID)
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

        case "doppler":
            if !(await shell("which doppler >/dev/null 2>&1")) { return .warning("Not installed — brew install dopplerhq/cli/doppler") }
            let ok = await shell("doppler me >/dev/null 2>&1")
            return ok ? .passing("Logged in") : .warning("Not logged in — run: doppler login")

        case "workspace-modules":
            let path = (monorepoPath as NSString).appendingPathComponent("node_modules/.modules.yaml")
            return exists(path) ? .passing("Installed") : .failing("Run pnpm install at the monorepo root")

        case "login-modules":
            let path = (loginPath as NSString).appendingPathComponent("node_modules")
            return exists(path) ? .passing("Installed") : .failing("Run npm install")

        case "stream-modules":
            let path = (streamServicesPath as NSString).appendingPathComponent("node_modules")
            return exists(path) ? .passing("Installed") : .warning("Run npm install (full profile only)")

        case "app-env":
            let missing = [bookingPath, partnerPath]
                .filter { !exists(($0 as NSString).appendingPathComponent(".env")) }
                .map { ($0 as NSString).lastPathComponent }
            return missing.isEmpty ? .passing("Pulled") : .warning("Missing for \(missing.joined(separator: ", ")) — run pnpm env:pull")

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

        default:
            return .passing("OK")
        }
    }

    // MARK: - Fix implementations

    private func runFix(_ id: String) async -> Bool {
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

        case "app-env":
            return await shellInDir(monorepoPath, "pnpm env:pull")

        case "login-env":
            return createLoginEnvLocal()

        case "hotel-data":
            return await shellInDir(monorepoPath, "pnpm db:setup:reset")

        case "sb-linked":
            let script = (monorepoPath as NSString).appendingPathComponent("scripts/setup/link-project.sh")
            return await shellInDir(monorepoPath, "bash \(ShellQuote.quote(script))")

        default:
            return false
        }
    }

    // MARK: - Helpers

    private func createLoginEnvLocal() -> Bool {
        let anonKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0"
        let jwtSecret = "super-secret-jwt-token-with-at-least-32-characters-long"

        let content = """
        NEXT_PUBLIC_SUPABASE_URL=http://localhost:54321
        NEXT_PUBLIC_SUPABASE_ANON_KEY=\(anonKey)
        NEXT_PUBLIC_SITE_URL=http://localhost:3000
        NEXT_PUBLIC_AMATEUR_LOCAL_UNIVERSAL_LOGIN_URL=http://localhost:3000
        AMATEUR_SUPABASE_URL=http://localhost:54321
        AMATEUR_SUPABASE_ANON_KEY=\(anonKey)
        AMATEUR_SUPABASE_SIGNING_KEY=\(jwtSecret)
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
