import Foundation

/// Which part of the service graph `start-all` brings up.
enum RunProfile: String, Codable, CaseIterable, Sendable {
    case booking
    case partner
    case both
    case full

    var displayName: String {
        switch self {
        case .booking: "Booking"
        case .partner: "Partner"
        case .both: "Booking + Partner"
        case .full: "Full (CDC + verification, experimental)"
        }
    }

    /// Canonical services in this profile. `full` is every canonical service.
    var baseServiceIDs: Set<String>? {
        switch self {
        case .booking: ["supabase", "universal-login", "stripe", "travel-portal"]
        case .partner: ["supabase", "universal-login", "partner-portal"]
        case .both: ["supabase", "universal-login", "stripe", "travel-portal", "partner-portal"]
        case .full: nil
        }
    }

    /// Services that start under this profile: the profile's canonical services plus
    /// any custom service whose dependencies all start too.
    func members(of services: [ServiceDefinition]) -> Set<String> {
        guard let base = baseServiceIDs else { return Set(services.map(\.id)) }
        var members = base.intersection(services.map(\.id))
        let custom = services.filter { !ServiceCatalog.canonicalIDs.contains($0.id) }
        var changed = true
        while changed {
            changed = false
            for service in custom where !members.contains(service.id) {
                if service.dependsOn.allSatisfy(members.contains) {
                    members.insert(service.id)
                    changed = true
                }
            }
        }
        return members
    }
}

/// The canonical service graph for the fb-travel monorepo, built from repo paths.
/// It is regenerated on every config load, so the code is the single source of truth.
enum ServiceCatalog {
    static let canonicalIDs: Set<String> = [
        "supabase", "universal-login", "stripe", "travel-portal", "partner-portal",
        "stream-services-install", "stream-qstash", "stream-db-setup", "stream-services",
        "stream-qstash-wire", "stream-sequin",
        "cache-apply-transport", "cache-cdc-rehearsal", "cache-cutover-audit",
        "capacity-contention", "capacity-block-edit-race", "capacity-overflow",
    ]

    /// Services of the old three-repo layout that a config upgrade drops.
    static let retiredIDs: Set<String> = ["yalc-link"]

    static let cacheApplySecret = "p5-runner-local-current-secret"

