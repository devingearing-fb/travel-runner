import Foundation

/// The fb-amateur-backend checkout that `scripts/local-db.sh` replays the migrations of.
///
/// The script takes, first match wins: `FB_AMATEUR_BACKEND_DIR`, the sibling
/// `../fb-amateur-backend`, or its managed clone `.backend-baseline/`. It clones and
/// fetches the managed one over HTTPS in `pnpm db:start` and in every reset, before any
/// DB step. Without access that git asks for a password, or fails late. So the runner
/// asks the remote first, with no prompt.
enum BackendBaseline {
    enum Source: Equatable, Sendable {
        /// `FB_AMATEUR_BACKEND_DIR`: used as it is.
        case environment(String)
        /// `../fb-amateur-backend`: used as it is.
        case sibling(String)
        /// `.backend-baseline/`. `cloned` is false before the first clone.
        case managedClone(String, cloned: Bool)

        /// The script fetches only the managed clone.
        var needsRemote: Bool {
            if case .managedClone = self { return true }
            return false
        }
    }

    /// The checkout that `local-db.sh` would use for the monorepo at `root`.
    static func source(
        root: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Source {
        let fm = FileManager.default
        func hasMigrations(_ dir: String) -> Bool {
            fm.fileExists(atPath: (dir as NSString).appendingPathComponent("supabase/migrations"))
        }
        if let dir = environment["FB_AMATEUR_BACKEND_DIR"], !dir.isEmpty { return .environment(dir) }
        let sibling = ((root as NSString).deletingLastPathComponent as NSString).appendingPathComponent("fb-amateur-backend")
        if hasMigrations(sibling) { return .sibling(sibling) }
        let clone = (root as NSString).appendingPathComponent(".backend-baseline")
        return .managedClone(clone, cloned: fm.fileExists(atPath: (clone as NSString).appendingPathComponent(".git")))
    }

    /// True when the folder is a monorepo whose DB scripts use a backend baseline.
    static func applies(root: String) -> Bool {
        FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(script))
    }

    static let script = "scripts/local-db.sh"

    /// The remote that `local-db.sh` clones (`BACKEND_REPO="…"`). The runner keeps no copy.
    static func repositoryURL(root: String) -> String? {
        let path = (root as NSString).appendingPathComponent(script)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return repositoryURL(script: content)
    }

    static func repositoryURL(script content: String) -> String? {
        for line in content.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("BACKEND_REPO=") else { continue }
            let value = text.dropFirst("BACKEND_REPO=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// git gives up instead of asking for a user name or a password.
    static let noPromptEnvironment = ["GIT_TERMINAL_PROMPT": "0"]

    /// Asks the remote for its HEAD. Reads only; no prompt.
    static func accessCommand(url: String) -> String {
        "GIT_TERMINAL_PROMPT=0 " + ShellQuote.join(["git", "ls-remote", "--quiet", url, "HEAD"])
    }

    /// A remote that does not answer in this time counts as no access.
    static let accessTimeout: Duration = .seconds(15)

    static let noAccessText =
        "No access to fb-amateur-backend over HTTPS. Run `gh auth setup-git`, or choose an existing checkout."

    // MARK: - The sibling checkout

    /// Prints the branch, then the commits behind its upstream (as last fetched; no fetch).
    static func siblingCommand(dir: String) -> String {
        let git = ShellQuote.join(["git", "-C", dir])
        return "\(git) rev-parse --abbrev-ref HEAD; \(git) rev-list --count 'HEAD..@{upstream}' 2>/dev/null || echo -"
    }

    struct SiblingState: Equatable, Sendable {
        var branch: String?
        /// Nil when the branch has no upstream.
        var behind: Int?
    }

    static func siblingState(_ output: String) -> SiblingState {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let branch = lines.first.flatMap { $0.isEmpty ? nil : $0 }
        let behind = lines.count > 1 ? Int(lines[1]) : nil
        return SiblingState(branch: branch, behind: behind)
    }

    /// The row of the sibling checkout: its branch, and how far behind it is.
    static func siblingStatus(_ state: SiblingState) -> CheckStatus {
        let branch = state.branch.map { " (\($0))" } ?? ""
        if let behind = state.behind, behind > 0 {
            return .warning("Sibling is \(behind) commit\(behind == 1 ? "" : "s") behind — use managed clone")
        }
        return .passing("Sibling checkout\(branch)")
    }
}
