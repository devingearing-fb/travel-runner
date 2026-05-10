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
    let portalPath: String
    let loginPath: String
    let travelDataPath: String

    private(set) var checks: [HealthCheck] = []

    init(portalPath: String, loginPath: String, travelDataPath: String) {
        self.portalPath = NSString(string: portalPath).expandingTildeInPath
        self.loginPath = NSString(string: loginPath).expandingTildeInPath
        self.travelDataPath = NSString(string: travelDataPath).expandingTildeInPath
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
            HealthCheck(id: "python-jwt", name: "Python 3 + PyJWT", section: .prerequisites,
                        fixLabel: "pip3 install pyjwt",
                        checkCommand: "python3 -c 'import jwt'",
                        checkDescription: "Required by the contract data copy script (copy-remote-data.py)"),
            HealthCheck(id: "yalc", name: "yalc CLI", section: .prerequisites,
                        fixLabel: "npm i -g yalc",
                        checkCommand: "which yalc",
                        checkDescription: "Local package linking (replaces npm link which breaks Turbopack)"),
            HealthCheck(id: "stripe-cli", name: "Stripe CLI", section: .prerequisites,
                        isRequired: false,
                        checkCommand: "which stripe",
                        checkDescription: "Optional — needed only for webhook/payment testing"),
            HealthCheck(id: "stripe-auth", name: "Stripe CLI Auth", section: .prerequisites,
                        isRequired: false, fixLabel: "stripe login",
                        checkCommand: "stripe config --list",
                        checkDescription: "Optional — Stripe CLI must be authenticated to forward webhook events"),
            HealthCheck(id: "npmrc", name: ".npmrc (GitHub Packages)", section: .prerequisites,
                        checkCommand: "cat .npmrc",
                        checkDescription: "Auth token for @fastbreak-amateur scoped packages on GitHub Packages",
                        checkPath: (portalPath as NSString).appendingPathComponent(".npmrc")),

            // Dependencies
            HealthCheck(id: "portal-modules", name: "Portal node_modules", section: .dependencies,
                        fixLabel: "npm install",
                        checkCommand: "ls node_modules/",
                        checkDescription: "npm dependencies for travel-booking-portal",
                        checkPath: (portalPath as NSString).appendingPathComponent("node_modules")),
            HealthCheck(id: "login-modules", name: "Login node_modules", section: .dependencies,
                        fixLabel: "npm install",
                        checkCommand: "ls node_modules/",
                        checkDescription: "npm dependencies for universal-login",
                        checkPath: (loginPath as NSString).appendingPathComponent("node_modules")),
            HealthCheck(id: "td-built", name: "fb-travel-data built", section: .dependencies,
                        fixLabel: "npm run build",
                        checkCommand: "ls dist/",
                        checkDescription: "fb-travel-data must be built (tsup → dist/) before yalc publish",
                        checkPath: (travelDataPath as NSString).appendingPathComponent("dist")),

            // Supabase & Database
            HealthCheck(id: "migration-link", name: "Migration symlink", section: .supabase,
                        fixLabel: "Create Symlink",
                        checkCommand: "readlink supabase/migrations",
                        checkDescription: "Portal's supabase/migrations/ must symlink to fb-travel-data/supabase/migrations/",
                        checkPath: (portalPath as NSString).appendingPathComponent("supabase/migrations")),
            HealthCheck(id: "portal-env", name: "Portal .env.local", section: .supabase,
                        fixLabel: "Run db:setup",
                        checkCommand: "grep LOCAL_SUPABASE_ANON_KEY .env.local",
                        checkDescription: "Must contain Supabase anon key, service role key, JWT secret, and login URL. Created by npm run db:setup.",
                        checkPath: (portalPath as NSString).appendingPathComponent(".env.local")),
            HealthCheck(id: "login-env", name: "Login .env.local", section: .supabase,
                        fixLabel: "Create from template",
                        checkCommand: "grep ALLOW_LOCALHOST_REDIRECTS .env.local",
                        checkDescription: "Must contain Supabase URL/keys and ALLOW_LOCALHOST_REDIRECTS=true for local auth flow",
                        checkPath: (loginPath as NSString).appendingPathComponent(".env.local")),
            HealthCheck(id: "hotel-data", name: "Hotel data cached", section: .supabase,
                        isRequired: false, fixLabel: "Run db:setup",
                        checkCommand: "ls data/travel_organizations.sql",
                        checkDescription: "~200K hotel records cached locally. First db:setup pulls from remote (~3-5 min). Reused on subsequent runs.",
                        checkPath: (portalPath as NSString).appendingPathComponent("data/travel_organizations.sql")),

            // Optional
            HealthCheck(id: "sb-linked", name: "Supabase project linked", section: .optional,
                        isRequired: false, fixLabel: "Link Project",
                        checkCommand: "cat supabase/.temp/project-ref",
                        checkDescription: "Links to remote Supabase project (ulpkcpnqrqgepwytyodd). Only needed for db:sync, drift detection, and pulling remote schema changes.",
                        checkPath: (portalPath as NSString).appendingPathComponent("supabase/.temp/project-ref")),
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

        case "python-jwt":
            let ok = await shell("python3 -c 'import jwt' 2>/dev/null")
            return ok ? .passing("Installed") : .failing("Run: pip3 install pyjwt")

        case "yalc":
            let ok = await shell("which yalc >/dev/null 2>&1")
            return ok ? .passing("Found") : .failing("Not installed")

        case "stripe-cli":
            let ok = await shell("which stripe >/dev/null 2>&1")
            return ok ? .passing("Found") : .warning("Not installed — webhooks won't work")

        case "stripe-auth":
            let ok = await shell("stripe config --list >/dev/null 2>&1")
            return ok ? .passing("Authenticated") : .warning("Not authenticated — run: stripe login")

        case "npmrc":
            let path = (portalPath as NSString).appendingPathComponent(".npmrc")
            let exists = FileManager.default.fileExists(atPath: path)
            return exists ? .passing("Found") : .failing("Missing — copy from partner-portal")

        case "portal-modules":
            let path = (portalPath as NSString).appendingPathComponent("node_modules")
            let exists = FileManager.default.fileExists(atPath: path)
            return exists ? .passing("Installed") : .failing("Run npm install")

        case "login-modules":
            let path = (loginPath as NSString).appendingPathComponent("node_modules")
            let exists = FileManager.default.fileExists(atPath: path)
            return exists ? .passing("Installed") : .failing("Run npm install")

        case "td-built":
            let path = (travelDataPath as NSString).appendingPathComponent("dist")
            let exists = FileManager.default.fileExists(atPath: path)
            return exists ? .passing("Built") : .failing("Run npm run build")

        case "migration-link":
            let linkPath = (portalPath as NSString).appendingPathComponent("supabase/migrations")
            let fm = FileManager.default
            // Use attributesOfItem (lstat) which does NOT follow symlinks
            guard let attrs = try? fm.attributesOfItem(atPath: linkPath) else {
                return .failing("Missing — supabase/migrations/ does not exist")
            }
            let fileType = attrs[.type] as? FileAttributeType
            if fileType == .typeSymbolicLink {
                if let dest = try? fm.destinationOfSymbolicLink(atPath: linkPath) {
                    if dest.contains("fb-travel-data") {
                        return .passing("Symlink → fb-travel-data")
                    }
                    return .warning("Symlink exists but points to: \(dest)")
                }
                return .passing("Symlink exists")
            }
            if fileType == .typeDirectory {
                return .warning("Real directory (not a symlink) — changes won't sync from fb-travel-data")
            }
            return .failing("Missing")

        case "portal-env":
            let path = (portalPath as NSString).appendingPathComponent(".env.local")
            guard FileManager.default.fileExists(atPath: path) else {
                return .failing("Missing")
            }
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               content.contains("LOCAL_SUPABASE_ANON_KEY=ey") {
                return .passing("Configured")
            }
            return .warning("Exists but missing Supabase keys")

        case "login-env":
            let path = (loginPath as NSString).appendingPathComponent(".env.local")
            guard FileManager.default.fileExists(atPath: path) else {
                return .failing("Missing")
            }
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               content.contains("ALLOW_LOCALHOST_REDIRECTS=true") {
                return .passing("Configured")
            }
            return .warning("Exists but may be incomplete")

        case "hotel-data":
            let path = (portalPath as NSString).appendingPathComponent("data/travel_organizations.sql")
            let exists = FileManager.default.fileExists(atPath: path)
            return exists ? .passing("Cached") : .warning("Not cached — will be slow on first db:setup")

        case "sb-linked":
            let path = (portalPath as NSString).appendingPathComponent("supabase/.temp/project-ref")
            let exists = FileManager.default.fileExists(atPath: path)
            return exists ? .passing("Linked") : .warning("Not linked — needed for remote sync only")

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

        case "python-jwt":
            return await shell("pip3 install pyjwt")

        case "yalc":
            return await shell("npm i -g yalc")

        case "stripe-auth":
            // Can't run interactive login from here — open terminal
            _ = await shell("open -a Terminal")
            return false

        case "portal-modules":
            return await shellInDir(portalPath, "npm install")

        case "login-modules":
            return await shellInDir(loginPath, "npm install")

        case "td-built":
            return await shellInDir(travelDataPath, "npm run build")

        case "migration-link":
            let target = (travelDataPath as NSString).appendingPathComponent("supabase/migrations")
            let link = (portalPath as NSString).appendingPathComponent("supabase/migrations")
            _ = await shell("rm -rf '\(link)'")
            return await shell("ln -s '\(target)' '\(link)'")

        case "portal-env":
            return await shellInDir(portalPath, "npm run db:setup -- --skip-hotels")

        case "login-env":
            return createLoginEnvLocal()

        case "hotel-data":
            return await shellInDir(portalPath, "npm run db:setup -- --reset-only")

        case "sb-linked":
            let script = (portalPath as NSString).appendingPathComponent("scripts/setup/link-project.sh")
            return await shell("bash '\(script)'")

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
        await shell("cd '\(dir)' && \(command)")
    }
}
