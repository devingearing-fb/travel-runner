import Foundation

/// Each app's shared dev values live in the monolith at `apps/<app>/.env`: a teammate's copy, or
/// `pnpm env:pull` from Doppler. The monolith's `scripts/env-check.mjs` decides what a complete file
/// holds (the keys `.env.example` tags `# shared`). The runner runs that script and copies a file
/// the developer picks. It never stores or shows values; the script reports key names only.
enum SharedEnvFiles {
    enum App: String, Sendable, CaseIterable {
        case booking, partner

        var directory: String { self == .booking ? "apps/booking-portal" : "apps/partner-portal" }
        var label: String { self == .booking ? "Booking" : "Partner" }
    }

    /// One app's entry in `env-check.mjs --json`.
    struct AppReport: Decodable, Sendable, Equatable {
        let app: String
        let exists: Bool
        let shared: Int
        let missing: [String]
        let blank: [String]
        let shadowed: [String]
        let ok: Bool
    }

    private struct Report: Decodable {
        let apps: [AppReport]
    }

    static let script = "scripts/env-check.mjs"

    /// The script's command for one app; `file` checks a candidate instead of the app's `.env`.
    static func command(monorepo: String, app: App, file: String? = nil) -> String {
        var argv = ["node", (monorepo as NSString).appendingPathComponent(script), "--json", "--app", app.rawValue]
        if let file { argv += ["--file", file] }
        return ShellQuote.join(argv)
    }

    /// The report in the script's output. A login shell can print lines before the JSON.
    static func decode(_ output: String, app: App) -> AppReport? {
        guard let start = output.firstIndex(of: "{"),
              let report = try? JSONDecoder().decode(Report.self, from: Data(output[start...].utf8)) else { return nil }
        return report.apps.first { $0.app == app.rawValue }
    }

    static func status(_ report: AppReport?) -> CheckStatus {
        guard let report else {
            return .warning("Could not run \(script) — pull the latest monorepo dev")
        }
        if !report.exists {
            return .warning("Missing — import the shared file. Local mode runs without it; remote mode needs it")
        }
        if report.ok { return .passing("All \(report.shared) shared keys") }
        if !report.missing.isEmpty {
            return .warning("Out of date: \(report.missing.count) of \(report.shared) shared keys missing (\(names(report.missing))) — import a fresh copy")
        }
        if !report.blank.isEmpty {
            return .warning("Blank shared keys: \(names(report.blank)) — import a fresh copy")
        }
        return .warning("Blank in .env.local, hiding the .env value: \(names(report.shadowed)) — delete those lines")
    }

    struct ImportPrompt: Equatable {
        let title: String
        let message: String
        /// False when the file is clearly not this app's shared file.
        let acceptable: Bool
    }

    static func importPrompt(_ report: AppReport, app: App, replacing: Bool) -> ImportPrompt {
        let found = report.shared - report.missing.count
        guard found > 0 else {
            return ImportPrompt(
                title: "Not a \(app.label.lowercased()) .env file",
                message: "This file sets none of the \(report.shared) shared \(app.label.lowercased()) keys. Is it the other app's file?",
                acceptable: false
            )
        }
        var lines = ["It sets \(found) of the \(report.shared) shared keys."]
        if !report.missing.isEmpty { lines.append("Missing: \(names(report.missing)).") }
        if !report.blank.isEmpty { lines.append("Blank: \(names(report.blank)).") }
        lines.append(replacing ? "It replaces the current \(app.directory)/.env." : "It becomes \(app.directory)/.env.")
        return ImportPrompt(title: "Import the shared \(app.label.lowercased()) .env?", message: lines.joined(separator: " "), acceptable: true)
    }

    private static func names(_ keys: [String]) -> String {
        keys.count > 3 ? keys.prefix(3).joined(separator: ", ") + " +\(keys.count - 3) more" : keys.joined(separator: ", ")
    }
}
