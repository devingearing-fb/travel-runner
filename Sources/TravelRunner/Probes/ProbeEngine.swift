import Foundation

protocol Probe: Sendable {
    func check() async -> Bool
}

enum ProbeFactory {
    static func makeProbe(for config: ProbeConfig) -> Probe {
        switch config.type {
        case .tcp:
            TcpProbe(port: config.port!, host: config.host ?? "127.0.0.1")
        case .http:
            HttpProbe(url: config.url ?? "http://127.0.0.1:\(config.port!)/health")
        case .stdoutRegex:
            StdoutProbe(pattern: config.pattern!)
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
