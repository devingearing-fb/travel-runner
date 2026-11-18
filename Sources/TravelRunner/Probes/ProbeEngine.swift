import Foundation

protocol Probe: Sendable {
    /// One check. A failed check says why.
    func outcome() async -> ProbeOutcome
}

extension Probe {
    func check() async -> Bool { await outcome().isReady }
}

/// A probe config that no probe can be made from. `reason` is `ProbeConfig.problem`.
struct ProbeConfigError: Error, Equatable, CustomStringConvertible {
    let reason: String
    var description: String { reason }
}

enum ProbeFactory {
    /// Throws `ProbeConfigError` for a config with a missing or wrong field.
    /// `requestTimeout` limits one HTTP request: 60 s while a service starts,
    /// 5 s for a liveness check.
    static func makeProbe(for config: ProbeConfig, requestTimeout: TimeInterval = 60) throws -> Probe {
        if let problem = config.problem { throw ProbeConfigError(reason: problem) }
        switch config.type {
        case .tcp:
            guard let port = config.port else { throw ProbeConfigError(reason: "probe type tcp needs a port (1–65535)") }
            return TcpProbe(port: port, host: config.host ?? "127.0.0.1")
        case .http:
            if let url = config.url { return HttpProbe(url: url, requestTimeout: requestTimeout) }
            guard let port = config.port else {
                throw ProbeConfigError(reason: "probe type http needs a url or a port (1–65535)")
            }
            return HttpProbe(url: "http://127.0.0.1:\(port)/health", requestTimeout: requestTimeout)
        case .stdoutRegex:
            return try StdoutProbe(pattern: config.pattern ?? "")
        }
    }
}

/// Checks until the probe passes or the time is up. Returns the last outcome.
/// The deadline is awake time: a Mac that sleeps uses none of it.
func waitForProbe(
    _ probe: Probe,
    timeout: Duration = .seconds(120),
    interval: Duration = .seconds(2),
    clock: RunnerClock = .awake
) async throws -> ProbeOutcome {
    let deadline = clock.uptime() + timeout
    var last = ProbeOutcome.timedOut
    while clock.uptime() < deadline {
        last = await probe.outcome()
        if last.isReady { return last }
        try await clock.sleep(for: interval)
    }
    return last
}
