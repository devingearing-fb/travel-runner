import Foundation
import Network

struct TcpProbe: Probe {
    let port: Int
    let host: String

    init(port: Int, host: String = "127.0.0.1") {
        self.port = port
        self.host = host
    }

    func outcome() async -> ProbeOutcome {
        // A number that is not a port has no listener.
        guard ProbeConfig.validPorts.contains(port),
              let endpointPort = UInt16(exactly: port).flatMap(NWEndpoint.Port.init(rawValue:)) else {
            return .other("\(port) is not a port")
        }
        return await withCheckedContinuation { continuation in
            let guard_ = ContinuationGuard()
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: endpointPort,
                using: .tcp
            )
            let queue = DispatchQueue(label: "tcp-probe-\(port)")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    Task { await guard_.resume(continuation, with: .ok) }
                case .failed(let error), .waiting(let error):
                    connection.cancel()
                    Task { await guard_.resume(continuation, with: Self.outcome(of: error)) }
                case .cancelled:
                    Task { await guard_.resume(continuation, with: .refused) }
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 2) {
                connection.cancel()
                Task { await guard_.resume(continuation, with: .timedOut) }
            }
        }
    }

    static func outcome(of error: NWError) -> ProbeOutcome {
        switch error {
        case .posix(.ECONNREFUSED): .refused
        case .posix(.ETIMEDOUT): .timedOut
        case .dns: .dnsError
        default: .other(error.localizedDescription)
        }
    }
}

private actor ContinuationGuard {
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<ProbeOutcome, Never>, with value: ProbeOutcome) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
