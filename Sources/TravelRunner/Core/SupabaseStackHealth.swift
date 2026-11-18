import Foundation

/// The state of the local Supabase stack of a checkout. An open database port is not
/// enough: Postgres opens it before Kong, auth and PostgREST answer.
enum SupabaseStackHealth: Equatable, Sendable {
    /// The containers run, the database answers `select 1`, the auth health URL
    /// answers, and `local-db.sh status -o env` gives the keys.
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

    /// One GET with a 5 s limit that follows no redirect: the status, or nil without an answer.
    static let liveHTTPStatus: @Sendable (URL) async -> Int? = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try? await HttpProbe.sendWithoutRedirects(request).statusCode
    }

    /// Checks the stack of the checkout at `root`. The cheap checks run first;
    /// `local-db.sh status` runs only when all the others pass.
    static func check(
        root: String,
        dbPort: Int,
        shell: any CommandRunning,
        environment: [String: String] = [:],
        httpStatus: @Sendable (URL) async -> Int? = liveHTTPStatus
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
            return status.contains("(unhealthy)")
        }

        if !missing.contains("db") {
            let query = await shell.run(
                ShellQuote.join(["docker", "exec", db, "psql", "-U", "postgres", "-d", "postgres", "-tAc", "select 1"]),
                timeout: .seconds(20)
            )
            if !(query.succeeded && query.trimmedOutput == "1") { missing.append("db") }
        }

        // Kong answers 401 without an API key: it is up and routes. A 5xx means it
        // cannot reach auth.
        if !missing.contains("kong"), let url = URL(string: "http://127.0.0.1:\(apiPort(root: root))/auth/v1/health") {
            switch await httpStatus(url) {
            case nil: missing.append("kong")
            case let status? where status >= 500: if !missing.contains("auth") { missing.append("auth") }
            default: break
            }
        }

        if missing.isEmpty {
            let status = await shell.run(
                "scripts/local-db.sh status -o env", cwd: root, environment: environment, timeout: .seconds(60)
            )
            if !(status.succeeded && LocalSupabaseKeys.parse(statusEnv: status.stdout) != nil) {
                missing.append(statusPart)
            }
        }
        return missing.isEmpty ? .healthy : .partial(missing: missing)
    }
}
