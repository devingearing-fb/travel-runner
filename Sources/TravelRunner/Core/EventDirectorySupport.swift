import Foundation

/// The env of the event directory app of the hackathon fork (`apps/event-directory`).
///
/// The app reads hosted services only. Its env is the file of `vercel env pull`,
/// which people also send to each other: `apps/event-directory/.env.local`.
/// For its event data the app needs a Vercel OIDC token of its project. The
/// token in the env file stops after 12 hours. After that, the app's own library
/// (`@vercel/oidc`) gets a new one, when two things are there:
/// the project link (`.vercel/project.json`) and a Vercel login on this Mac.
/// The runner writes the link from the IDs in the token of the env file. It does
/// not write the env file.
enum EventDirectoryEnv {
    /// Without these the pages fail at once.
    static let requiredKeys = ["SITE_URL", "PXI_API_URL"]
    static let tokenKey = "VERCEL_OIDC_TOKEN"
    /// The files that `next dev` reads in the app folder, the strongest first.
    static let fileNames = [".env.development.local", ".env.local", ".env.development", ".env"]
    static let linkPath = ".vercel/project.json"
    /// The home page shows the chat of the agent when this is set, and the app sends
    /// `/eve/v1/*` to that address.
    static let agentURLKey = "AMATEUR_AGENT_URL"
    /// The agent that the runner starts. `eve dev` listens on 127.0.0.1 only.
    static let localAgentURL = "http://127.0.0.1:\(ServiceCatalog.agentPort)"

    /// The values that the runner gives the process: the address of the agent,
    /// when the app's own files do not set one.
    static func processEnv(_ values: [String: String]) -> [String: String] {
        let own = (values[agentURLKey] ?? "").trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? [agentURLKey: localAgentURL] : [:]
    }

    /// What the app gets from the files of its folder.
    static func values(directory: String) -> [String: String] {
        var values: [String: String] = [:]
        for name in fileNames.reversed() {
            let path = (directory as NSString).appendingPathComponent(name)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            values.merge(AgentEnv.parse(content, dialect: .node)) { _, stronger in stronger }
        }
        return values
    }

