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
            // The first result wins. Each path claims it before it cancels the
            // connection, so the cancel cannot change the outcome.
            let once = ResumeOnce(continuation)
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: endpointPort,
                using: .tcp
            )
            let queue = DispatchQueue(label: "tcp-probe-\(port)")

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(with: .ok)
                    connection.cancel()
                case .failed(let error), .waiting(let error):
                    once.resume(with: Self.outcome(of: error))
                    connection.cancel()
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 2) {
                once.resume(with: .timedOut)
                connection.cancel()
            }
        }
    }

    static func outcome(of error: NWError) -> ProbeOutcome {
        switch error {
        // A reset before the connection is ready is a refused connect too.
        case .posix(.ECONNREFUSED), .posix(.ECONNRESET): .refused
        case .posix(.ETIMEDOUT): .timedOut
        case .dns: .dnsError
        default: .other(error.localizedDescription)
        }
    }
}

/// Resumes the continuation with the first value only.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProbeOutcome, Never>?

    init(_ continuation: CheckedContinuation<ProbeOutcome, Never>) {
        self.continuation = continuation
    }

    func resume(with value: ProbeOutcome) {
        let pending: CheckedContinuation<ProbeOutcome, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}
