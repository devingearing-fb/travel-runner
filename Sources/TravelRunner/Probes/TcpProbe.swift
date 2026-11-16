import Foundation
import Network

struct TcpProbe: Probe {
    let port: Int
    let host: String

    init(port: Int, host: String = "127.0.0.1") {
        self.port = port
        self.host = host
    }

    func check() async -> Bool {
        // A number that is not a port has no listener.
        guard ProbeConfig.validPorts.contains(port),
              let endpointPort = UInt16(exactly: port).flatMap(NWEndpoint.Port.init(rawValue:)) else { return false }
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
                    Task { await guard_.resume(continuation, with: true) }
                case .failed, .cancelled:
                    Task { await guard_.resume(continuation, with: false) }
                case .waiting:
                    connection.cancel()
                    Task { await guard_.resume(continuation, with: false) }
                default:
                    break
                }
            }

            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 2) {
                connection.cancel()
                Task { await guard_.resume(continuation, with: false) }
            }
        }
    }
}

private actor ContinuationGuard {
    private var resumed = false

    func resume(_ continuation: CheckedContinuation<Bool, Never>, with value: Bool) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
