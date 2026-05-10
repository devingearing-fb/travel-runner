import SwiftUI

enum HealthStatus: String, Sendable {
    case stopped = "STOPPED"
    case starting = "STARTING"
    case healthy = "HEALTHY"
    case degraded = "DEGRADED"

    var color: Color {
        switch self {
        case .stopped: .gray
        case .starting: .orange
        case .healthy: .green
        case .degraded: .red
        }
    }

    var iconName: String {
        "circle.fill"
    }
}
