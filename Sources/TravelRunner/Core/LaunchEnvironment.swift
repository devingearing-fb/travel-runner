import Foundation

/// What a launch can change from outside, for a run that must not touch the real
/// config or the real control port: the release smoke test (`scripts/smoke.sh`).
enum LaunchEnvironment {
    /// The folder of services.json, in place of `~/.config/<storage name>`.
    static let configDirKey = "TRAVEL_RUNNER_CONFIG_DIR"
    /// The port of the control API, in place of the port of the flavor.
    static let controlPortKey = "TRAVEL_RUNNER_CONTROL_PORT"
    /// `1` for a launch that nobody watches: no alert, no permission prompt, no window.
    static let smokeKey = "TRAVEL_RUNNER_SMOKE"

    /// An absolute path from the environment, or the folder of the flavor.
    static func configDir(
        flavor: Flavor = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let path = environment[configDirKey], path.hasPrefix("/") {
            return (path as NSString).standardizingPath
        }
        return NSString(string: "~/.config/\(flavor.storageName)").expandingTildeInPath
    }

    /// A port from 1 to 65535 from the environment, or the port of the flavor.
    static func controlPort(
        flavor: Flavor = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> UInt16 {
        if let text = environment[controlPortKey], let port = UInt16(text), port > 0 { return port }
        return flavor.controlPort
    }

    /// Where the services of this app find its control API.
    static func controlURL(
        flavor: Flavor = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        "http://[::1]:\(controlPort(flavor: flavor, environment: environment))"
    }

    static func isSmoke(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[smokeKey] == "1"
    }
}
