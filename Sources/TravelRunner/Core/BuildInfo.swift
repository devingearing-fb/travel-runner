import Foundation

/// Which build of the app this is: version, commit, flavor, and release or dev.
/// Settings, the menu, `/api/status` and the debug tickets all read it from here.
struct BuildInfo: Equatable, Sendable {
    /// `release.sh` writes `release`. `build.sh` writes `dev`. A dev build never updates itself.
    enum Kind: String, Sendable {
        case release
        case dev
    }

    /// The keys in Info.plist that `build.sh` and `release.sh` write.
    static let commitKey = "TRGitCommit"
    static let kindKey = "TRBuildKind"

    /// CFBundleShortVersionString. `nil` without an Info.plist (`swift run`, tests).
    let version: String?
    /// CFBundleVersion: the time of the build.
    let build: String?
    /// The short git commit. `nil` when the build did not come from a git checkout.
    let commit: String?
    let kind: Kind
    let flavor: Flavor

    static let current = resolve(info: Bundle.main.infoDictionary, flavor: .current)

    /// A build that does not say it is a release is a dev build.
    static func resolve(info: [String: Any]?, flavor: Flavor) -> BuildInfo {
        BuildInfo(
            version: text(info?["CFBundleShortVersionString"]),
            build: text(info?["CFBundleVersion"]),
            commit: text(info?[commitKey]),
            kind: text(info?[kindKey]).flatMap(Kind.init(rawValue:)) ?? .dev,
            flavor: flavor
        )
    }

    var isDev: Bool { kind == .dev }

    /// "v0.13.5 (a1b2c3d)"
    var versionLabel: String {
        let base = "v\(version ?? "?")"
        guard let commit else { return base }
        return "\(base) (\(commit))"
    }

    /// "v0.13.5 (a1b2c3d) · standard · release"
    var summary: String {
        "\(versionLabel) · \(flavor.rawValue) · \(kind.rawValue)"
    }

    /// The line in the menu bar menu.
    var menuTitle: String {
        "\(flavor.displayName) \(versionLabel)" + (isDev ? " · DEV" : "")
    }

    /// The build fields of `/api/status`. An unknown value is an empty string.
    var statusFields: [String: String] {
        [
            "version": version ?? "",
            "build": build ?? "",
            "commit": commit ?? "",
            "build_kind": kind.rawValue,
        ]
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else { return nil }
        return string
    }
}
