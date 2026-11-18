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

    /// The checkout that `local-db.sh` would use for the monorepo at `root`, in the
    /// login shell that runs it. A shell profile can set `FB_AMATEUR_BACKEND_DIR` that
    /// the runner itself does not have, for example when it opens from Finder.
    /// `timeout` is the check timeout of the caller.
    static func resolve(root: String, shell: any CommandRunning, timeout: Duration = .seconds(15)) async -> Source {
        let result = await shell.run(environmentCommand, cwd: root, timeout: timeout)
        let dir = result.exitCode == 0 ? environmentValue(result.stdout) : nil
        return source(root: root, environment: dir.map { ["FB_AMATEUR_BACKEND_DIR": $0] } ?? [:])
    }

    /// Prints `FB_AMATEUR_BACKEND_DIR` as the login shell sets it, after a marker: a
    /// profile can print lines of its own before it.
    static let environmentCommand = #"printf 'FB_AMATEUR_BACKEND_DIR=%s\n' "${FB_AMATEUR_BACKEND_DIR:-}""#

    /// The value of `environmentCommand`, or nil when it is not set.
    static func environmentValue(_ output: String) -> String? {
        let marker = "FB_AMATEUR_BACKEND_DIR="
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(marker) }) else { return nil }
        let value = String(line.dropFirst(marker.count))
        return value.isEmpty ? nil : value
    }

    /// The checkout that `local-db.sh` would use for the monorepo at `root`, given the
    /// environment of the script.
    static func source(root: String, environment: [String: String]) -> Source {
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

    /// True when `local-db.sh` has built its Supabase workspace. Then `db:start` builds
    /// nothing and clones nothing; only a reset needs the backend checkout.
    static func workspaceExists(root: String) -> Bool {
        FileManager.default.fileExists(
            atPath: (root as NSString).appendingPathComponent(".supabase-workspace/supabase/config.toml")
        )
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
