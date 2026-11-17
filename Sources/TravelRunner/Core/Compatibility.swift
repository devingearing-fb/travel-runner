import Foundation

/// The contract between the runner and the checkout it runs. The checkout names the
/// oldest runner that may reset its database, in `scripts/db/manifest.json`:
///
///     "runner": { "minVersion": "0.14.0" }
///
/// An older runner still starts the services, but it runs no reset and no DB step.
enum Compatibility {
    /// Three numbers, compared in order.
    struct Version: Comparable, Equatable, Sendable {
        let major: Int
        let minor: Int
        let patch: Int

        /// The manifest value: exactly `x.y.z`, with no prefix, suffix or leading zero.
        init?(manifest text: String) {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            var numbers: [Int] = []
            for part in parts {
                guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                      part == "0" || part.first != "0",
                      let number = Int(part) else { return nil }
                numbers.append(number)
            }
            self.init(numbers)
        }

        /// The app's own version. A dev build has a suffix ("0.13.5-2-ga1b2c3d-dirty"),
        /// and only the numbers before it count. A missing number is 0.
        init?(runner text: String) {
            let head = text.trimmingCharacters(in: .whitespaces).prefix { $0 == "." || ($0.isASCII && $0.isNumber) }
            let parts = head.split(separator: ".", omittingEmptySubsequences: false).prefix(3)
            guard !parts.isEmpty else { return nil }
            var numbers: [Int] = []
            for part in parts {
                guard let number = Int(part) else { return nil }
                numbers.append(number)
            }
            while numbers.count < 3 { numbers.append(0) }
            self.init(numbers)
        }

        private init(_ numbers: [Int]) {
            major = numbers[0]
            minor = numbers[1]
            patch = numbers[2]
        }

        static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
    }

    /// What the manifest says about the runner.
    enum Requirement: Equatable, Sendable {
        /// No manifest, no `runner` section, or no `minVersion` in it.
        case none
        case minVersion(String)
        /// A `runner` section or a `minVersion` that is not what the contract allows.
        case unreadable(String)
    }

    enum Verdict: Equatable, Sendable {
        case compatible
        case runnerTooOld(required: String, current: String)
        /// The checkout names a minimum that this runner cannot compare. A newer
        /// contract is the likely cause, so this blocks resets too.
        case unreadableRequirement(value: String, current: String)

        var blocksResets: Bool { self != .compatible }
    }

    /// The banner, and the answer of the control API, while resets are blocked.
    struct Notice: Equatable, Sendable {
        let text: String
        /// Where to get the newest release without the in-app updater. An old copy
        /// may not see updates.
        let downloadURL: URL
    }

    static var updateButtonTitle: String { "Update \(Flavor.current.displayName)" }
    static let downloadLinkTitle = "Download the newest release"

    // MARK: - Reading the manifest

    static func manifestPath(root: String) -> String {
        (root as NSString).appendingPathComponent("scripts/db/manifest.json")
    }

    /// A manifest that is absent or is not JSON gives `.none`: the DB setup reports
    /// that problem itself.
    static func requirement(manifestPath: String) -> Requirement {
        guard let data = FileManager.default.contents(atPath: manifestPath) else { return .none }
        return requirement(manifest: data)
    }

    static func requirement(manifest data: Data) -> Requirement {
        guard let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let section = manifest["runner"], !(section is NSNull) else { return .none }
        guard let runner = section as? [String: Any] else { return .unreadable("\(section)") }
        guard let value = runner["minVersion"], !(value is NSNull) else { return .none }
        guard let text = value as? String else { return .unreadable("\(value)") }
        return Version(manifest: text) == nil ? .unreadable(text) : .minVersion(text)
    }

    // MARK: - The check

    /// The version that the check compares, or nil for a build that is never
    /// blocked. A dev build (`build.sh`) is named by `git describe`
    /// ("0.13.5-12-ga1b2c3d"): its number is the last tag, not what the source can
    /// do. The person who built it has the source, so it is not blocked.
    static func comparableVersion(of build: BuildInfo) -> String? {
        build.isDev ? nil : build.version
    }

    /// `runnerVersion` is nil for a dev build and without an Info.plist (`swift run`,
    /// tests). Such a copy has no version to compare, so it is not blocked.
    static func check(requirement: Requirement, runnerVersion: String?) -> Verdict {
        guard let runnerVersion, let current = Version(runner: runnerVersion) else { return .compatible }
        switch requirement {
        case .none:
            return .compatible
        case .unreadable(let value):
            return .unreadableRequirement(value: value, current: runnerVersion)
        case .minVersion(let text):
            guard let required = Version(manifest: text) else {
                return .unreadableRequirement(value: text, current: runnerVersion)
            }
            return current < required ? .runnerTooOld(required: text, current: runnerVersion) : .compatible
        }
    }

    static func check(root: String, runnerVersion: String?) -> Verdict {
        check(requirement: requirement(manifestPath: manifestPath(root: root)), runnerVersion: runnerVersion)
    }

    // MARK: - What the person reads

    /// Nil when the runner may reset this checkout.
    static func notice(for verdict: Verdict, flavor: Flavor = .current) -> Notice? {
        let text: String
        switch verdict {
        case .compatible:
            return nil
        case .runnerTooOld(let required, let current):
            text = "This \(flavor.monorepoName) checkout needs \(flavor.displayName) \(required) or newer "
                + "(you have \(current)). The database was not touched."
        case .unreadableRequirement(let value, let current):
            text = "This \(flavor.monorepoName) checkout names a \(flavor.displayName) version that this copy "
                + "cannot read (\"\(value)\"; you have \(current)). The database was not touched."
        }
        return Notice(text: text, downloadURL: downloadURL(flavor: flavor))
    }

    /// The releases of the runner, which is a public repository. The hackathon app is
    /// never the latest release, so its link is the list.
    static func downloadURL(flavor: Flavor) -> URL {
        switch flavor {
        case .standard: URL(string: "https://github.com/devingearing-fb/travel-runner/releases/latest")!
        case .hackathon: URL(string: "https://github.com/devingearing-fb/travel-runner/releases")!
        }
    }
}
