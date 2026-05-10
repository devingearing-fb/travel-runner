import Foundation

enum ConfigLoader {
    static let configDir = NSString(string: "~/.config/travel-runner").expandingTildeInPath
    static let configPath = (configDir as NSString).appendingPathComponent("services.json")

    static func load() throws -> ServiceConfig {
        guard FileManager.default.fileExists(atPath: configPath) else {
            throw ConfigError.noConfig
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        return try JSONDecoder().decode(ServiceConfig.self, from: data)
    }

    enum ConfigError: Error, CustomStringConvertible {
        case noConfig
        var description: String { "No services.json found — run setup first" }
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
        let portalPath = repos.bookingPortal ?? "~/path/to/travel-booking-portal"
        let loginPath = repos.universalLogin ?? "~/path/to/fb-amateur-universal-login"

        let config: [String: Any] = [
            "version": 1,
            "registry_port_range": [19999, 20009],
            "paths": [
                "travel_data": repos.travelData ?? "",
                "booking_portal": portalPath,
                "universal_login": loginPath
            ] as [String: Any],
            "services": [
                [
                    "id": "supabase",
                    "name": "Supabase",
                    "cmd": ["npx", "supabase", "start"],
                    "cwd": portalPath,
                    "probe": ["type": "tcp", "port": 54322, "timeout": 300],
                    "restart": "on-failure",
                    "phase": "ground",
                    "reuse_if_running": true,
                    "depends_on": [] as [String]
                ],
                [
                    "id": "yalc-link",
                    "name": "yalc Link",
                    "cmd": ["yalc", "link", "@fastbreak-amateur/fb-travel-data"],
                    "cwd": portalPath,
                    "type": "oneshot",
                    "phase": "gateway",
                    "depends_on": ["supabase"]
                ],
                [
                    "id": "universal-login",
                    "name": "Universal Login",
                    "cmd": ["npm", "run", "dev"],
                    "cwd": loginPath,
                    "probe": ["type": "tcp", "port": 3000],
                    "restart": "on-failure",
                    "phase": "gateway",
                    "depends_on": ["yalc-link"]
                ],
                [
                    "id": "stripe",
                    "name": "Stripe CLI",
                    "cmd": ["stripe", "listen", "--forward-to", "http://localhost:3002/api/webhooks/stripe"],
                    "probe": [
                        "type": "stdout_regex",
                        "pattern": "whsec_[A-Za-z0-9]+",
                        "artifact": "STRIPE_WEBHOOK_SECRET"
                    ] as [String: Any],
                    "restart": "on-failure",
                    "phase": "gateway",
                    "depends_on": ["universal-login"]
                ],
                [
                    "id": "travel-portal",
                    "name": "Travel Portal",
                    "cmd": ["npm", "run", "dev"],
                    "cwd": portalPath,
                    "probe": ["type": "tcp", "port": 3002],
                    "restart": "on-failure",
                    "phase": "portal",
                    "depends_on": ["stripe"]
                ]
            ] as [[String: Any]]
        ]

        let fm = FileManager.default
        if !fm.fileExists(atPath: configDir) {
            try fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        }

        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: configPath))
        print("[Config] Generated services.json at \(configPath)")
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
