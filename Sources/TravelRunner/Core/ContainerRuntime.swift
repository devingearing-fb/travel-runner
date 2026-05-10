import Foundation

enum ContainerRuntime: Sendable {
    case docker
    case orbstack

    var displayName: String {
        switch self {
        case .docker: "Docker Desktop"
        case .orbstack: "OrbStack"
        }
    }

    var appName: String {
        switch self {
        case .docker: "Docker"
        case .orbstack: "OrbStack"
        }
    }

    static func detect() -> ContainerRuntime {
        if FileManager.default.fileExists(atPath: "/Applications/OrbStack.app") {
            return .orbstack
        }
        return .docker
    }
}
