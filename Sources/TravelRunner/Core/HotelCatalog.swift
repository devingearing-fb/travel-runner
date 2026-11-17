import Foundation

/// The hotel catalog of the local database and where its dump comes from.
///
/// The DB scripts of the checkout check the hotel source before a reset (`scripts/db`,
/// `check-prerequisites.mjs` and `fetch-hotels.mjs`). The runner shows what they found,
/// offers the way out, and looks at the catalog after Start.
enum HotelCatalog {
    // MARK: - The source, before a reset

    /// The keys of the shared `.env` that the hotel download needs. All three must be set.
    static let devKeys = AgentEnv.supabaseKeys

    /// The shared env files that the download reads, in its order.
    static let sharedEnvFiles = ["apps/booking-portal/.env", "apps/partner-portal/.env"]

    /// True when one shared env file sets all three dev keys, as the download asks.
    static func devKeysPresent(monorepo: String) -> Bool {
        sharedEnvFiles.contains { relative in
            let path = (monorepo as NSString).appendingPathComponent(relative)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            let values = AgentEnv.parse(content, dialect: .shared)
            return devKeys.allSatisfy { !(values[$0] ?? "").isEmpty }
        }
    }

    /// The exit codes of the scripts when the hotels cannot be had: no credentials (10),
    /// refused (11), network (12), nothing to download (13).
    static let sourceExitCodes: ClosedRange<Int32> = 10...13

    /// The steps that check or fetch the hotels before the reset.
    static let sourceStepIDs: Set<String> = ["check-prerequisites", "fetch-hotels"]

    static let cannotDownloadPrefix = "Hotels cannot be downloaded yet: "

    static func cannotDownloadText(reason: String) -> String {
        let reason = reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return "\(cannotDownloadPrefix)\(reason). Nothing was reset."
    }

    /// The banner text when a step stopped a reset because the hotels cannot be had, or
    /// nil. `resetRan` is true when the reset step of the run passed: then the database
    /// was changed, and this banner is not the one to show.
    static func sourceFailure(stepID: String, exitCode: Int32?, message: String?, resetRan: Bool) -> String? {
        guard sourceStepIDs.contains(stepID), !resetRan,
              let exitCode, sourceExitCodes.contains(exitCode) else { return nil }
        let message = (message ?? "").trimmingCharacters(in: .whitespaces)
        // check-prerequisites gives the whole line itself.
        if let range = message.range(of: cannotDownloadPrefix) {
            return String(message[range.lowerBound...])
        }
        return cannotDownloadText(reason: message.isEmpty ? "exit code \(exitCode)" : message)
    }

    static let importButtonTitle = "Import shared .env…"
    static let resetWithoutHotelsTitle = "Reset without hotels"
    /// The manifest profile that resets and seeds without the hotel steps.
    static let withoutHotelsProfile = "fast"
    static let noWithoutHotelsProfileText =
        "This branch has no reset without hotels (no \"fast\" profile in scripts/db/manifest.json). Nothing was changed."

    // MARK: - The Environment Check row

    /// The `##db:health:pass:` detail of `fetch-hotels.mjs --verify`, for example
    /// "Cached — 209,823 rows, 2026-08-11". Nil when the cached dump is not valid.
    static func cachedDetail(verifyOutput: String, succeeded: Bool) -> String? {
        guard succeeded else { return nil }
        let prefix = "##db:health:pass:"
        return verifyOutput.split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    static let noSourceText =
        "No cached hotel dump, and no dev keys in the shared .env (AMATEUR_SUPABASE_URL, ANON_KEY, SIGNING_KEY) — import apps/booking-portal/.env"
    static let keysOnlyText = "Not cached — the shared .env has the dev keys; the first reset downloads the hotels (3–5 min)"

    /// The row "Hotel catalog source". It passes on a valid cached dump, or when the
    /// shared env has the three keys the download needs.
    static func sourceStatus(cached: String?, keysPresent: Bool) -> CheckStatus {
        if let cached { return .passing(cached) }
        return keysPresent ? .passing(keysOnlyText) : .failing(noSourceText)
    }

    // MARK: - The catalog, after Start

    /// Fewer hotels than this is an empty catalog: dev has about 200,000.
    static let minimumHotels = 100_000

    static let countSQL = "SELECT count(*) FROM fb_travel.travel_organizations"

    /// The count of the answer, or nil when the query failed.
    static func count(_ result: DbQueryResult) -> Int? {
        guard result.exitCode == 0, let line = DbQueryResult.lastLine(of: result.stdout) else { return nil }
        return Int(line)
    }

    /// `seed_state.hotels_skipped` of the answer of `SELECT row_to_json(s) …`: true when the
    /// last reset left the hotels out on purpose. Nil when no reset recorded it.
    static func hotelsSkipped(seedState output: String) -> Bool? {
        guard let line = DbQueryResult.lastLine(of: output),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return nil
        }
        return object["hotels_skipped"] as? Bool
    }

    /// The banner after Start when hotel search would find nothing.
    struct EmptyNotice: Equatable, Sendable {
        let count: Int

        var text: String {
            let number = count.formatted(.number.locale(Locale(identifier: "en_US")))
            return "Hotel catalog is empty (\(number) hotel\(count == 1 ? "" : "s")) — hotel search will return nothing."
        }
    }

    static let loadHotelsTitle = "Load hotels"

    /// Nil when the catalog is full, cannot be read, or a reset left the hotels out on
    /// purpose ("Reset without hotels"). A database that no runner reset counts as
    /// wanting hotels.
    static func emptyNotice(count: Int?, hotelsSkipped: Bool?) -> EmptyNotice? {
        guard let count, count < minimumHotels, hotelsSkipped != true else { return nil }
        return EmptyNotice(count: count)
    }
}
