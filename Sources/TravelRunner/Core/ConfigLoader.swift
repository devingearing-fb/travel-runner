import Foundation

enum ConfigLoader {
    static let configDir = NSString(string: "~/.config/travel-runner").expandingTildeInPath
    static let configPath = (configDir as NSString).appendingPathComponent("services.json")

    static func load() throws -> ServiceConfig {
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw ConfigError.noConfig
        }
        let url = URL(fileURLWithPath: configPath)
        let original = try Data(contentsOf: url)
        let upgraded = try upgradedData(original)
        if upgraded != original {
            try upgraded.write(to: url, options: .atomic)
            print("[Config] Upgraded services.json to version 2")
        }
        return try JSONDecoder().decode(ServiceConfig.self, from: upgraded)
    }

    enum ConfigError: Error, CustomStringConvertible {
        case noConfig
        case missingBundledDefault

        var description: String {
            switch self {
            case .noConfig: "No services.json found — run setup first"
            case .missingBundledDefault: "Bundled default-services.json is missing"
            }
        }
    }

    private static func findBundledDefault() -> URL? {
        if let url = Bundle.main.url(forResource: "default-services", withExtension: "json") {
            return url
        }
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("TravelRunner_TravelRunner.bundle")
            .appendingPathComponent("default-services.json"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        // SPM debug builds
        if let url = Bundle.module.url(forResource: "default-services", withExtension: "json") {
            return url
        }
        return nil
    }

    static var isFirstRun: Bool {
        !FileManager.default.fileExists(atPath: configPath)
    }

    static func generate(from repos: DetectedRepos) throws {
        guard let bundledURL = findBundledDefault() else {
            throw ConfigError.missingBundledDefault
        }
        let portalPath = repos.bookingPortal ?? "~/path/to/travel-booking-portal"
        let loginPath = repos.universalLogin ?? "~/path/to/fb-amateur-universal-login"
        let streamPath = repos.streamServices ?? inferredStreamServicesPath(portalPath: portalPath)
        let loadTestPath = (portalPath as NSString)
            .deletingLastPathComponent
            .appending("/travel-load-test")

        let data = try Data(contentsOf: bundledURL)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var services = root["services"] as? [[String: Any]] else {
            throw ConfigError.missingBundledDefault
        }

        root["paths"] = [
            "travel_data": repos.travelData ?? "",
            "booking_portal": portalPath,
            "universal_login": loginPath,
            "partner_portal": repos.partnerPortal ?? "",
            "stream_services": streamPath,
        ]

        for index in services.indices {
            switch services[index]["id"] as? String {
            case "yalc-link":
                services[index]["cwd"] = repos.travelData ?? ""
            case "supabase", "travel-portal":
                services[index]["cwd"] = portalPath
            case "universal-login":
                services[index]["cwd"] = loginPath
            case "partner-portal":
                services[index]["cwd"] = repos.partnerPortal ?? ""
            case "cache-apply-transport", "cache-cdc-rehearsal", "cache-cutover-audit":
                services[index]["cwd"] = loadTestPath
            default:
                break
            }
        }
        root["services"] = services

        let configured = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        let upgraded = try upgradedData(configured, streamServicesPath: streamPath)

        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        try upgraded.write(to: URL(fileURLWithPath: configPath), options: .atomic)
        print("[Config] Generated services.json at \(configPath)")
    }

    private static let streamServiceIDs: Set<String> = [
        "stream-services-install",
        "stream-qstash",
        "stream-db-setup",
        "stream-services",
        "stream-qstash-wire",
        "stream-sequin",
        "cache-cdc-rehearsal",
    ]

    static func upgradedData(
        _ data: Data,
        streamServicesPath override: String? = nil
    ) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var services = root["services"] as? [[String: Any]] else {
            throw ConfigError.noConfig
        }
        var paths = root["paths"] as? [String: Any] ?? [:]
        let portalPath = (paths["booking_portal"] as? String)
            ?? services.first(where: { ($0["id"] as? String) == "travel-portal" })?["cwd"] as? String
            ?? "~/Documents/Codebases/TRAVEL BOOKING/travel-booking-portal"
        let streamPath = override
            ?? paths["stream_services"] as? String
            ?? inferredStreamServicesPath(portalPath: portalPath)
        let loadTestPath = services.first(where: { ($0["id"] as? String) == "cache-apply-transport" })?["cwd"] as? String
            ?? (portalPath as NSString).deletingLastPathComponent.appending("/travel-load-test")
        let preCDCDependency = services.contains { ($0["id"] as? String) == "capacity-overflow" }
            ? "capacity-overflow"
            : nil

        paths["stream_services"] = streamPath
        root["paths"] = paths
        root["version"] = 2

        services.removeAll { service in
            guard let id = service["id"] as? String else { return false }
            return streamServiceIDs.contains(id)
        }
        for index in services.indices {
            switch services[index]["id"] as? String {
            case "capacity-contention":
                services[index]["depends_on"] = ["cache-apply-transport"]
            case "cache-cutover-audit":
                services[index]["depends_on"] = ["cache-apply-transport", "cache-cdc-rehearsal"]
            default:
                break
            }
        }
        services.append(contentsOf: canonicalStreamServices(
            streamPath: streamPath,
            portalPath: portalPath,
            loadTestPath: loadTestPath,
            preCDCDependency: preCDCDependency
        ))
        root["services"] = services

        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private static func inferredStreamServicesPath(portalPath: String) -> String {
        let expandedPortal = NSString(string: portalPath).expandingTildeInPath
        let codebases = ((expandedPortal as NSString).deletingLastPathComponent as NSString)
            .deletingLastPathComponent
        let candidate = (codebases as NSString).appendingPathComponent("stream-services")
        let manifest = (candidate as NSString).appendingPathComponent("package.json")
        if FileManager.default.fileExists(atPath: manifest) {
            return candidate
        }
        return "~/Documents/Codebases/stream-services"
    }

    private static func canonicalStreamServices(
        streamPath: String,
        portalPath: String,
        loadTestPath: String,
        preCDCDependency: String?
    ) -> [[String: Any]] {
        let qstashToken = "eyJVc2VySUQiOiJkZWZhdWx0VXNlciIsIlBhc3N3b3JkIjoiZGVmYXVsdFBhc3N3b3JkIn0="
        let cacheSecret = "p5-runner-local-current-secret"
        let databaseDependencies = ["supabase"] + (preCDCDependency.map { [$0] } ?? [])
        return [
            [
                "id": "stream-services-install",
                "name": "Stream Services Install",
                "cmd": ["npm", "install", "--prefer-offline", "--no-audit", "--no-fund"],
                "cwd": streamPath,
                "type": "oneshot",
                "restart": "never",
                "phase": "stream",
                "depends_on": ["supabase"],
            ],
            [
                "id": "stream-qstash",
                "name": "Local QStash",
                "cmd": ["./node_modules/.bin/qstash", "dev"],
                "cwd": portalPath,
                "probe": ["type": "tcp", "port": 8080, "timeout": 120],
                "restart": "on-failure",
                "phase": "stream",
                "depends_on": ["supabase"],
            ],
            [
                "id": "stream-db-setup",
                "name": "Stream CDC Database Setup",
                "cmd": ["./scripts/local-cdc/runner-db-setup.sh"],
                "cwd": portalPath,
                "env": ["STREAM_SERVICES_DIR": streamPath],
                "type": "oneshot",
                "restart": "never",
                "phase": "stream",
                "depends_on": databaseDependencies,
            ],
            [
                "id": "stream-services",
                "name": "Stream Services",
                "cmd": ["npm", "run", "dev", "--", "-p", "3003"],
                "cwd": streamPath,
                "env": [
                    "PINO_PRETTY": "false",
                    "AMATEUR_QSTASH_URL": "http://127.0.0.1:8080",
                    "AMATEUR_QSTASH_TOKEN": qstashToken,
                    "AMATEUR_QSTASH_CURRENT_SIGNING_KEY": "sig_7kYjw48mhY7kAjqNGcy6cr29RJ6r",
                    "AMATEUR_QSTASH_NEXT_SIGNING_KEY": "sig_5ZB6DVzB1wjE8S6rZ7eenA8Pdnhs",
                    "AMATEUR_SEQUIN_CURRENT_SECRET": "local-dev-sequin-secret",
                    "TRAVEL_CACHE_APPLY_URL": "http://127.0.0.1:3002/api/cache/apply",
                    "CACHE_APPLY_SECRET_CURRENT": cacheSecret,
                ],
                "probe": ["type": "tcp", "port": 3003, "timeout": 180],
                "restart": "on-failure",
                "phase": "stream",
                "depends_on": ["stream-services-install", "stream-qstash", "stream-db-setup", "travel-portal"],
            ],
            [
                "id": "stream-qstash-wire",
                "name": "QStash Worker Wiring",
                "cmd": ["./scripts/local-cdc/qstash-wire.sh"],
                "cwd": portalPath,
                "env": ["STREAM_SERVICES_PORT": "3003"],
                "type": "oneshot",
                "restart": "never",
                "phase": "stream",
                "depends_on": ["stream-qstash", "stream-services"],
            ],
            [
                "id": "stream-sequin",
                "name": "Local Sequin Cache CDC",
                "cmd": ["./scripts/local-cdc/run-sequin.sh"],
                "cwd": portalPath,
                "probe": ["type": "tcp", "port": 7376, "timeout": 300],
                "restart": "on-failure",
                "phase": "stream",
                "depends_on": ["stream-db-setup", "stream-qstash-wire"],
            ],
            [
                "id": "cache-cdc-rehearsal",
                "name": "Cache CDC Rehearsal",
                "cmd": ["npm", "run", "test:cache-cdc:runner"],
                "cwd": loadTestPath,
                "env": [
                    "CACHE_CDC_STREAM_URL": "http://127.0.0.1:3003",
                    "CACHE_CDC_QSTASH_URL": "http://127.0.0.1:8080",
                    "CACHE_CDC_PORTAL_URL": "http://127.0.0.1:3002",
                    "TRAVEL_RUNNER_CONTROL_URL": "http://[::1]:19900",
                ],
                "type": "oneshot",
                "restart": "never",
                "phase": "verification",
                "depends_on": ["stream-sequin"],
            ],
        ]
    }

    private static func copyToUserConfig(from bundledURL: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }
        try fm.copyItem(at: bundledURL, to: URL(fileURLWithPath: configPath))
        print("[Config] Created default config at \(configPath)")
    }
}
