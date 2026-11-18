import Foundation

struct ServiceConfig: Codable, Sendable {
    let version: Int
    let registryPortRange: [Int]
    let services: [ServiceDefinition]
    let paths: RepoPaths?
    let profile: RunProfile?
    /// Services of the file that were left out, with the reason. Not stored in the file.
    var skippedServices: [SkippedService] = []

    enum CodingKeys: String, CodingKey {
        case version
        case registryPortRange = "registry_port_range"
        case services
        case paths
        case profile
    }

    var resolvedProfile: RunProfile { profile ?? .both }
}

extension ServiceConfig {
    /// A service that cannot run does not stop the load: it is left out, and
    /// `skippedServices` says why.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try container.decode([ServiceEntry].self, forKey: .services)
        var services = entries.compactMap { if case .valid(let service) = $0 { service } else { nil } }
        var skipped = entries.compactMap { if case .skipped(let skipped) = $0 { skipped } else { nil } }
        Self.skipDependents(of: &skipped, in: &services)
        self.init(
            version: try container.decode(Int.self, forKey: .version),
            registryPortRange: try container.decode([Int].self, forKey: .registryPortRange),
            services: services,
            paths: try container.decodeIfPresent(RepoPaths.self, forKey: .paths),
            profile: try container.decodeIfPresent(RunProfile.self, forKey: .profile),
            skippedServices: skipped
        )
    }

    /// A service that needs a skipped service cannot start, so it is skipped too,
    /// and so is each service that needs it. Without this the dependency graph
    /// rejects the whole file.
    private static func skipDependents(of skipped: inout [SkippedService], in services: inout [ServiceDefinition]) {
        while true {
            let present = Set(services.map(\.id))
            let gone = Set(skipped.compactMap(\.id)).subtracting(present)
            var kept: [ServiceDefinition] = []
            var found = false
            for service in services {
                if let missing = service.dependsOn.first(where: gone.contains) {
                    skipped.append(SkippedService(id: service.id, reason: "depends on \"\(missing)\", which was skipped"))
                    found = true
                } else {
                    kept.append(service)
                }
            }
            services = kept
            if !found { return }
        }
    }

    private enum ServiceEntry: Decodable {
        case valid(ServiceDefinition)
        case skipped(SkippedService)

        init(from decoder: Decoder) throws {
            do {
                let service = try ServiceDefinition(from: decoder)
                if let problem = service.probe?.problem {
                    self = .skipped(SkippedService(id: service.id, reason: problem))
                } else {
                    self = .valid(service)
                }
            } catch {
                let id = (try? decoder.container(keyedBy: ServiceDefinition.CodingKeys.self))
                    .flatMap { try? $0.decode(String.self, forKey: .id) }
                self = .skipped(SkippedService(id: id, reason: SkippedService.reason(for: error, in: decoder.codingPath)))
            }
        }
    }
}

/// A service of services.json that the runner left out, and why.
struct SkippedService: Sendable, Equatable {
    let id: String?
    let reason: String

    /// The text of the banner.
    var message: String {
        let kind = id.map(ServiceCatalog.canonicalIDs.contains) == true ? "service" : "custom service"
        let name = id.map { "\(kind) \"\($0)\"" } ?? "a \(kind) with no id"
        return "services.json: \(name) was skipped — \(reason)."
    }

    /// Says which field of the service is wrong, in the words of the file.
    /// `servicePath` is the place of the service in the file; the field is named from there.
    static func reason(for error: Error, in servicePath: [CodingKey] = []) -> String {
        // The place of an element in a list reads as `cmd[1]`: the decoder's own name
        // for it ("Index 1") is not a name from the file.
        func field(_ path: [CodingKey], _ last: CodingKey? = nil) -> String {
            var name = ""
            for key in path.dropFirst(servicePath.count) + (last.map { [$0] } ?? []) {
                if let index = key.intValue, key.stringValue == "Index \(index)" {
                    name += "[\(index)]"
                } else {
                    name += name.isEmpty ? key.stringValue : ".\(key.stringValue)"
                }
            }
            return name
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "it has no \"\(field(context.codingPath, key))\""
        case DecodingError.valueNotFound(_, let context),
             DecodingError.typeMismatch(_, let context),
             DecodingError.dataCorrupted(let context):
            let name = field(context.codingPath)
            if name == "probe.type" {
                return "its probe type is not known (use tcp, http or stdout_regex)"
            }
            return name.isEmpty ? "it is not a service object" : "its \"\(name)\" has the wrong kind of value"
        default:
            return "it cannot be read"
        }
    }
}

