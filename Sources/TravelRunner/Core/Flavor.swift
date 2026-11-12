import Foundation

/// Which app this build is. One source makes two apps: Travel Runner, for
/// fb-travel-monolith, and Travel Runner Hackathon, for the hackathon fork
/// (fb-travel-monolith-hackathon), which also has the agent app.
///
/// The two apps keep their state apart (config, control port, tickets, update
/// feed), so a person can have both. They use the same service ports, so only
/// one of them can run a stack at a time (`SiblingRunner`).
enum Flavor: String, Sendable, CaseIterable {
    case standard
    case hackathon

    /// The key in Info.plist that `build.sh` and `release.sh` write.
    static let infoKey = "TRFlavor"
    /// For `swift run`, which has no Info.plist.
    static let environmentKey = "TRAVEL_RUNNER_FLAVOR"

    static let current = resolve(
        info: Bundle.main.infoDictionary,
        environment: ProcessInfo.processInfo.environment
    )

    /// Info.plist first, then the environment. An unknown value is the standard app.
    static func resolve(info: [String: Any]?, environment: [String: String]) -> Flavor {
        if let value = info?[infoKey] as? String, let flavor = Flavor(rawValue: value) { return flavor }
        if let value = environment[environmentKey], let flavor = Flavor(rawValue: value) { return flavor }
        return .standard
    }

    var displayName: String {
        switch self {
        case .standard: "Travel Runner"
        case .hackathon: "Travel Runner Hackathon"
        }
    }

    /// The repo this app runs, as people know it.
    var monorepoName: String {
        switch self {
        case .standard: "fb-travel-monolith"
        case .hackathon: "fb-travel-monolith-hackathon"
        }
    }

    /// Folder name for the config (`~/.config/<name>`) and the caches.
    var storageName: String {
        switch self {
        case .standard: "travel-runner"
        case .hackathon: "travel-runner-hackathon"
        }
    }

    var bundleID: String { "ai.fastbreak.\(storageName)" }

    var controlPort: UInt16 {
        switch self {
        case .standard: 19900
        case .hackathon: 19901
        }
    }

    var controlURL: String { "http://[::1]:\(controlPort)" }

    /// The other app. It can hold the service ports.
    var sibling: Flavor {
        switch self {
        case .standard: .hackathon
        case .hackathon: .standard
        }
    }

    /// Folder on the Desktop for the debug tickets.
    var debugTrackingFolder: String {
        switch self {
        case .standard: "debug-tracking"
        case .hackathon: "debug-tracking-hackathon"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .standard: "suitcase.rolling.fill"
        case .hackathon: "trophy.fill"
        }
    }

    /// Control-Shift and this key show or hide the window. Each app has its own
    /// key, or one press would toggle the two windows.
    var hotkeyCharacter: String {
        switch self {
        case .standard: "t"
        case .hackathon: "h"
        }
    }

    /// The fork has `apps/amateur-agent`; the runner starts it as a service.
    var runsAgent: Bool { self == .hackathon }

    /// The Rooms tab shows the monolith's holds viewer, which the fork does not have.
    var hasRoomsTab: Bool { self == .standard }
}
