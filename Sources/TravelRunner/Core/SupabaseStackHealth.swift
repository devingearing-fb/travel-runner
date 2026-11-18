import Foundation

/// The state of the local Supabase stack of a checkout. An open database port is not
/// enough: Postgres opens it before Kong, auth and PostgREST answer.
enum SupabaseStackHealth: Equatable, Sendable {
    /// The containers are up, the database answers `select 1`, `local-db.sh status
    /// -o env` gives the keys, and auth and rest answer through Kong with the anon key.
    case healthy
    /// Some parts of the stack run. `missing` names those that do not answer.
    case partial(missing: [String])
    /// No container of this stack runs.
    case down
    /// The database of another project holds the port.
    case foreign(container: String)

    /// The containers that a working stack needs. Studio, storage and the rest are optional.
    static let requiredServices = ["db", "kong", "auth", "rest"]

    /// The part that stands for `local-db.sh status -o env` in `missing`.
    static let statusPart = "local-db.sh status"

    /// Stops the containers of the stack and keeps their data.
    static let stopCommand = ["pnpm", "db:stop"]

    /// The toast when `pnpm db:stop` fails or times out: the stack runs on.
    static let didNotStopText = "Supabase did not stop — see its log"

    /// The row text while the stack stops.
    static let stoppingText = "Stopping Supabase (pnpm db:stop)…"

    /// Off by default: Supabase keeps running between sessions.
    static let stopOnQuitSettingKey = "stopSupabaseOnQuit"

    static let restartConfirmationTitle = "Restart Supabase?"
    static let restartConfirmationMessage = "This stops and starts the local containers (about 1 min). Data is kept."

    /// "auth, kong not answering".
    static func missingText(_ missing: [String]) -> String {
        "\(missing.joined(separator: ", ")) not answering"
    }

    /// The log line of a start that finds a stack that is only partly up.
    static func partialRepairLine(_ missing: [String]) -> String {
        "[travel-runner] Supabase is only partly up (\(missingText(missing))) — running db:stop, then db:start"
    }

    /// The container of one service of the project: `supabase_<service>_<project_id>`.
    static func container(_ service: String, project: String) -> String {
        "supabase_\(service)_\(project)"
    }

    /// `docker ps --format '{{.Names}}\t{{.Status}}'`: name → status.
    static func parseContainers(_ output: String) -> [String: String] {
        var containers: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            containers[name] = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        }
        return containers
    }

    /// The `[api] port` of `supabase/config.toml`, or 54321.
    static func apiPort(inConfig config: String) -> Int {
        var section = ""
        for raw in config.split(whereSeparator: \.isNewline) {
            let line = (raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard section == "api" else { continue }
            let pair = line.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "port",
                  let port = Int(pair[1].trimmingCharacters(in: .whitespaces)), port > 0 else { continue }
            return port
        }
        return 54321
    }

    static func apiPort(root: String) -> Int {
        let path = (root as NSString).appendingPathComponent("supabase/config.toml")
        return (try? String(contentsOfFile: path, encoding: .utf8)).map(apiPort(inConfig:)) ?? 54321
    }

    /// One request with a 5 s limit that follows no redirect: the status, or nil without an answer.
    static let liveHTTPStatus: @Sendable (URLRequest) async -> Int? = { request in
        try? await HttpProbe.sendWithoutRedirects(request).statusCode
    }

    /// A GET through Kong. With the anon key Kong passes it on to the service;
    /// without one Kong answers 401 itself.
    static func apiRequest(_ url: URL, apiKey: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "apikey") }
        return request
    }

    /// True when `docker ps` shows the container up and ready: not restarting, not
    /// paused, and with no health check that fails or still starts.
    static func isUp(status: String) -> Bool {
        status.hasPrefix("Up")
            && !["(unhealthy)", "(health: starting)", "(Paused)"].contains(where: status.contains)
    }

    /// Checks the stack of the checkout at `root`. The cheap checks run first;
    /// `local-db.sh status` runs only when the containers and the database pass.
    static func check(
        root: String,
        dbPort: Int,
        shell: any CommandRunning,
        environment: [String: String] = [:],
        httpStatus: @Sendable (URLRequest) async -> Int? = liveHTTPStatus
    ) async -> SupabaseStackHealth {
        let project = SupabaseProject.projectName(root: root)
        let list = await shell.run("docker ps --format '{{.Names}}\t{{.Status}}'", timeout: .seconds(10))
        // Docker does not answer: nothing of the stack can run. db:start says why.
        guard list.succeeded else { return .down }
        let containers = parseContainers(list.stdout)
        let db = container("db", project: project)

        if containers[db] == nil {
            let owner = await shell.run(
                "docker ps --filter publish=\(dbPort) --format '{{.Names}}'", timeout: .seconds(10)
            )
            if owner.succeeded, let name = owner.stdout.split(whereSeparator: \.isNewline).first.map(String.init),
               !name.isEmpty, name != db {
                return .foreign(container: name)
            }
        }

        guard requiredServices.contains(where: { containers[container($0, project: project)] != nil }) else {
            return .down
        }

        var missing = requiredServices.filter { service in
            guard let status = containers[container(service, project: project)] else { return true }
            return !isUp(status: status)
        }

        if !missing.contains("db") {
            let query = await shell.run(
                ShellQuote.join(["docker", "exec", db, "psql", "-U", "postgres", "-d", "postgres", "-tAc", "select 1"]),
                timeout: .seconds(20)
            )
            if !(query.succeeded && query.trimmedOutput == "1") { missing.append("db") }
        }

        // The keys come before the requests: without the anon key Kong answers 401
        // itself, and the request never reaches auth or rest.
        var keys: LocalSupabaseKeys?
        if missing.isEmpty {
            let status = await shell.run(
                "scripts/local-db.sh status -o env", cwd: root, environment: environment, timeout: .seconds(60)
            )
            keys = status.succeeded ? LocalSupabaseKeys.parse(statusEnv: status.stdout) : nil
            if keys == nil { missing.append(statusPart) }
        }

        if !missing.contains("kong") {
            let base = "http://127.0.0.1:\(apiPort(root: root))"
            // A 5xx means Kong cannot reach the service. Without the key only auth is
            // asked: Kong's 401 shows that Kong itself is up.
            let paths = keys == nil ? [("auth", "/auth/v1/health")] : [("auth", "/auth/v1/health"), ("rest", "/rest/v1/")]
            for (service, path) in paths {
                guard let url = URL(string: base + path) else { continue }
                switch await httpStatus(apiRequest(url, apiKey: keys?.anonKey)) {
                case nil:
                    if !missing.contains("kong") { missing.append("kong") }
                case let code? where code >= 500:
                    if !missing.contains(service) { missing.append(service) }
                default:
                    break
                }
                if missing.contains("kong") { break }
            }
        }
        return missing.isEmpty ? .healthy : .partial(missing: missing)
    }
}