/// Repo locations. The app and package directories live inside the monorepo and are
/// derived from it; only repos outside the monorepo are configured.
struct RepoPaths: Codable, Sendable, Equatable {
    var monorepo: String?
    var universalLogin: String?
    var streamServices: String?
    var loadTest: String?

    enum CodingKeys: String, CodingKey {
        case monorepo
        case universalLogin = "universal_login"
        case streamServices = "stream_services"
        case loadTest = "load_test"
    }

    var bookingPortal: String? { inMonorepo("apps/booking-portal") }
    var partnerPortal: String? { inMonorepo("apps/partner-portal") }
    var travelData: String? { inMonorepo("packages/travel-data") }

    private func inMonorepo(_ relative: String) -> String? {
        guard let monorepo, !monorepo.isEmpty else { return nil }
        return (NSString(string: monorepo).expandingTildeInPath as NSString).appendingPathComponent(relative)
    }
}

struct ServiceDefinition: Codable, Sendable, Identifiable {
    let id: String
    let name: String?
    /// `var`, so a launch can copy the definition and change it without losing a field.
    var cmd: [String]
    let cwd: String?
    let probe: ProbeConfig?
    let type: ServiceType?
    let restart: RestartPolicy?
    let dependsOn: [String]
    var env: [String: String]?
    let phase: String?
    let reuseIfRunning: Bool?
    /// A command that tears the service down (a `compose down`). A stop runs it
    /// after the grace of SIGTERM, as a backup to the service's own cleanup, and
    /// before any port sweep.
    var stopCmd: [String]? = nil
    /// The wait between SIGTERM and SIGKILL of a stop. Nil is `defaultStopGrace`.
    var stopGraceSeconds: Int? = nil
    /// What the row says while the service stops. Not stored in the file.
    var stopNote: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, cmd, cwd, probe, type, restart, env, phase
        case dependsOn = "depends_on"
        case reuseIfRunning = "reuse_if_running"
        case stopCmd = "stop_cmd"
        case stopGraceSeconds = "stop_grace_seconds"
    }

    /// Enough for a dev server to close its sockets and write its last lines.
    static let defaultStopGrace: Duration = .seconds(5)

    var resolvedStopGrace: Duration {
        stopGraceSeconds.map { .seconds(max($0, 0)) } ?? Self.defaultStopGrace
    }

    /// The stop command, or nil when the service has none.
    var resolvedStopCmd: [String]? {
        guard let stopCmd, !stopCmd.isEmpty else { return nil }
        return stopCmd
    }

    /// The row text while the service stops, or nil when it has no stop command.
    var stoppingText: String? {
        guard let stopCmd = resolvedStopCmd else { return nil }
        return "Stopping \(stopNote ?? "\(displayName) (\(stopCmd.joined(separator: " ")))")…"
    }

    var shouldReuseIfRunning: Bool { reuseIfRunning ?? false }

    var displayName: String { name ?? id }

    var resolvedType: ServiceType { type ?? .daemon }

    var resolvedRestart: RestartPolicy { restart ?? .never }

    var resolvedCwd: String? {
        cwd.map { NSString(string: $0).expandingTildeInPath }
    }
}

enum ServiceType: String, Codable, Sendable {
    case daemon
    case oneshot
}

enum RestartPolicy: String, Codable, Sendable {
    case onFailure = "on-failure"
    case always
    case never
}

struct ProbeConfig: Codable, Sendable {
    let type: ProbeType
    let port: Int?
    let host: String?
    let url: String?
    let pattern: String?
    let artifact: String?
    let timeout: Int?

    enum ProbeType: String, Codable, Sendable {
        case tcp
        case http
        case stdoutRegex = "stdout_regex"
    }

    var resolvedTimeout: Duration {
        .seconds(timeout ?? 120)
    }

    static let validPorts = 1...65535

    /// What is wrong with this probe, or nil when a probe can be made from it.
    var problem: String? {
        switch type {
        case .tcp:
            guard let port, Self.validPorts.contains(port) else {
                return "probe type tcp needs a port (1–65535)"
            }
        case .http:
            if let url {
                guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
                      parsed.host?.isEmpty == false else {
                    return "probe type http needs an http or https url"
                }
            } else if port == nil {
                return "probe type http needs a url or a port (1–65535)"
            }
        case .stdoutRegex:
            guard let pattern, !pattern.isEmpty else {
                return "probe type stdout_regex needs a pattern"
            }
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                return "probe type stdout_regex needs a pattern that is a valid regular expression"
            }
        }
        // The port is also used to find and stop the process that listens on it.
        if let port, !Self.validPorts.contains(port) {
            return "probe port \(port) is not a port (1–65535)"
        }
        return nil
    }
}
