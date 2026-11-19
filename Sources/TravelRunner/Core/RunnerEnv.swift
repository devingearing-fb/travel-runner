import Foundation

/// Keys of the running local Supabase stack (`scripts/local-db.sh status -o env`).
struct LocalSupabaseKeys: Sendable, Equatable {
    var anonKey: String
    var serviceRoleKey: String
    var jwtSecret: String
    var publishableKey: String?

    static func parse(statusEnv output: String) -> LocalSupabaseKeys? {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        guard let anon = values["ANON_KEY"], !anon.isEmpty,
              let service = values["SERVICE_ROLE_KEY"], !service.isEmpty,
              let secret = values["JWT_SECRET"], !secret.isEmpty else { return nil }
        return LocalSupabaseKeys(
            anonKey: anon, serviceRoleKey: service, jwtSecret: secret,
            publishableKey: values["PUBLISHABLE_KEY"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}

/// The runner's block in each app's `.env.local`.
///
/// Each app's shared dev values live in the monolith at `apps/<app>/.env` (a teammate's copy, or
/// `pnpm env:pull` from Doppler); the runner never holds them. Next.js loads `.env.local` over
/// `.env`. The runner owns a marked block at the end of `.env.local` with the machine-specific
/// values. Local mode overrides every shared value that points at hosted dev, including
/// `AMATEUR_SUPABASE_*`: booking only copies `LOCAL_SUPABASE_*` into those when they are unset,
/// and the shared `.env` sets them. Remote mode leaves Supabase to the shared `.env`.
enum RunnerEnv {
    enum App: String, Sendable { case booking, partner, core }
    enum Mode: Sendable { case local, remote }

    /// The staff provider of the local database. The servicing seed
    /// (`supabase/seeds/seed_reservation_servicing.sql`) marks its admins as a sign-in
    /// through `sso:local-demo`, and the partner portal and Travel Core take a user as
    /// staff only when `EMPLOYEE_SSO_PROVIDER_ID` is that provider exactly. Local mode
    /// only: the hosted dev database has the real provider, from the shared `.env`.
    static let localEmployeeSsoProviderID = "local-demo"

    /// What the env files give Travel Core. Its own Doppler config has no Supabase
    /// and no Statsig values; the partner portal's shared `.env` has them, for the
    /// same database and the same Statsig project. `scripts/env-mode.mjs` of the
    /// monolith writes the same block (`coreBlockValues`).
    struct CoreShared: Sendable, Equatable {
        /// The keys that `apps/travel-core/.env` sets with a value.
        var ownKeys: Set<String> = []
        /// The keys that a person set in `apps/travel-core/.env.local`, outside the block.
        var localKeys: Set<String> = []
        /// The values of the partner portal's shared `.env`, as the file has them
        /// (quotes and all): a quoted JSON signing key stays valid in a copy.
        var partner: [String: String] = [:]

        /// True when the app's own files set `key`: the block then writes no fallback for it.
        func isSet(_ key: String) -> Bool { ownKeys.contains(key) || localKeys.contains(key) }
    }

    /// Keys that Travel Core needs and its Doppler config does not hold, in write
    /// order. The block writes one only when the app's own files do not set it. The
    /// Statsig client key may be a placeholder (the server key must be a real one:
    /// with a made-up server key every page answers 500). The domain is the local
    /// one of platform-core's Caddyfile; without a domain the app rewrites its
    /// platform routes to "platform.undefined".
    static let coreFallbacks: [(String, String)] = [
        ("NEXT_PUBLIC_STATSIG_CLIENT_KEY", "client-local-placeholder"),
        ("NEXT_PUBLIC_FASTBREAK_DOMAIN", "fastbreak.test"),
    ]

    static let beginMarker = "# >>> travel-runner: managed block, rewritten on start and on mode changes"
    static let endMarker = "# <<< travel-runner"

    /// Every key the runner may write for an app, in any mode. Lines for these keys outside
    /// the block are removed, so the block is their only source in `.env.local`.
    static func managedKeys(for app: App) -> Set<String> {
        let supabase: Set<String> = [
            "AMATEUR_SUPABASE_URL", "AMATEUR_SUPABASE_ANON_KEY", "AMATEUR_SUPABASE_SIGNING_KEY",
            "NEXT_PUBLIC_SUPABASE_URL", "NEXT_PUBLIC_SUPABASE_ANON_KEY", "SUPABASE_URL",
            // Suffixed names written by older runners; doppler-env.sh refuses them.
            "AMATEUR_SUPABASE_URL_DEV", "AMATEUR_SUPABASE_ANON_KEY_DEV", "AMATEUR_SUPABASE_SIGNING_KEY_DEV",
        ]
        switch app {
        case .booking:
            return supabase.union([
                "LOCAL_SUPABASE_URL", "LOCAL_SUPABASE_ANON_KEY", "LOCAL_SUPABASE_SIGNING_KEY",
                "SUPABASE_SERVICE_ROLE_KEY", "NEXT_PUBLIC_LOCAL_DEV",
                "NEXT_PUBLIC_WEBAPP_URL", "LOGIN_URL", "NEXT_PUBLIC_TRAVEL_PARTNER_PORTAL_URL",
                "STRIPE_WEBHOOK_SECRET",
            ])
        case .partner:
            return supabase.union([
                "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY",
                "NEXT_PUBLIC_WEBAPP_URL", "NEXT_PUBLIC_VGS_EXPORT_BASE_URL",
                "NEXT_PUBLIC_TRAVEL_BOOKING_PORTAL_URL", "LOGIN_URL", "UNIVERSAL_LOGIN_URL",
                "EMPLOYEE_SSO_PROVIDER_ID",
            ])
        case .core:
            // The fallback keys (`coreFallbacks`, STATSIG_SERVER_KEY) are not here: the
            // block owns one only while it writes it, and a person's own line stays.
            return supabase.union([
                "NEXT_PUBLIC_APP_ENV", "NEXT_PUBLIC_BASE_URL", "NEXT_PUBLIC_TRAVEL_BOOKING_PORTAL_URL",
                "AUTH_COOKIE_DOMAIN", "LOGIN_URL", "EMPLOYEE_SSO_PROVIDER_ID",
            ])
        }
    }

    /// The block's values, in write order. `host` is `localhost` or the LAN IP.
    /// Local mode without keys (stack not up yet) writes only the non-Supabase values.
    /// `hostedLoginURL` is booking's login in remote mode (see `hostedLoginURL(bookingEnv:partnerEnv:)`);
    /// nil leaves the shared `.env` value.
    static func values(
        for app: App,
        mode: Mode,
        host: String,
        keys: LocalSupabaseKeys?,
        stripeWebhookSecret: String?,
        hostedLoginURL: String? = nil,
        core: CoreShared = CoreShared()
    ) -> [(String, String)] {
        let supabaseURL = "http://\(host):54321"
        let loginURL = "http://\(host):3000/login/init"
        if app == .core {
            return coreValues(mode: mode, host: host, keys: keys, shared: core, supabaseURL: supabaseURL, loginURL: loginURL)
        }
        var values: [(String, String)] = []

        if mode == .local, let keys {
            values += [
                ("AMATEUR_SUPABASE_URL", supabaseURL),
                ("AMATEUR_SUPABASE_ANON_KEY", keys.anonKey),
                ("AMATEUR_SUPABASE_SIGNING_KEY", keys.jwtSecret),
                ("NEXT_PUBLIC_SUPABASE_URL", supabaseURL),
                ("NEXT_PUBLIC_SUPABASE_ANON_KEY", keys.anonKey),
            ]
            switch app {
            case .booking:
                values += [
                    ("LOCAL_SUPABASE_URL", supabaseURL),
                    ("LOCAL_SUPABASE_ANON_KEY", keys.anonKey),
                    ("LOCAL_SUPABASE_SIGNING_KEY", keys.jwtSecret),
                    ("SUPABASE_URL", supabaseURL),
                    ("SUPABASE_SERVICE_ROLE_KEY", keys.serviceRoleKey),
                ]
            case .partner:
                values.append(("SUPABASE_URL", supabaseURL))
                if let publishable = keys.publishableKey {
                    values.append(("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY", publishable))
                }
            case .core:
                break
            }
        }

        switch app {
        case .booking:
            values += [
                ("NEXT_PUBLIC_WEBAPP_URL", "http://\(host):3002"),
                ("NEXT_PUBLIC_TRAVEL_PARTNER_PORTAL_URL", "http://\(host):3006"),
            ]
            if mode == .local {
                values.append(("LOGIN_URL", loginURL))
            } else if let hostedLoginURL {
                values.append(("LOGIN_URL", hostedLoginURL))
            }
            if mode == .local { values.append(("NEXT_PUBLIC_LOCAL_DEV", "true")) }
            if let stripeWebhookSecret { values.append(("STRIPE_WEBHOOK_SECRET", stripeWebhookSecret)) }
        case .partner:
            values += [
                ("NEXT_PUBLIC_WEBAPP_URL", "http://\(host):3006"),
                ("NEXT_PUBLIC_VGS_EXPORT_BASE_URL", "http://\(host):3006"),
                ("NEXT_PUBLIC_TRAVEL_BOOKING_PORTAL_URL", "http://\(host):3002"),
            ]
            // Remote mode keeps the hosted login from partner's shared .env (it sets both).
            if mode == .local {
                values += [("LOGIN_URL", loginURL), ("UNIVERSAL_LOGIN_URL", loginURL)]
                // The seed admins are staff only with the local provider. It is written
                // with the local stack's keys only: their logins live in the local
                // database. Remote mode does not write the key, so the shared value
                // (the real provider) applies.
                if keys != nil { values.append(("EMPLOYEE_SSO_PROVIDER_ID", localEmployeeSsoProviderID)) }
            }
        case .core:
            break
        }
        return values
    }

    /// The block of Travel Core, in the write order of `coreBlockValues` in the
    /// monolith's `scripts/env-mode.mjs`. The app runs by itself on its port: the
    /// base URL is that port, and the session cookie has no domain (a domain of a
    /// shared file, like `.fastbreak.test`, does not match localhost, and the app
    /// could then not renew its session). The app reads `LOGIN_URL` first, then
    /// `NEXT_PUBLIC_UNIVERSAL_AUTH_URL`. In remote mode, what the app's own `.env`
    /// does not set comes from the partner portal (the same database and login).
    private static func coreValues(
        mode: Mode, host: String, keys: LocalSupabaseKeys?, shared: CoreShared, supabaseURL: String, loginURL: String
    ) -> [(String, String)] {
        var values: [(String, String)] = []
        func copy(_ key: String) {
            if let value = shared.partner[key] { values.append((key, value)) }
        }
        let supabase = ["AMATEUR_SUPABASE_URL", "AMATEUR_SUPABASE_ANON_KEY", "AMATEUR_SUPABASE_SIGNING_KEY"]
        if mode == .local, let keys {
            values += [
                ("AMATEUR_SUPABASE_URL", supabaseURL),
                ("AMATEUR_SUPABASE_ANON_KEY", keys.anonKey),
                ("AMATEUR_SUPABASE_SIGNING_KEY", keys.jwtSecret),
            ]
        } else if mode == .remote, !shared.ownKeys.contains("AMATEUR_SUPABASE_URL") {
            supabase.forEach(copy)
        }
        if mode == .local || !shared.ownKeys.contains("NEXT_PUBLIC_APP_ENV") {
            values.append(("NEXT_PUBLIC_APP_ENV", "local"))
        }
        values += [
            ("NEXT_PUBLIC_BASE_URL", "http://\(host):\(ServiceCatalog.travelCorePort)"),
            ("NEXT_PUBLIC_TRAVEL_BOOKING_PORTAL_URL", "http://\(host):3002"),
            ("AUTH_COOKIE_DOMAIN", ""),
        ]
        switch mode {
        case .local:
            values.append(("LOGIN_URL", loginURL))
            // With the local stack's keys only: the seed's staff logins live in the local database.
            if keys != nil { values.append(("EMPLOYEE_SSO_PROVIDER_ID", localEmployeeSsoProviderID)) }
        case .remote:
            if !shared.ownKeys.contains("LOGIN_URL"), !shared.ownKeys.contains("NEXT_PUBLIC_UNIVERSAL_AUTH_URL") {
                copy("LOGIN_URL")
            }
            if !shared.ownKeys.contains("EMPLOYEE_SSO_PROVIDER_ID") { copy("EMPLOYEE_SSO_PROVIDER_ID") }
        }
        if !shared.isSet("STATSIG_SERVER_KEY") { copy("STATSIG_SERVER_KEY") }
        for (key, value) in coreFallbacks where !shared.isSet(key) {
            values.append((key, value))
        }
        return values
    }

    /// The Redis of the holds and of the capacity cache. The booking portal and the
    /// partner portal change the same inventory, so both must use one instance.
    static let redisURLKey = "UPSTASH_REDIS_REST_URL"

    /// The value that an app reads for `key`: its `.env.local` wins over its `.env`,
    /// and the last assignment of a file wins. Quotes are removed. Nil when no file sets it.
    static func effectiveValue(of key: String, env: String, envLocal: String) -> String? {
        guard let raw = rawValues(in: envLocal)[key] ?? rawValues(in: env)[key] else { return nil }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// The warning when the two portals read different Redis instances, or nil. A
    /// hold that staff place in the partner portal then never reaches the guests of
    /// the booking portal, and each portal shows its own room counts. Only the
    /// hosts are named: a URL of Upstash has no secret.
    static func redisMismatch(booking: String?, partner: String?) -> String? {
        guard let booking, let partner, booking != partner else { return nil }
        func host(_ url: String) -> String { URL(string: url)?.host ?? url }
        return "The booking portal and the partner portal use different Redis instances "
            + "(\(host(booking)) and \(host(partner))): holds and room counts of one do not reach the other. "
            + "Set the same \(redisURLKey) and UPSTASH_REDIS_REST_TOKEN in both apps: "
            + "remove the line from the .env.local that differs from the shared .env, then restart the two portals."
    }

    /// The lines of a dotenv text that are outside the runner block: what a person wrote.
    static func outsideBlock(_ text: String) -> String {
        var kept: [String] = []
        var insideBlock = false
        for line in text.components(separatedBy: "\n") {
            if line == beginMarker { insideBlock = true; continue }
            if insideBlock {
                if line == endMarker { insideBlock = false }
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// The keys that a dotenv text sets with a value, with the right-hand side as
    /// the text has it (quotes and all). The last assignment of a key wins, as in dotenv.
    static func rawValues(in text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.components(separatedBy: "\n") {
            guard let key = assignedKey(line), let eq = line.firstIndex(of: "=") else { continue }
            let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).isEmpty {
                values[key] = nil
            } else {
                values[key] = raw
            }
        }
        return values
    }

    static func rawValues(inFile path: String) -> [String: String] {
        (try? String(contentsOfFile: path, encoding: .utf8)).map(rawValues(in:)) ?? [:]
    }

    /// The hosted login booking needs in remote mode, from the monolith's shared files.
    /// nil when booking's own `.env` sets `LOGIN_URL` (that value applies) or when neither does.
    /// The dev Doppler config sets it only for partner, so booking borrows partner's value.
    static func hostedLoginURL(bookingEnv: String, partnerEnv: String) -> String? {
        if let own = value(of: "LOGIN_URL", inFile: bookingEnv), !own.isEmpty { return nil }
        guard let partner = value(of: "LOGIN_URL", inFile: partnerEnv), !partner.isEmpty else { return nil }
        return partner
    }

    /// `existing` with the old block and stray managed keys removed and the new block appended.
    static func render(existing: String, values: [(String, String)], managedKeys: Set<String>) -> String {
        var kept: [String] = []
        var insideBlock = false
        for line in existing.components(separatedBy: "\n") {
            if line == beginMarker { insideBlock = true; continue }
            if insideBlock {
                if line == endMarker { insideBlock = false }
                continue
            }
            if let key = assignedKey(line), managedKeys.contains(key) { continue }
            kept.append(line)
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty { kept.removeLast() }
        guard !values.isEmpty else { return kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n" }

        var lines = kept
        if !lines.isEmpty { lines.append("") }
        lines.append(beginMarker)
        lines += values.map { "\($0.0)=\($0.1)" }
        lines.append(endMarker)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the block into `path` (creating the file), leaving other lines alone.
    @discardableResult
    static func apply(path: String, app: App, values: [(String, String)]) -> Bool {
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let updated = render(existing: existing, values: values, managedKeys: managedKeys(for: app))
        guard updated != existing else { return true }
        do {
            try updated.write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("[RunnerEnv] Failed to write \(path): \(error)")
            return false
        }
    }

    /// The key a `KEY=value` (or `export KEY=value`) line assigns, if any.
    static func assignedKey(_ line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return nil }
        if trimmed.hasPrefix("export ") { trimmed = String(trimmed.dropFirst("export ".count)) }
        guard let eq = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    /// Reads one key from a dotenv file.
    static func value(of key: String, inFile path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: "\n") where assignedKey(line) == key {
            return value(of: key, inLine: line)
        }
        return nil
    }

    private static func value(of key: String, inLine line: String) -> String? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
}
