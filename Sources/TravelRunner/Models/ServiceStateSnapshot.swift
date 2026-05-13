import Foundation

struct ServiceStateSnapshot: Codable, Sendable {
    let id: String
    let phase: String
    let pid: Int32?
    let exitCode: Int32?
    let restartCount: Int
    let isCircuitBroken: Bool
    let uptimeSeconds: Int?
}
