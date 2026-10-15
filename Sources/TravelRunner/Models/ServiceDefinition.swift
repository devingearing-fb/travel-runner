import Foundation

struct ServiceConfig: Codable, Sendable {
    let version: Int
    let registryPortRange: [Int]
    let services: [ServiceDefinition]
    let paths: RepoPaths?
    let profile: RunProfile?

    enum CodingKeys: String, CodingKey {
        case version
        case registryPortRange = "registry_port_range"
        case services
        case paths
        case profile
    }

    var resolvedProfile: RunProfile { profile ?? .both }
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
    let cmd: [String]
    let cwd: String?
    let probe: ProbeConfig?
    let type: ServiceType?
    let restart: RestartPolicy?
    let dependsOn: [String]
    let env: [String: String]?
    let phase: String?
    let reuseIfRunning: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, cmd, cwd, probe, type, restart, env, phase
        case dependsOn = "depends_on"
        case reuseIfRunning = "reuse_if_running"
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
}
