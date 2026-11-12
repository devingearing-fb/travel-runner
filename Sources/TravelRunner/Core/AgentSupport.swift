import Foundation

/// Finds a Node.js that can run the agent. eve needs Node 24 or later; the rest
/// of the fork is on Node 22, so the default `node` of many people is too old.
enum NodeLocator {
    struct Install: Equatable, Sendable {
        let version: [Int]
        let binDirectory: String

        var major: Int { version.first ?? 0 }
    }

    /// The version in a folder name: `v24.3.0`, `24.3.0` or `node@24`.
    static func version(fromName name: String) -> [Int]? {
        var text = name
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if text.hasPrefix("v") { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    /// The major version in the output of `node --version`.
    static func major(ofVersionOutput output: String) -> Int? {
        version(fromName: output.trimmingCharacters(in: .whitespacesAndNewlines))?.first
    }

    /// Where the version managers and Homebrew keep their Node versions:
    /// the folder of the versions, and the path from one version to its `bin`.
    static func searchRoots(home: String) -> [(directory: String, binPath: String)] {
        [
            ("\(home)/.nvm/versions/node", "bin"),
            ("\(home)/.local/share/fnm/node-versions", "installation/bin"),
            ("\(home)/Library/Application Support/fnm/node-versions", "installation/bin"),
            ("\(home)/.local/share/mise/installs/node", "bin"),
            ("\(home)/.volta/tools/image/node", "bin"),
            ("\(home)/.asdf/installs/nodejs", "bin"),
            ("/opt/homebrew/opt", "bin"),
            ("/usr/local/opt", "bin"),
        ]
    }

    /// Each Node on this Mac that has a `node` program.
    static func installs(home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> [Install] {
        var found: [Install] = []
        for root in searchRoots(home: home) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: root.directory) else { continue }
            let isHomebrew = root.directory.hasSuffix("/opt")
            for name in names.sorted() {
                // Homebrew's folder holds every formula: only `node@<major>` is a Node.
                if isHomebrew, !name.hasPrefix("node@") { continue }
                guard let version = version(fromName: name) else { continue }
                let bin = "\(root.directory)/\(name)/\(root.binPath)"
                guard fileManager.isExecutableFile(atPath: "\(bin)/node") else { continue }
                found.append(Install(version: version, binDirectory: bin))
            }
        }
        return found
    }

    /// The Node to use: the newest of the lowest major version that is new enough.
    /// The agent's `.nvmrc` names that major, so it is the version the app expects.
    static func pick(_ installs: [Install], minimumMajor: Int) -> Install? {
        let usable = installs.filter { $0.major >= minimumMajor }
        guard let major = usable.map(\.major).min() else { return nil }
        return usable.filter { $0.major == major }.max { $0.version.lexicographicallyPrecedes($1.version) }
    }

    /// `command` with this Node first in PATH. The login shell sets PATH before the
    /// command runs, so the change must be in the command itself.
    static func command(_ command: [String], nodeBin: String) -> [String] {
        ["/bin/sh", "-c", #"PATH="$1:$PATH"; export PATH; shift; exec "$@""#, "sh", nodeBin] + command
    }
}

/// The env of the agent app.
///
/// The agent has no shared `.env` of its own. It needs the same `AMATEUR_SUPABASE_*`
/// values as the portals, and a credential for the model. The runner writes no file
/// for the agent. For a key that the agent's own files do not set, the runner gives
/// the process the value of the booking portal's shared `.env`. eve keeps a value
/// of the process over the value of a file.
enum AgentEnv {
    static let supabaseKeys = ["AMATEUR_SUPABASE_URL", "AMATEUR_SUPABASE_ANON_KEY", "AMATEUR_SUPABASE_SIGNING_KEY"]
    static let signingKey = "AMATEUR_SUPABASE_SIGNING_KEY"
    static let gatewayKey = "AI_GATEWAY_API_KEY"
    /// `eve link` writes this token; it is a model credential too.
    static let oidcKey = "VERCEL_OIDC_TOKEN"

    /// The files that `eve dev` reads in the app folder, the strongest first.
    static let fileNames = [".env.development.local", ".env.local", ".env.development", ".env"]

    enum Dialect {
        /// As eve reads its files (`util.parseEnv` of Node): a double-quoted value
        /// stops at the next double quote, also at an escaped one.
        case node
        /// As Doppler writes the shared `.env`: `\"` and `\\` in a double-quoted value
        /// are escapes.
        case shared
    }

    /// The assignments of a dotenv file. A later line of a key replaces an earlier one.
    static func parse(_ content: String, dialect: Dialect) -> [String: String] {
        var values: [String: String] = [:]
        for line in content.components(separatedBy: .newlines) {
            guard let key = RunnerEnv.assignedKey(line), let eq = line.firstIndex(of: "=") else { continue }
            let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            values[key] = value(of: raw, dialect: dialect)
        }
        return values
    }

    private static func value(of raw: String, dialect: Dialect) -> String {
        guard let quote = raw.first, quote == "\"" || quote == "'" || quote == "`" else {
            // Not quoted: a comment starts at " #".
            let end = raw.range(of: " #")?.lowerBound ?? raw.endIndex
            return raw[..<end].trimmingCharacters(in: .whitespaces)
        }
        var result = ""
        var index = raw.index(after: raw.startIndex)
        while index < raw.endIndex {
            let character = raw[index]
            if character == quote { break }
            let next = raw.index(after: index)
            if character == "\\", quote == "\"", next < raw.endIndex {
                let escaped = raw[next]
                if escaped == "n" {
                    result.append("\n")
                    index = raw.index(after: next)
                    continue
                }
                if dialect == .shared, escaped == "\"" || escaped == "\\" {
                    result.append(escaped)
                    index = raw.index(after: next)
                    continue
                }
            }
            result.append(character)
            index = next
        }
        return result
    }

    /// What eve gets from the files of the agent folder.
    static func ownValues(directory: String) -> [String: String] {
        var values: [String: String] = [:]
        for name in fileNames.reversed() {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            values.merge(parse(content, dialect: .node)) { _, stronger in stronger }
        }
        return values
    }

    /// The values of the booking portal's shared `.env`.
    static func sharedValues(file: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: file, encoding: .utf8) else { return [:] }
        return parse(content, dialect: .shared)
    }

    /// False for an empty value, and for a signing key that looks like a JSON key
    /// but is not JSON. That is the Doppler line pasted into `.env.local`: eve reads
    /// only `{\` from it.
    static func isUsable(_ value: String?, key: String) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return false }
        guard key == signingKey, value.hasPrefix("{") else { return true }
        return (try? JSONSerialization.jsonObject(with: Data(value.utf8))) is [String: Any]
    }

    struct Plan: Equatable, Sendable {
        /// Values that the runner gives the process, from the shared `.env`.
        var passthrough: [String: String] = [:]
        /// Supabase keys that no file sets.
        var missing: [String] = []
        /// True when a file gives a credential for the model.
        var hasModelCredential = false
        /// True when the agent's own signing key is one that eve cannot read.
        var ownSigningKeyUnreadable = false
        /// Set when the model credential is the token of the event directory's
        /// Vercel project (`withProjectToken`).
        var modelProject: ModelProject?
        /// True when the agent has its own `VERCEL_OIDC_TOKEN` that is good, or can get
        /// one itself (project link and Vercel login). The runner then gives it none.
        var ownsProjectToken = false
        /// True when the token of the agent's own files stopped (or stops soon), and
        /// the agent cannot get a new one itself.
        var ownTokenStale = false
        /// True when no file gives the agent the address of the PXI API.
        var pxiMissing = false
        /// Set when the runner gives the agent the token of the event directory's project.
        var projectTokenUntil: Date?
        /// The keys that the runner takes from the env of the event directory.
        var eventDirectoryKeys: [String] = []
    }

    /// The agent reads the event data of the event directory (PXI). These are the
    /// agent's keys for that, and the key of the event directory's env with the value.
    static let eventDirectorySources: [(agentKey: String, eventKey: String)] = [
        ("PXI_API_URL", "PXI_API_URL"),
        ("NEXT_PUBLIC_REGISTRATION_BASE_URL", "NEXT_PUBLIC_REGISTRATION_BASE_URL"),
        ("MAPBOX_ACCESS_TOKEN", "NEXT_PUBLIC_MAPBOX_ACCESS_TOKEN"),
    ]
    static let pxiURLKey = "PXI_API_URL"

    /// For a PXI key that the agent's own files do not set, the runner gives the agent
    /// the value of the event directory's env. The runner does not set
    /// `EVENT_DIRECTORY_ORIGIN`: without it the agent makes relative links, which work
    /// on each host of the event directory (localhost, the LAN address).
    static func withEventDirectoryValues(_ plan: Plan, own: [String: String], event: [String: String]) -> Plan {
        var plan = plan
        func isSet(_ value: String?) -> Bool { !(value ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        for (agentKey, eventKey) in eventDirectorySources where !isSet(own[agentKey]) && isSet(event[eventKey]) {
            plan.passthrough[agentKey] = event[eventKey]
            plan.eventDirectoryKeys.append(agentKey)
        }
        plan.pxiMissing = !isSet(own[pxiURLKey]) && plan.passthrough[pxiURLKey] == nil
        return plan
    }

    /// Why a file is not an env of the agent, for Import…; nil when it is one.
    /// The env of the event directory is refused: it has none of the agent's own keys,
    /// and the runner already gives the agent the values of that file.
    static func importProblem(_ values: [String: String]) -> String? {
        func isSet(_ key: String) -> Bool { !(values[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        let ownKeys = supabaseKeys + [gatewayKey]
        if ownKeys.contains(where: isSet) { return nil }
        if isSet("SITE_URL") {
            return "It is the env of the event directory. Import it on the row of the event directory; "
                + "the runner gives the agent the values that it needs from that file."
        }
        return "It sets none of \(ownKeys.joined(separator: ", "))."
    }

    /// True when `@vercel/oidc` finds a Vercel project link from this folder. As the
    /// library does, it walks up to the first folder with `.vercel`, and that folder
    /// must have `project.json`.
    static func hasProjectLink(from directory: String) -> Bool {
        var current = (directory as NSString).standardizingPath
        while true {
            let folder = (current as NSString).appendingPathComponent(".vercel")
            if FileManager.default.fileExists(atPath: folder) {
                return FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent("project.json"))
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return false }
            current = parent
        }
    }

    /// True when a token of the agent's own files cannot work: it stopped (or stops
    /// soon), and the agent cannot get a new one itself. Text that is not a Vercel
    /// token is not judged.
    static func isStaleToken(_ value: String?, canRefresh: Bool, now: Date) -> Bool {
        guard !canRefresh,
              let claims = EventDirectoryEnv.claims(ofToken: value?.trimmingCharacters(in: .whitespacesAndNewlines)),
              let until = claims.expiresAt else { return false }
        return until.timeIntervalSince(now) < minimumTokenLife
    }

    /// The Vercel project whose token pays for the model calls of the agent.
    struct ModelProject: Equatable, Sendable {
        var name: String?
        var until: Date
    }

    /// A token must be good for this long, or the runner does not use it.
    static let minimumTokenLife: TimeInterval = 600
    /// The app's library gets a new token when the one it has stops sooner than this.
    static let tokenRefreshBufferMs = 6 * 60 * 60 * 1000

    /// The shell command that prints a token of the event directory's Vercel project.
    /// It uses the library of that app (`@vercel/oidc`), which reads the project link
    /// and the Vercel login of this Mac, and gets a new token when the old one stops soon.
    static func projectTokenCommand(eventDirectory: String) -> String {
        let quoted = "'" + eventDirectory.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        let script = "setTimeout(()=>process.exit(2),20000).unref();"
            + #"import("@vercel/oidc").then(m=>m.getVercelOidcToken({expirationBufferMs:\#(tokenRefreshBufferMs)}))"#
            + ".then(t=>process.stdout.write(t)).catch(()=>process.exit(1))"
        return "cd \(quoted) && node -e '\(script)'"
    }

    /// Gives the agent the token that `projectTokenCommand` printed, when the agent's
    /// own files give no `VERCEL_OIDC_TOKEN`. The agent uses the token for the event
    /// data (PXI). eve also uses it for the AI Gateway, when no file gives the agent a
    /// model credential. The agent cannot get a new token by itself (it has no project
    /// link), so the token must have some life left.
    static func withProjectToken(_ plan: Plan, commandOutput: String, now: Date = Date()) -> Plan {
        guard !plan.ownsProjectToken else { return plan }
        let token = commandOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let claims = EventDirectoryEnv.claims(ofToken: token),
              let until = claims.expiresAt,
              until.timeIntervalSince(now) >= minimumTokenLife else { return plan }
        var plan = plan
        plan.passthrough[oidcKey] = token
        plan.projectTokenUntil = until
        if !plan.hasModelCredential {
            plan.hasModelCredential = true
            plan.modelProject = ModelProject(name: claims.projectName, until: until)
        }
        return plan
    }

    /// `canRefreshToken`: the agent's folder has a Vercel project link, and this Mac
    /// has a Vercel login, so the agent's library gets a token itself.
    static func plan(
        own: [String: String],
        shared: [String: String],
        canRefreshToken: Bool = false,
        now: Date = Date()
    ) -> Plan {
        var plan = Plan()
        for key in supabaseKeys {
            if isUsable(own[key], key: key) { continue }
            if key == signingKey, let value = own[key], !value.trimmingCharacters(in: .whitespaces).isEmpty {
                plan.ownSigningKeyUnreadable = true
            }
            if isUsable(shared[key], key: key) {
                plan.passthrough[key] = shared[key]
            } else {
                plan.missing.append(key)
            }
        }
        let hasOwnToken = isUsable(own[oidcKey], key: oidcKey)
        plan.ownTokenStale = hasOwnToken && isStaleToken(own[oidcKey], canRefresh: canRefreshToken, now: now)
        plan.ownsProjectToken = canRefreshToken || (hasOwnToken && !plan.ownTokenStale)
        if isUsable(own[gatewayKey], key: gatewayKey) || plan.ownsProjectToken {
            plan.hasModelCredential = true
        } else if isUsable(shared[gatewayKey], key: gatewayKey) {
            plan.passthrough[gatewayKey] = shared[gatewayKey]
            plan.hasModelCredential = true
        }
        return plan
    }

    static func plan(agentDirectory: String, sharedEnvFile: String) -> Plan {
        plan(
            own: ownValues(directory: agentDirectory),
            shared: sharedValues(file: sharedEnvFile),
            canRefreshToken: hasProjectLink(from: agentDirectory) && EventDirectoryEnv.hasVercelLogin()
        )
    }

    /// One line for the log of the service and for the environment check.
    /// `eventProjectUsable`: the runner can get the token of the event directory's
    /// project at the start of the agent (for the environment check).
    static func summary(_ plan: Plan, eventProjectUsable: Bool = false) -> String {
        var parts: [String] = []
        let supabase = supabaseKeys.filter { plan.passthrough[$0] != nil }
        if !plan.missing.isEmpty {
            parts.append("Not set: \(plan.missing.joined(separator: ", "))")
        } else if supabase.isEmpty {
            parts.append("AMATEUR_SUPABASE_* from the agent's own env")
        } else {
            parts.append("\(supabase.joined(separator: ", ")) from apps/booking-portal/.env")
        }
        if plan.ownSigningKeyUnreadable {
            parts.append("the signing key in the agent's .env.local is not readable JSON (single quotes fix it)")
        }
        if plan.ownTokenStale {
            parts.append("the \(oidcKey) in the agent's own env stopped")
        }
        if let project = plan.modelProject {
            let format = DateFormatter()
            format.dateFormat = "MMM d HH:mm"
            let name = project.name.map { "the Vercel project \($0)" } ?? "the Vercel project of the event directory"
            parts.append(
                "the model calls use \(name) (AI Gateway); its token is good until \(format.string(from: project.until)), "
                    + "restart the agent after that"
            )
        } else if let until = plan.projectTokenUntil {
            let format = DateFormatter()
            format.dateFormat = "MMM d HH:mm"
            parts.append(
                "the event data uses the token of the event directory's Vercel project; it is good until "
                    + "\(format.string(from: until)), restart the agent after that"
            )
        } else if !plan.hasModelCredential, eventProjectUsable {
            parts.append("the model calls use the Vercel project of the event directory (AI Gateway)")
        } else if !plan.hasModelCredential {
            parts.append("no \(gatewayKey): add it to apps/amateur-agent/.env.local, or use /login in the eve REPL")
        }
        // The event tools of the agent (PXI) need the token of a Vercel project.
        if !plan.ownsProjectToken, plan.projectTokenUntil == nil, !eventProjectUsable {
            parts.append(
                "no Vercel token for the event data: put the env of the event directory in place. \(EventDirectoryEnv.loginHint)"
            )
        }
        if plan.pxiMissing {
            parts.append(
                "no \(pxiURLKey): the event tools of the agent fail. Import the env of the event directory (Environment Check)"
            )
        }
        if !plan.eventDirectoryKeys.isEmpty {
            parts.append("\(plan.eventDirectoryKeys.joined(separator: ", ")) from the env of the event directory")
        }
        return parts.joined(separator: "; ")
    }
}

/// Decides how the runner starts the agent service.
enum AgentLauncher {
    struct Launch: Equatable, Sendable {
        /// The `bin` folder of the Node to put first in PATH; nil when the default Node is new enough.
        var nodeBin: String?
        /// Values for the process (see `AgentEnv`).
        var env: [String: String]
        /// Lines for the log of the service.
        var notes: [String]
    }

    enum Decision: Equatable, Sendable {
        case run(Launch)
        case skip(String)
    }

    static func decide(
        hasPackages: Bool,
        defaultNodeMajor: Int?,
        installs: [NodeLocator.Install],
        env: AgentEnv.Plan,
        minimumMajor: Int = ServiceCatalog.agentNodeMajor
    ) -> Decision {
        guard hasPackages else {
            return .skip("Its packages are not installed. Run pnpm install at the root of the fork, then restart the agent.")
        }
        var notes: [String] = []
        var nodeBin: String?
        if let major = defaultNodeMajor, major >= minimumMajor {
            notes.append("Node \(major) (the default) runs the agent.")
        } else if let install = NodeLocator.pick(installs, minimumMajor: minimumMajor) {
            nodeBin = install.binDirectory
            let version = install.version.map(String.init).joined(separator: ".")
            notes.append("Node \(version) runs the agent (\(install.binDirectory)). The default Node is too old for eve.")
        } else {
            let found = defaultNodeMajor.map { "the default is Node \($0)" } ?? "no default Node"
            return .skip(
                "eve needs Node \(minimumMajor) or later (\(found)). Install it with: nvm install \(minimumMajor), "
                    + "or: brew install node@\(minimumMajor). Then restart the agent."
            )
        }
        notes.append(AgentEnv.summary(env))
        return .run(Launch(nodeBin: nodeBin, env: env.passthrough, notes: notes))
    }

    /// The service with the Node and the env of `launch`.
    static func definition(_ definition: ServiceDefinition, launch: Launch) -> ServiceDefinition {
        ServiceDefinition(
            id: definition.id,
            name: definition.name,
            cmd: launch.nodeBin.map { NodeLocator.command(definition.cmd, nodeBin: $0) } ?? definition.cmd,
            cwd: definition.cwd,
            probe: definition.probe,
            type: definition.type,
            restart: definition.restart,
            dependsOn: definition.dependsOn,
            env: (definition.env ?? [:]).merging(launch.env) { _, passed in passed },
            phase: definition.phase,
            reuseIfRunning: definition.reuseIfRunning
        )
    }
}
