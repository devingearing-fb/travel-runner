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
    }

    static func plan(own: [String: String], shared: [String: String]) -> Plan {
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
        if isUsable(own[gatewayKey], key: gatewayKey) || isUsable(own[oidcKey], key: oidcKey) {
            plan.hasModelCredential = true
        } else if isUsable(shared[gatewayKey], key: gatewayKey) {
            plan.passthrough[gatewayKey] = shared[gatewayKey]
            plan.hasModelCredential = true
        }
        return plan
    }

    static func plan(agentDirectory: String, sharedEnvFile: String) -> Plan {
        plan(own: ownValues(directory: agentDirectory), shared: sharedValues(file: sharedEnvFile))
    }

    /// One line for the log of the service and for the environment check.
    static func summary(_ plan: Plan) -> String {
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
        if !plan.hasModelCredential {
            parts.append("no \(gatewayKey): add it to apps/amateur-agent/.env.local, or use /login in the eve REPL")
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
