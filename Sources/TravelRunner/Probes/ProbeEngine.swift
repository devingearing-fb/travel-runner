import Foundation

protocol Probe: Sendable {
    func check() async -> Bool
}

/// A probe config that no probe can be made from. `reason` is `ProbeConfig.problem`.
struct ProbeConfigError: Error, Equatable, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

enum ProbeFactory {
    /// Throws `ProbeConfigError` for a config with a missing or wrong field.
    static func makeProbe(for config: ProbeConfig) throws -> Probe {
        if let problem = config.problem { throw ProbeConfigError(reason: problem) }
        switch config.type {
        case .tcp:
            guard let port = config.port else { throw ProbeConfigError(reason: "probe type tcp needs a port (1–65535)") }
            return TcpProbe(port: port, host: config.host ?? "127.0.0.1")
        case .http:
            if let url = config.url { return HttpProbe(url: url) }
            guard let port = config.port else {
                throw ProbeConfigError(reason: "probe type http needs a url or a port (1–65535)")
            }
            return HttpProbe(url: "http://127.0.0.1:\(port)/health")
        case .stdoutRegex:
            return try StdoutProbe(pattern: config.pattern ?? "")
        }
    }
}

func waitForProbe(
    _ probe: Probe,
    timeout: Duration = .seconds(120),
    interval: Duration = .seconds(2)
) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await probe.check() { return true }
        try await Task.sleep(for: interval)
    }
    return false
}
