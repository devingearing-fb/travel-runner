import Foundation

/// Where the setup wizard is, in UserDefaults: whether it was completed, and the paths
/// typed so far. services.json is written only when the wizard completes, so a wizard
/// that stops at the checks leaves no config, and its paths come back as a draft.
///
/// Each value is kept per services.json path: a launch with another config folder
/// (`TRAVEL_RUNNER_CONFIG_DIR`, the smoke test) has its own state.
struct SetupState {
    static let completedKey = "setupCompleted"
    static let draftPathsKey = "setupDraftPaths"

    let defaults: UserDefaults
    let configPath: String

    static var live: SetupState {
        SetupState(defaults: .standard, configPath: ConfigLoader.configPath)
    }

    /// True once the wizard completed for this config. A config from before this state
    /// existed counts as completed: its user went through setup already.
    var completed: Bool {
        if let stored = (defaults.dictionary(forKey: Self.completedKey) as? [String: Bool])?[configPath] {
            return stored
        }
        let migrated = FileManager.default.fileExists(atPath: configPath)
        setCompleted(migrated)
        return migrated
    }

    /// The wizard ended with a saved config. The draft is no longer needed.
    func markCompleted() {
        setCompleted(true)
        draftPaths = nil
    }

    /// The paths typed in the wizard before it completed.
    var draftPaths: RepoPaths? {
        get {
            guard let data = (defaults.dictionary(forKey: Self.draftPathsKey) as? [String: Data])?[configPath] else {
                return nil
            }
            return try? JSONDecoder().decode(RepoPaths.self, from: data)
        }
        nonmutating set {
            var all = defaults.dictionary(forKey: Self.draftPathsKey) as? [String: Data] ?? [:]
            all[configPath] = newValue.flatMap { try? JSONEncoder().encode($0) }
            defaults.set(all, forKey: Self.draftPathsKey)
        }
    }

    /// The wizard opens at launch when there is no usable config, or when it never completed.
    static func opensWizard(needsSetup: Bool, completed: Bool) -> Bool {
        needsSetup || !completed
    }

    private func setCompleted(_ value: Bool) {
        var all = defaults.dictionary(forKey: Self.completedKey) as? [String: Bool] ?? [:]
        all[configPath] = value
        defaults.set(all, forKey: Self.completedKey)
    }
}
