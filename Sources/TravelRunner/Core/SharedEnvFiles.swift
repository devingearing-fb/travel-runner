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

    /// `failure` is the reason the script gave no report (see `runFailure`).
    static func status(_ report: AppReport?, failure: String? = nil) -> CheckStatus {
        guard let report else {
            return .warning(failure ?? "Could not run \(script) — pull the latest monorepo dev")
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
        lines.append(replacing
            ? "It replaces the current \(app.directory)/.env, after a copy to .env.bak-<date>."
            : "It becomes \(app.directory)/.env.")
        return ImportPrompt(title: "Import the shared \(app.label.lowercased()) .env?", message: lines.joined(separator: " "), acceptable: true)
    }

    // MARK: - Why the script gave no report

    static func scriptExists(monorepo: String) -> Bool {
        FileManager.default.fileExists(atPath: (monorepo as NSString).appendingPathComponent(script))
    }

    /// Why a run of `env-check.mjs` gave no report, in one line.
    static func runFailure(_ result: CommandResult, scriptExists: Bool, timeout: Duration) -> String {
        if !scriptExists { return "\(script) is missing in this checkout — pull dev" }
        if result.timedOut { return Shell.timeoutText(script, after: timeout) }
        if result.exitCode == 127 { return "node could not be run (exit 127)" }
        if result.succeeded { return "\(script) gave no report — pull dev" }
        guard let line = EnvironmentChecker.lastErrorLine(result) else {
            return "\(script) failed (exit \(result.exitCode))"
        }
        return "\(script) failed (exit \(result.exitCode)): \(line)"
    }

    // MARK: - Writing the file

    /// The app's shared `.env` in the checkout.
    static func target(monorepo: String, app: App) -> String {
        ((monorepo as NSString).appendingPathComponent(app.directory) as NSString).appendingPathComponent(".env")
    }

    /// Writes `data` to `target` with mode 0600. A file already there is first copied to
    /// `<target>.bak-<yyyyMMdd-HHmmss>`, also 0600. Returns the name of the copy, or nil.
    @discardableResult
    static func install(_ data: Data, at target: String, now: Date) throws -> String? {
        let backup = FileManager.default.fileExists(atPath: target)
            ? try BackupCopy.make(of: target, now: now, permissions: 0o600) : nil
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
        return backup
    }

    // MARK: - Pull from Doppler

    /// The script behind `pnpm env:pull`.
    static let dopplerScript = "scripts/doppler-env.sh"

    /// `pnpm env:pull <app>` in the monorepo: Doppler writes the app's `.env`.
    static func pullCommand(monorepo: String, app: App) -> String {
        "cd \(ShellQuote.quote(monorepo)) && pnpm env:pull \(app.rawValue)"
    }

    static func pullUnavailable(monorepo: String) -> String? {
        FileManager.default.fileExists(atPath: (monorepo as NSString).appendingPathComponent(dopplerScript))
            ? nil : "\(dopplerScript) is missing in this checkout — pull dev"
    }

    /// The first line of every `.env` that `doppler-env.sh` writes.
    static let dopplerMarker = "# Written by scripts/doppler-env.sh from Doppler — do not edit; rerun the script."

    /// `doppler-env.sh` refuses a `.env` it did not write ("move it away first"). Before a
    /// pull the runner moves such a file to `<target>.bak-<yyyyMMdd-HHmmss>` (0600), and puts
    /// it back when the pull writes nothing. A file the script wrote stays: the script
    /// replaces it, so repeated pulls leave no copies. Returns the path of the moved file, or nil.
    static func moveAside(_ target: String, now: Date) throws -> String? {
        guard FileManager.default.fileExists(atPath: target), !writtenByDoppler(target) else { return nil }
        let name = try BackupCopy.make(of: target, now: now, permissions: 0o600)
        try FileManager.default.removeItem(atPath: target)
        return ((target as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
    }

    /// True when the first line of the file is `dopplerMarker`, as `doppler-env.sh` checks it.
    static func writtenByDoppler(_ path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
            .map { String($0) == dopplerMarker } ?? false
    }

    /// Puts a moved file back when the pull left no `.env`. True when it did.
    @discardableResult
    static func restore(_ moved: String, to target: String) -> Bool {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: target), fileManager.fileExists(atPath: moved) else { return false }
        return (try? fileManager.moveItem(atPath: moved, toPath: target)) != nil
    }

    // MARK: - Copy from another worktree

    static func worktreeCommand(monorepo: String) -> String {
        ShellQuote.join(["git", "-C", monorepo, "worktree", "list", "--porcelain"])
    }

    /// The folders of `git worktree list --porcelain`, the main worktree first.
    static func worktrees(porcelain: String) -> [String] {
        porcelain.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("worktree ") ? String(line.dropFirst("worktree ".count)) : nil
        }
    }

    /// The app's `.env` of each other worktree that has one, in the order of `worktrees`.
    static func copySources(
        worktrees: [String], current: String, app: App,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        let here = URL(fileURLWithPath: current).standardizedFileURL.resolvingSymlinksInPath().path
        return worktrees
            .filter { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path != here }
            .map { target(monorepo: $0, app: app) }
            .filter(exists)
    }

    private static func names(_ keys: [String]) -> String {
        keys.count > 3 ? keys.prefix(3).joined(separator: ", ") + " +\(keys.count - 3) more" : keys.joined(separator: ", ")
    }
}