    static func services(paths: RepoPaths) -> [ServiceDefinition] {
        let monorepo = expand(paths.monorepo ?? "")
        let booking = (monorepo as NSString).appendingPathComponent("apps/booking-portal")
        let partner = (monorepo as NSString).appendingPathComponent("apps/partner-portal")
        let login = expand(paths.universalLogin ?? "")
        let stream = expand(paths.streamServices ?? "")
        let loadTest = expand(paths.loadTest ?? "")
        let bookingEnvFile = "--env-file=" + (booking as NSString).appendingPathComponent(".env.local")
        let qstashToken = "eyJVc2VySUQiOiJkZWZhdWx0VXNlciIsIlBhc3N3b3JkIjoiZGVmYXVsdFBhc3N3b3JkIn0="

        return [
            service("supabase", "Supabase", ["pnpm", "db:start"], cwd: monorepo,
                    probe: tcp(54322, timeout: 300), restart: .onFailure, phase: "ground", reuse: true),
            service("universal-login", "Universal Login", ["npm", "run", "dev"], cwd: login,
                    probe: tcp(3000), restart: .onFailure, phase: "gateway", dependsOn: ["supabase"]),
            service("stripe", "Stripe CLI",
                    ["stripe", "listen", "--forward-to", "http://localhost:3002/api/webhooks/stripe"],
                    probe: ProbeConfig(type: .stdoutRegex, port: nil, host: nil, url: nil,
                                       pattern: "whsec_[A-Za-z0-9]+", artifact: "STRIPE_WEBHOOK_SECRET", timeout: nil),
                    restart: .onFailure, phase: "gateway", dependsOn: ["universal-login"]),
            service("travel-portal", "Travel Portal", ["pnpm", "dev"], cwd: booking,
                    probe: http("http://127.0.0.1:3002/api/health", port: 3002, timeout: 240),
                    restart: .onFailure, phase: "portal", dependsOn: ["universal-login", "stripe"],
                    env: [
                        "PINO_PRETTY": "false",
                        "CACHE_APPLY_MODE": "full",
                        "CACHE_APPLY_SECRET_CURRENT": cacheApplySecret,
                        "CACHE_APPLY_RATE_LIMIT_PER_MINUTE": "2000",
                    ]),
            service("partner-portal", "Partner Portal", ["pnpm", "dev"], cwd: partner,
                    probe: http("http://127.0.0.1:3006/api/health", port: 3006, timeout: 240),
                    restart: .onFailure, phase: "portal", dependsOn: ["universal-login"]),

            // Local CDC: production logic runs in stream-services; the local
            // infrastructure scripts live in (and run from) the booking app.
            service("stream-services-install", "Stream Services Install",
                    ["npm", "install", "--prefer-offline", "--no-audit", "--no-fund"], cwd: stream,
                    type: .oneshot, restart: .never, phase: "stream", dependsOn: ["supabase"]),
            service("stream-qstash", "Local QStash", ["./node_modules/.bin/qstash", "dev"], cwd: booking,
                    probe: tcp(8080, timeout: 120), restart: .onFailure, phase: "stream", dependsOn: ["supabase"]),
            service("stream-db-setup", "Stream CDC Database Setup", ["./scripts/local-cdc/runner-db-setup.sh"],
                    cwd: booking, type: .oneshot, restart: .never, phase: "stream",
                    dependsOn: ["supabase", "capacity-overflow"],
                    env: ["STREAM_SERVICES_DIR": stream]),
            service("stream-services", "Stream Services", ["npm", "run", "dev", "--", "-p", "3003"], cwd: stream,
                    probe: tcp(3003, timeout: 180), restart: .onFailure, phase: "stream",
                    dependsOn: ["stream-services-install", "stream-qstash", "stream-db-setup", "travel-portal"],
                    env: [
                        "PINO_PRETTY": "false",
                        "AMATEUR_QSTASH_URL": "http://127.0.0.1:8080",
                        "AMATEUR_QSTASH_TOKEN": qstashToken,
                        "AMATEUR_QSTASH_CURRENT_SIGNING_KEY": "sig_7kYjw48mhY7kAjqNGcy6cr29RJ6r",
                        "AMATEUR_QSTASH_NEXT_SIGNING_KEY": "sig_5ZB6DVzB1wjE8S6rZ7eenA8Pdnhs",
                        "AMATEUR_SEQUIN_CURRENT_SECRET": "local-dev-sequin-secret",
                        "TRAVEL_CACHE_APPLY_URL": "http://127.0.0.1:3002/api/cache/apply",
                        "CACHE_APPLY_SECRET_CURRENT": cacheApplySecret,
                    ]),
            service("stream-qstash-wire", "QStash Worker Wiring", ["./scripts/local-cdc/qstash-wire.sh"], cwd: booking,
                    type: .oneshot, restart: .never, phase: "stream", dependsOn: ["stream-qstash", "stream-services"],
                    env: ["STREAM_SERVICES_PORT": "3003"]),
            service("stream-sequin", "Local Sequin Cache CDC", ["./scripts/local-cdc/run-sequin.sh"], cwd: booking,
                    probe: tcp(7376, timeout: 300), restart: .onFailure, phase: "stream",
                    dependsOn: ["stream-db-setup", "stream-qstash-wire"]),

            // Verification oneshots (travel-load-test).
            service("cache-apply-transport", "Cache Apply Transport", ["npm", "run", "test:cache-transport:runner"],
                    cwd: loadTest, type: .oneshot, restart: .never, phase: "verification", dependsOn: ["travel-portal"],
                    env: ["CACHE_APPLY_BASE_URL": "http://127.0.0.1:3002", "CACHE_APPLY_SECRET": cacheApplySecret]),
            service("capacity-contention", "Capacity Contention E2E",
                    ["node", bookingEnvFile, "--import", "tsx", "scripts/blocking-contention-repro.ts"],
                    cwd: loadTest, type: .oneshot, restart: .never, phase: "verification",
                    dependsOn: ["cache-apply-transport"]),
            service("capacity-block-edit-race", "Capacity Block Edit Race",
                    ["node", bookingEnvFile, "--import", "tsx", "src/block-edit-race-orchestrator.ts"],
                    cwd: loadTest, type: .oneshot, restart: .never, phase: "verification",
                    dependsOn: ["capacity-contention"]),
            service("capacity-overflow", "Capacity Overflow E2E",
                    ["node", bookingEnvFile, "--import", "tsx", "scripts/overflow-display-audit.ts"],
                    cwd: loadTest, type: .oneshot, restart: .never, phase: "verification",
                    dependsOn: ["capacity-block-edit-race"]),
            service("cache-cdc-rehearsal", "Cache CDC Rehearsal", ["npm", "run", "test:cache-cdc:runner"],
                    cwd: loadTest, type: .oneshot, restart: .never, phase: "verification", dependsOn: ["stream-sequin"],
                    env: [
                        "CACHE_CDC_STREAM_URL": "http://127.0.0.1:3003",
                        "CACHE_CDC_QSTASH_URL": "http://127.0.0.1:8080",
                        "CACHE_CDC_PORTAL_URL": "http://127.0.0.1:3002",
                        "TRAVEL_RUNNER_CONTROL_URL": "http://[::1]:19900",
                    ]),
            service("cache-cutover-audit", "Cache Cutover Audit", ["npm", "run", "audit:p6"], cwd: loadTest,
                    type: .oneshot, restart: .never, phase: "verification",
                    dependsOn: ["cache-apply-transport", "cache-cdc-rehearsal"]),
        ]
    }

    static func expand(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func service(
        _ id: String,
        _ name: String,
        _ cmd: [String],
        cwd: String? = nil,
        probe: ProbeConfig? = nil,
        type: ServiceType? = nil,
        restart: RestartPolicy,
        phase: String,
        dependsOn: [String] = [],
        env: [String: String]? = nil,
        reuse: Bool? = nil
    ) -> ServiceDefinition {
        ServiceDefinition(
            id: id, name: name, cmd: cmd, cwd: cwd, probe: probe, type: type, restart: restart,
            dependsOn: dependsOn, env: env, phase: phase, reuseIfRunning: reuse
        )
    }

    private static func tcp(_ port: Int, timeout: Int? = nil) -> ProbeConfig {
        ProbeConfig(type: .tcp, port: port, host: nil, url: nil, pattern: nil, artifact: nil, timeout: timeout)
    }

    private static func http(_ url: String, port: Int, timeout: Int) -> ProbeConfig {
        // The port stays set so preflight and the occupant kill keep working.
        ProbeConfig(type: .http, port: port, host: nil, url: url, pattern: nil, artifact: nil, timeout: timeout)
    }
}
