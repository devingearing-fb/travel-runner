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

    /// True when the Docker daemon answers.
    static func isResponding() async -> Bool {
        await shell("docker ps >/dev/null 2>&1")
    }

    /// Opens the runtime's app when the daemon does not answer, then waits for it
    /// (two seconds between checks). Returns false when it did not come up.
    static func ensureRunning(checks: Int = 10) async -> Bool {
        if await isResponding() { return true }
        _ = await shell("open -a '\(detect().appName)'")
        for _ in 0..<checks {
            try? await Task.sleep(for: .seconds(2))
            if await isResponding() { return true }
        }
        return false
    }

    private static func shell(_ command: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do { try process.run() } catch { continuation.resume(returning: false) }
        }
    }
}
