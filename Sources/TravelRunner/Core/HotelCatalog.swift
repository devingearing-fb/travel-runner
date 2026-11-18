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
    /// The step that loads the hotels. It downloads the dump first when none is cached.
    static let loadStepID = "load-hotels"

    static let cannotDownloadPrefix = "Hotels cannot be downloaded yet: "

    /// `nothingReset` is true for a stop before the reset.
    static func cannotDownloadText(reason: String, nothingReset: Bool = true) -> String {
        let reason = reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return "\(cannotDownloadPrefix)\(reason)." + (nothingReset ? " Nothing was reset." : "")
    }

    /// The banner when the hotels cannot be had.
    struct SourceNotice: Equatable, Sendable {
        let text: String
        /// A stop before the reset: nothing changed, and a reset without hotels is a
        /// way out. After a reset, or for "Load hotels", only the import is.
        let beforeReset: Bool
        /// The body of the "Reset without hotels…" confirmation.
        var resetConfirmation = HotelCatalog.withoutHotelsConfirmation(otherCheckout: nil)
    }

    /// The banner when a step stopped because the hotels cannot be had, or nil.
    /// `resetRan` is true when the reset step of the run passed: then the database was
    /// changed, and the stop before the reset is not the one to report.
    static func sourceFailure(stepID: String, exitCode: Int32?, message: String?, resetRan: Bool) -> SourceNotice? {
        guard let exitCode, sourceExitCodes.contains(exitCode) else { return nil }
        let message = (message ?? "").trimmingCharacters(in: .whitespaces)
        let reason = message.isEmpty ? "exit code \(exitCode)" : message
        if stepID == loadStepID {
            return SourceNotice(text: cannotDownloadText(reason: reason, nothingReset: false), beforeReset: false)
        }
        guard sourceStepIDs.contains(stepID), !resetRan else { return nil }
        // check-prerequisites gives the whole line itself.
        if let range = message.range(of: cannotDownloadPrefix) {
            return SourceNotice(text: String(message[range.lowerBound...]), beforeReset: true)
        }
        return SourceNotice(text: cannotDownloadText(reason: reason), beforeReset: true)
    }

    static let importButtonTitle = "Import shared .env…"
    static let resetWithoutHotelsTitle = "Reset without hotels"

    /// The body of the "Reset without hotels…" confirmation: the reset text, with the
    /// line about a database that another checkout built.
    static func withoutHotelsConfirmation(otherCheckout: String?) -> String {
        DbResetPolicy.resetConfirmation(otherCheckout: otherCheckout) + " No hotels are loaded."
    }
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

    /// "Cached — 209,823 rows, 2026-08-11" for a valid dump, or nil. It reads the dump
    /// of the app, or one still in the checkout (the next fetch moves it). The
    /// checkout's script decides if it is whole; a checkout without the script takes
    /// any file.
    static func readCachedDump(
        monorepo: String, dumpPath: String, shell: any CommandRunning, cwd: String?
    ) async -> String? {
        let exists = { FileManager.default.fileExists(atPath: $0) }
        let paths = [dumpPath, DbSetupRunner.checkoutHotelDumpPath(root: monorepo)]
        let script = (monorepo as NSString).appendingPathComponent("scripts/db/fetch-hotels.mjs")
        guard exists(script) else { return paths.contains(where: exists) ? "Cached" : nil }
        for path in paths where exists(path) {
            let result = await shell.run(
                EnvironmentChecker.hotelVerifyCommand(monorepo: monorepo, dump: path),
                cwd: cwd, timeout: EnvironmentChecker.checkTimeout
            )
            if let detail = cachedDetail(verifyOutput: result.stdout, succeeded: result.succeeded) {
                return detail
            }
        }
        return nil
    }

    /// The cached dump, for DB Tools and the reset confirmation.
    enum DumpState: Equatable, Sendable {
        /// Not read yet.
        case unknown
        /// A valid dump: the detail of `fetch-hotels.mjs --verify`.
        case cached(String)
        /// No valid dump: the next reset downloads one.
        case missing

        /// The hotel part of the reset confirmation. The minutes are estimates: the
        /// load of about 200,000 rows, and the download from dev before it.
        var resetLine: String {
            switch self {
            case .cached: "reload from cache (about \(HotelCatalog.reloadMinutes) min)"
            case .missing: "download from dev, then load (about \(HotelCatalog.downloadMinutes) min)"
            case .unknown:
                "reload from cache, or download first when none is cached (\(HotelCatalog.reloadMinutes)–\(HotelCatalog.downloadMinutes) min)"
            }
        }

        /// The text beside "Re-download hotels".
        var label: String {
            switch self {
            case .cached(let detail): detail
            case .missing: "No cached hotel dump"
            case .unknown: "Hotel dump not checked yet"
            }
        }
    }

    static let reloadMinutes = 3
    static let downloadMinutes = 8

    static let loadHotelsOnlyTitle = "Load hotels only"
    static let redownloadTitle = "Re-download hotels"
    /// The step that downloads the dump, and the flag that makes it download again.
    static let fetchStepID = "fetch-hotels"
    static let forceArgument = "--force"

    static let noSourceText =
        "No cached hotel dump, and no dev keys in the shared .env (AMATEUR_SUPABASE_URL, ANON_KEY, SIGNING_KEY) — import apps/booking-portal/.env"
    static let keysOnlyText = "Not cached — the shared .env has the dev keys; the first reset downloads the hotels (3–5 min)"

    /// The row "Hotel catalog source". It passes on a valid cached dump, or when the
    /// shared env has the three keys the download needs.
    static func sourceStatus(cached: String?, keysPresent: Bool) -> CheckStatus {
        if let cached { return .passing(cached) }
        return keysPresent ? .passing(keysOnlyText) : .failing(noSourceText)
    }

    // MARK: - The keys, tested

    /// True when the checkout's `fetch-hotels.mjs` has `--preflight`. An older script
    /// ignores the flag and downloads, so the runner never passes it to one.
    static func supportsPreflight(monorepo: String) -> Bool {
        let path = (monorepo as NSString).appendingPathComponent("scripts/db/fetch-hotels.mjs")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return content.contains("--preflight")
    }

    /// `fetch-hotels.mjs --preflight`: reads the keys and asks dev for one row. Downloads nothing.
    static func preflightCommand(monorepo: String, dump: String) -> String {
        "TRAVEL_HOTEL_DUMP=\(ShellQuote.quote(dump)) "
            + ShellQuote.join(["node", (monorepo as NSString).appendingPathComponent("scripts/db/fetch-hotels.mjs"), "--preflight"])
    }

    /// The script gives up after 25 s; this is the limit for a script that hangs.
    static let preflightTimeout: Duration = .seconds(30)

    static let keysAcceptedText =
        "Not cached — dev Supabase accepts the shared keys; the first reset downloads the hotels (3–5 min)"

    /// The hotel row when the shared keys were tested. Dev refusing them fails the row.
    /// No network only warns: the keys may be fine.
    static func preflightStatus(_ result: CommandResult) -> CheckStatus {
        if result.timedOut {
            return .warning("\(Shell.timeoutText("The test of the hotel keys", after: preflightTimeout)) — the keys are not checked")
        }
        if result.succeeded { return .passing(keysAcceptedText) }
        let prefix = "##db:health:fail:"
        let reason = result.stdout.split(whereSeparator: \.isNewline)
            .last { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? "fetch-hotels.mjs --preflight failed (exit \(result.exitCode))"
        if result.exitCode == 12 {
            return .warning("\(reason) — the keys are not checked")
        }
        return .failing(reason)
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
