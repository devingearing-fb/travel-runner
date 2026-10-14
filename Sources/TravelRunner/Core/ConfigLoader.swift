import Foundation

enum ConfigLoader {
    static let configDir = NSString(string: "~/.config/travel-runner").expandingTildeInPath
    static let configPath = (configDir as NSString).appendingPathComponent("services.json")
    static let currentVersion = 3

    static func load() throws -> ServiceConfig {
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw ConfigError.noConfig
        }
        let url = URL(fileURLWithPath: configPath)
        let original = try Data(contentsOf: url)
        let upgraded = try upgradedData(original)
        if upgraded != original {
            try upgraded.write(to: url, options: .atomic)
            print("[Config] Wrote services.json version \(currentVersion)")
        }
        return try JSONDecoder().decode(ServiceConfig.self, from: upgraded)
    }

    enum ConfigError: Error, CustomStringConvertible {
        case noConfig
        case monorepoNotFound

        var description: String {
            switch self {
            case .noConfig: "No services.json found — run setup first"
            case .monorepoNotFound: "services.json does not point at the fb-travel monorepo — run setup"
            }
        }
    }

    static var isFirstRun: Bool {
        !FileManager.default.fileExists(atPath: configPath)
    }

    /// True when there is no usable config: no file, or an old-layout file whose
    /// monorepo cannot be found. The setup wizard opens in both cases.
    static var needsSetup: Bool {
        guard let data = FileManager.default.contents(atPath: configPath) else { return true }
        return (try? upgradedData(data)) == nil
    }

    /// Paths from the current file, before any upgrade, to pre-fill the setup wizard.
    static func existingPaths() -> RepoPaths {
        guard let data = FileManager.default.contents(atPath: configPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RepoPaths()
        }
        if let config = try? JSONDecoder().decode(ServiceConfig.self, from: upgradedData(data)),
           let paths = config.paths {
            return paths
        }
        let services = root["services"] as? [[String: Any]] ?? []
        let paths = root["paths"] as? [String: Any] ?? [:]
        return RepoPaths(
            monorepo: nil,
            universalLogin: paths["universal_login"] as? String ?? cwd(of: "universal-login", in: services),
            streamServices: paths["stream_services"] as? String ?? cwd(of: "stream-services", in: services),
            loadTest: cwd(of: "cache-apply-transport", in: services)
        )
    }

    /// Writes a config for these paths. Custom services and the profile of an
    /// existing config are kept.
    static func generate(paths: RepoPaths) throws {
        var root: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: configPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        root["paths"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(paths))
        root["services"] = root["services"] ?? []
        let data = try upgradedData(JSONSerialization.data(withJSONObject: root))

        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        print("[Config] Generated services.json at \(configPath)")
    }

    /// Sets the profile in the config file.
    static func saveProfile(_ profile: RunProfile) throws {
        let url = URL(fileURLWithPath: configPath)
        guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ConfigError.noConfig
        }
        root["profile"] = profile.rawValue
        try upgradedData(JSONSerialization.data(withJSONObject: root)).write(to: url, options: .atomic)
    }

    /// Normalizes any config version to the current one. The canonical services are
    /// rebuilt from the paths on every call; custom services are kept as they are.
    /// A version 2 file (three sibling repos) is migrated by locating the monorepo
    /// next to its old booking-portal path.
    static func upgradedData(
        _ data: Data,
        findMonorepo: (String) -> String? = RepoDetector.findMonorepo(near:)
    ) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.noConfig
        }
        let rawServices = root["services"] as? [[String: Any]] ?? []
        let rawPaths = root["paths"] as? [String: Any] ?? [:]

        var monorepo = nonEmpty(rawPaths["monorepo"])
        if monorepo == nil {
            let oldPortal = nonEmpty(rawPaths["booking_portal"]) ?? cwd(of: "travel-portal", in: rawServices)
            monorepo = oldPortal.flatMap(findMonorepo)
        }
        guard let monorepo else { throw ConfigError.monorepoNotFound }

        let parent = (ServiceCatalog.expand(monorepo) as NSString).deletingLastPathComponent
        let paths = RepoPaths(
            monorepo: monorepo,
            universalLogin: nonEmpty(rawPaths["universal_login"])
                ?? cwd(of: "universal-login", in: rawServices)
                ?? "~/Documents/Codebases/fb-amateur-universal-login",
            streamServices: nonEmpty(rawPaths["stream_services"])
                ?? cwd(of: "stream-services", in: rawServices)
                ?? "~/Documents/Codebases/stream-services",
            loadTest: nonEmpty(rawPaths["load_test"])
                ?? cwd(of: "cache-apply-transport", in: rawServices)
                ?? (parent as NSString).appendingPathComponent("travel-load-test")
        )

        let excluded = ServiceCatalog.canonicalIDs.union(ServiceCatalog.retiredIDs)
        let customServices = try rawServices
            .filter { !excluded.contains($0["id"] as? String ?? "") }
            .map { try JSONDecoder().decode(ServiceDefinition.self, from: JSONSerialization.data(withJSONObject: $0)) }

        let profile = (root["profile"] as? String).flatMap(RunProfile.init(rawValue:)) ?? .both
        let config = ServiceConfig(
            version: currentVersion,
            registryPortRange: root["registry_port_range"] as? [Int] ?? [19999, 20009],
            services: ServiceCatalog.services(paths: paths) + customServices,
            paths: paths,
            profile: profile
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }

    private static func cwd(of id: String, in services: [[String: Any]]) -> String? {
        nonEmpty(services.first(where: { $0["id"] as? String == id })?["cwd"])
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
