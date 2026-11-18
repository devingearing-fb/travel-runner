import Foundation

/// What a ticket says about this Mac and the stack at the time of the failure:
/// the build, macOS, the tools, the profile, the database, the checks and each
/// service. The issue folder has it as `diagnostics.json`.
///
/// Paths under the home folder start with `~`. Free text goes through the
/// redactor before it is written (`redacted(by:)`).
struct DiagnosticsSnapshot: Codable, Sendable, Equatable {
    struct App: Codable, Sendable, Equatable {
        var version: String?
        var build: String?
        var commit: String?
        var buildKind: String
        var flavor: String

        enum CodingKeys: String, CodingKey {
            case version, build, commit, flavor
            case buildKind = "build_kind"
        }

        init(_ info: BuildInfo) {
            version = info.version
            build = info.build
            commit = info.commit
            buildKind = info.kind.rawValue
            flavor = info.flavor.rawValue
        }
    }

    struct Machine: Codable, Sendable, Equatable {
        /// Such as "Version 15.1 (Build 24B83)".
        var macOS: String
        /// The architecture of this process: "arm64" or "x86_64".
        var arch: String
        /// True when an Intel build runs on Apple silicon.
        var rosetta: Bool

        enum CodingKeys: String, CodingKey {
            case arch, rosetta
            case macOS = "macos"
        }

        static var current: Machine {
            Machine(
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                arch: machineName(),
                rosetta: isTranslated()
            )
        }

        private static func machineName() -> String {
            var info = utsname()
            uname(&info)
            return withUnsafeBytes(of: &info.machine) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }

        private static func isTranslated() -> Bool {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname("sysctl.proc_translated", &value, &size, nil, 0) == 0 else { return false }
            return value == 1
        }
    }

    struct Tool: Codable, Sendable, Equatable {
        var name: String
        /// Nil when the tool is not on the PATH, or when it was not read.
        var path: String?
        var version: String?
        /// Where the PATH got the tool: "login shell", "~/.zshrc (nvm)" or "runner".
        var source: String?
        /// Why the tool or its version could not be read.
        var problem: String?

        init(_ report: ToolReport, home: String) {
            name = report.name
            path = report.path.map { DiagnosticsSnapshot.tilde($0, home: home) }
            version = report.version
            source = switch report.origin {
            case .loginShell: "login shell"
            case .rcFile(let file, let manager): manager.map { "\(file) (\($0))" } ?? file
            case .runner: "runner"
            case nil: nil
            }
            problem = report.problem
        }
    }

    struct Check: Codable, Sendable, Equatable {
        var id: String
        var name: String
        /// "pending", "passed", "warning" or "failed".
        var status: String
        var message: String?
        var fix: String?

        init(id: String, name: String, result: PreflightResult) {
            self.id = id
            self.name = name
            switch result {
            case .pending: status = "pending"
            case .passed(let detail): status = "passed"; message = detail
            case .warning(let message): status = "warning"; self.message = message
            case .failed(let message, let fix): status = "failed"; self.message = message; self.fix = fix
            }
        }
    }

    struct DbStep: Codable, Sendable, Equatable {
        var id: String
        var name: String
        var status: String
        var optional: Bool
        var error: String?
    }

    struct DbPipeline: Codable, Sendable, Equatable {
        var profile: String
        var seedScenario: String
        var running: Bool
        var steps: [DbStep]

        enum CodingKeys: String, CodingKey {
            case profile, running, steps
            case seedScenario = "seed_scenario"
        }
    }

    struct Service: Codable, Sendable, Equatable {
        var id: String
        var phase: String
        var inProfile: Bool
        var pid: Int32?
        var exitCode: Int32?
        var restartCount: Int
        var circuitBroken: Bool
        var uptimeSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case id, phase, pid
            case inProfile = "in_profile"
            case exitCode = "exit_code"
            case restartCount = "restart_count"
            case circuitBroken = "circuit_broken"
            case uptimeSeconds = "uptime_seconds"
        }
    }

    var generatedAt: String
    var app: App
    var machine: Machine
    var tools: [Tool]
    /// The PATH of the commands of the runner.
    var toolPath: String?
    /// The run profile: which part of the stack Start brings up.
    var profile: String
    /// "local" or "remote".
    var dbMode: String
    var health: String
    var lastError: String?
    var preflight: [Check]
    /// Nil before the first DB setup of this run.
    var dbPipeline: DbPipeline?
    var pendingMigrations: [String]
    /// The checkouts from Settings, by key ("monorepo", "universal_login", ...).
    var repoPaths: [String: String]
    /// The branch of each service's checkout, by service id.
    var gitBranches: [String: String]
    var services: [Service]

    enum CodingKeys: String, CodingKey {
        case app, machine, tools, profile, health, preflight, services
        case generatedAt = "generated_at"
        case toolPath = "tool_path"
        case dbMode = "db_mode"
        case lastError = "last_error"
        case dbPipeline = "db_pipeline"
        case pendingMigrations = "pending_migrations"
        case repoPaths = "repo_paths"
        case gitBranches = "git_branches"
    }

    /// The repo paths of the config, with `~`. A path that is not set is left out.
    static func repoPaths(_ paths: RepoPaths?, home: String) -> [String: String] {
        guard let paths else { return [:] }
        let all: [(String, String?)] = [
            ("monorepo", paths.monorepo),
            ("universal_login", paths.universalLogin),
            ("stream_services", paths.streamServices),
            ("load_test", paths.loadTest),
        ]
        var result: [String: String] = [:]
        for (key, value) in all {
            guard let value, !value.isEmpty else { continue }
            result[key] = tilde(value, home: home)
        }
        return result
    }

    /// `path` with the home folder written as `~`. It also works inside a PATH
    /// list, where the home folder can be in many entries.
    static func tilde(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        var result = path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
        result = result.replacingOccurrences(of: ":" + home + "/", with: ":~/")
        return result
    }

    /// The snapshot with each free-text field redacted: the last error, the
    /// messages of the checks and the errors of the DB steps.
    func redacted(by redactor: Redactor) -> DiagnosticsSnapshot {
        var copy = self
        copy.lastError = lastError.map(redactor.redact)
        copy.preflight = preflight.map { check in
            var check = check
            check.message = check.message.map(redactor.redact)
            check.fix = check.fix.map(redactor.redact)
            return check
        }
        copy.dbPipeline?.steps = (dbPipeline?.steps ?? []).map { step in
            var step = step
            step.error = step.error.map(redactor.redact)
            return step
        }
        copy.tools = tools.map { tool in
            var tool = tool
            tool.problem = tool.problem.map(redactor.redact)
            return tool
        }
        return copy
    }
}
