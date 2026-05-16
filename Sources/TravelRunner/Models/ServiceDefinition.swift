import Foundation

struct ServiceConfig: Codable, Sendable {
    let version: Int
    let registryPortRange: [Int]
    let services: [ServiceDefinition]
    let paths: RepoPaths?

    enum CodingKeys: String, CodingKey {
        case version
        case registryPortRange = "registry_port_range"
        case services
        case paths
    }
}

struct RepoPaths: Codable, Sendable {
    let travelData: String?
    let bookingPortal: String?
    let universalLogin: String?
    let partnerPortal: String?

    enum CodingKeys: String, CodingKey {
        case travelData = "travel_data"
        case bookingPortal = "booking_portal"
        case universalLogin = "universal_login"
        case partnerPortal = "partner_portal"
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