    static func missingKeys(_ values: [String: String]) -> [String] {
        requiredKeys.filter { (values[$0] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// The claims of a Vercel OIDC token that the runner uses. They are not secret.
    struct TokenClaims: Equatable, Sendable {
        var projectID: String
        var teamID: String
        var projectName: String?
        var expiresAt: Date?

        func isValid(at now: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt > now
        }
    }

    /// Reads the claims from the middle part of the token. The runner does not
    /// check the signature: it only reads which project the token is for.
    static func claims(ofToken token: String?) -> TokenClaims? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projectID = payload["project_id"] as? String, !projectID.isEmpty,
              let teamID = payload["owner_id"] as? String, !teamID.isEmpty else { return nil }
        return TokenClaims(
            projectID: projectID,
            teamID: teamID,
            projectName: payload["project"] as? String,
            expiresAt: (payload["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        )
    }

    /// The content of `.vercel/project.json`, as `vercel link` writes it.
    static func projectLink(_ claims: TokenClaims) -> Data {
        var link = ["projectId": claims.projectID, "orgId": claims.teamID]
        if let name = claims.projectName { link["projectName"] = name }
        return (try? JSONSerialization.data(withJSONObject: link, options: [.sortedKeys])) ?? Data()
    }

    static func isLinked(directory: String) -> Bool {
        FileManager.default.fileExists(atPath: (directory as NSString).appendingPathComponent(linkPath))
    }

    /// Writes the project link when there is none. A link that a person made
    /// (`vercel link`, possibly to another project) stays. Returns true when it wrote the file.
    @discardableResult
    static func ensureLink(directory: String, claims: TokenClaims) -> Bool {
        guard !isLinked(directory: directory) else { return false }
        let path = (directory as NSString).appendingPathComponent(linkPath)
        do {
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
            )
            try projectLink(claims).write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// True when the Vercel CLI has a login on this Mac. The app's library uses it
    /// to get a new token.
    static func hasVercelLogin(home: String = NSHomeDirectory()) -> Bool {
        let candidates = [
            "\(home)/Library/Application Support/com.vercel.cli/auth.json",
            "\(home)/.local/share/com.vercel.cli/auth.json",
        ]
        for path in candidates {
            guard let data = FileManager.default.contents(atPath: path),
                  let auth = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let token = (auth["token"] as? String) ?? ""
            let refresh = (auth["refreshToken"] as? String) ?? ""
            if !token.isEmpty || !refresh.isEmpty { return true }
        }
        return false
    }

    /// How the app gets the token for its event data.
    enum Access: Equatable, Sendable {
        /// The token of the env file is good until this time. After it, `renewable` says what happens.
        case valid(until: Date, renewable: Bool)
        /// No good token in the file; the app gets one through the Vercel login.
        case renewable
        /// No good token, and no Vercel login: the pages with event data fail.
        case needsLogin(expired: Date?)
        /// No good token, and nothing that names the project: a new env file is necessary.
        case needsEnv
    }

    /// `linked` is the state after the runner wrote the link, when it could.
    static func access(claims: TokenClaims?, linked: Bool, hasLogin: Bool, now: Date = Date()) -> Access {
        let renewable = linked && hasLogin
        if let claims, let expiresAt = claims.expiresAt, claims.isValid(at: now) {
            return .valid(until: expiresAt, renewable: renewable)
        }
        if renewable { return .renewable }
        if linked { return .needsLogin(expired: claims?.expiresAt) }
        return .needsEnv
    }

    static let loginHint = "Log in to Vercel: npx vercel login"

    /// One line for the log of the service and for the environment check.
    static func summary(_ access: Access) -> String {
        let format = DateFormatter()
        format.dateFormat = "MMM d HH:mm"
        switch access {
        case .valid(let until, let renewable):
            let after = renewable
                ? "After that, the app gets a new one through your Vercel login."
                : "After that, the pages with event data fail. \(loginHint)"
            return "The API token of the env file is good until \(format.string(from: until)). \(after)"
        case .renewable:
            return "The app gets its API token through your Vercel login."
        case .needsLogin(let expired):
            let when = expired.map { "stopped on \(format.string(from: $0))" } ?? "is not there"
            return "The API token of the env file \(when), and there is no Vercel login. The pages with event data fail. \(loginHint)"
        case .needsEnv:
            return "The env file has no API token (\(tokenKey)), and the app is not linked to its Vercel project. The pages with event data fail. Get a new env file: vercel env pull .env.local --environment=production"
        }
    }

    /// True when the pages with event data can work.
    static func isUsable(_ access: Access) -> Bool {
        switch access {
        case .valid, .renewable: true
        case .needsLogin, .needsEnv: false
        }
    }
}

/// Decides how the runner starts the event directory.
enum EventDirectoryLauncher {
    enum Decision: Equatable, Sendable {
        /// Start it with these values for the process; the lines go to the log of the service.
        case run(notes: [String], env: [String: String])
        case skip(String)
    }

    static func decide(
        hasPackages: Bool,
        missingKeys: [String],
        access: EventDirectoryEnv.Access,
        wroteLink: Bool,
        env: [String: String] = [:]
    ) -> Decision {
        guard hasPackages else {
            return .skip("Its packages are not installed. Run pnpm install at the root of the fork, then restart the event directory.")
        }
        guard missingKeys.isEmpty else {
            return .skip(
                "Its env is not there (\(missingKeys.joined(separator: ", "))). Put the file of `vercel env pull` at "
                    + "\(RepoDetector.eventDirectory)/.env.local, or use Import… on the Environment Check step. Then restart the event directory."
            )
        }
        var notes: [String] = []
        if wroteLink {
            notes.append("Linked the app to its Vercel project (\(RepoDetector.eventDirectory)/\(EventDirectoryEnv.linkPath)), from the IDs in the env file.")
        }
        notes.append(EventDirectoryEnv.summary(access))
        if let agent = env[EventDirectoryEnv.agentURLKey] {
            notes.append("The chat of the home page uses the agent of the runner (\(EventDirectoryEnv.agentURLKey)=\(agent)).")
        }
        return .run(notes: notes, env: env)
    }

    /// The service with the values of `env` for its process.
    static func definition(_ definition: ServiceDefinition, env: [String: String]) -> ServiceDefinition {
        guard !env.isEmpty else { return definition }
        return ServiceDefinition(
            id: definition.id,
            name: definition.name,
            cmd: definition.cmd,
            cwd: definition.cwd,
            probe: definition.probe,
            type: definition.type,
            restart: definition.restart,
            dependsOn: definition.dependsOn,
            env: (definition.env ?? [:]).merging(env) { _, passed in passed },
            phase: definition.phase,
            reuseIfRunning: definition.reuseIfRunning
        )
    }
}
