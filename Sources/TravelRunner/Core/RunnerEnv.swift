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
    enum App: String, Sendable { case booking, partner }
    enum Mode: Sendable { case local, remote }

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
        hostedLoginURL: String? = nil
    ) -> [(String, String)] {
        let supabaseURL = "http://\(host):54321"
        let loginURL = "http://\(host):3000/login/init"
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
            }
        }
        return values
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
            let raw = line[line.index(after: line.firstIndex(of: "=")!)...].trimmingCharacters(in: .whitespaces)
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}
