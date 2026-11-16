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

    /// True when the Docker daemon answers. A daemon that hangs counts as down.
    static func isResponding(shell: any CommandRunning = LoginShell()) async -> Bool {
        await shell.run("docker ps >/dev/null 2>&1", timeout: .seconds(10)).succeeded
    }

    /// Opens the runtime's app when the daemon does not answer, then waits for it
    /// (two seconds between checks). Returns false when it did not come up.
    static func ensureRunning(checks: Int = 10, shell: any CommandRunning = LoginShell()) async -> Bool {
        if await isResponding(shell: shell) { return true }
        _ = await shell.run("open -a '\(detect().appName)'", timeout: .seconds(10))
        for _ in 0..<checks {
            try? await Task.sleep(for: .seconds(2))
            if await isResponding(shell: shell) { return true }
        }
        return false
    }
}
