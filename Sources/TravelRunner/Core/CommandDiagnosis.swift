import Foundation

/// Says what is missing when a service command cannot run: the tool, the packages,
/// the script of the branch, or the execute bit of a file. It reads the command,
/// the files of its folder and the last lines of its log, and nothing else.
enum CommandDiagnosis {
    enum Finding: Equatable, Sendable {
        /// The tool is not on the PATH, also after a new read of the shell.
        case toolMissing(tool: String, searchedPath: String)
        /// The PATH of the launch did not have the tool. The new read of the shell has it.
        case toolFoundNow(tool: String, path: String)
        /// The packages are not installed in `repo` (the folder of the install).
        case dependenciesMissing(repo: String)
        /// The `package.json` of the service has no such script.
        case scriptMissing(script: String, packageJSON: String)
        /// The command is a file that this checkout does not have.
        case fileMissing(file: String, folder: String)
        /// Exit 126: the file exists but cannot be run.
        case notExecutable(file: String)
        /// No cause was found.
        case unknown(command: String, code: Int32)
    }

    /// The commands that run a script of `package.json`.
    private static let packageManagers: Set<String> = ["pnpm", "npm", "yarn"]

    /// pnpm commands that are not scripts.
    private static let pnpmCommands: Set<String> = [
        "exec", "dlx", "x", "install", "i", "add", "remove", "rm", "update", "up", "create", "store", "why",
        "list", "ls", "outdated", "link", "unlink", "prune", "rebuild", "import", "fetch", "patch", "env",
    ]

    /// Flags that run the script of another package or folder.
    private static let otherPackageFlags: Set<String> = [
        "--filter", "-F", "--dir", "-C", "--prefix", "--workspace", "-w", "-r", "--recursive",
    ]

    // MARK: - Diagnosis

    /// What exit 126 or 127 of `command` means. `tool` is the answer of
    /// `ToolEnvironment.diagnoseMissing`; nil when the PATH had the tool.
    static func diagnose(
        code: Int32, command: [String], cwd: String?, logTail: [String], tool: ToolEnvironment.MissingTool?
    ) -> Finding {
        let first = command.first ?? ""
        switch tool {
        case .notFound(let searchedPath): return .toolMissing(tool: first, searchedPath: searchedPath)
        case .foundNow(let path): return .toolFoundNow(tool: first, path: path)
        case nil: break
        }
        if code == 126 {
            return .notExecutable(file: deniedFile(in: logTail) ?? first)
        }
        // A file of the checkout, by its path: `./scripts/run.sh`, `./node_modules/.bin/qstash`.
        if first.contains("/"), let cwd {
            let path = first.hasPrefix("/") ? first : (cwd as NSString).appendingPathComponent(first)
            if !FileManager.default.fileExists(atPath: path) {
                if first.contains("node_modules/") {
                    return .dependenciesMissing(repo: DependencyWatcher.installTarget(for: cwd).folder)
                }
                return .fileMissing(file: first, folder: cwd)
            }
        }
        if let finding = packageFinding(command: command, cwd: cwd, logTail: logTail) { return finding }
        // A script ran, and the shell did not find a tool of the packages (`sh: next: command not found`).
        if packageManagers.contains(first), let cwd, hasPackageJSON(cwd),
           logTail.contains(where: { $0.contains("command not found") }) {
            return .dependenciesMissing(repo: DependencyWatcher.installTarget(for: cwd).folder)
        }
        return .unknown(command: first.isEmpty ? "its command" : first, code: code)
    }

    /// A run of a package manager that ended with another code. pnpm ends with 1
    /// when the packages are missing and with 1 or 254 when the script is missing.
    /// Nil unless the log says so.
    static func diagnoseFailedRun(command: [String], cwd: String?, logTail: [String]) -> Finding? {
        guard let first = command.first, packageManagers.contains(first) else { return nil }
        let markers = [
            "ERR_PNPM_NO_SCRIPT", "Missing script:", "ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL", "command not found",
            missingModulesMarker,
        ]
        guard logTail.contains(where: { line in markers.contains { line.contains($0) } }) else { return nil }
        return packageFinding(command: command, cwd: cwd, logTail: logTail)
    }

    /// pnpm prints this when the folder has no `node_modules`.
    private static let missingModulesMarker = "node_modules missing, did you mean to install"

    /// A script that `package.json` does not have, or packages that are not installed.
    private static func packageFinding(command: [String], cwd: String?, logTail: [String]) -> Finding? {
        guard let first = command.first, packageManagers.contains(first), let cwd else { return nil }
        let packageJSON = (cwd as NSString).appendingPathComponent("package.json")
        if let script = scriptName(of: command), let scripts = scripts(in: packageJSON), scripts[script] == nil {
            return .scriptMissing(script: script, packageJSON: packageJSON)
        }
        guard hasPackageJSON(cwd) else { return nil }
        let repo = DependencyWatcher.installTarget(for: cwd).folder
        let modules = [repo, cwd].map { ($0 as NSString).appendingPathComponent("node_modules") }
        if modules.contains(where: { !FileManager.default.fileExists(atPath: $0) })
            || logTail.contains(where: { $0.contains(missingModulesMarker) }) {
            return .dependenciesMissing(repo: repo)
        }
        return nil
    }

    /// The script that a package manager command runs: `pnpm dev`, `pnpm run dev`,
    /// `npm run dev`, `yarn dev`. Nil for another package (`--filter`), for a
    /// command of the package manager (`pnpm exec`), and for `npm start`.
    static func scriptName(of command: [String]) -> String? {
        guard let first = command.first, packageManagers.contains(first) else { return nil }
        var words = command.dropFirst()
        // Flags before the command. A filter runs the script of another package.
        while let word = words.first, word.hasPrefix("-") {
            if otherPackageFlags.contains(word) || word.hasPrefix("--filter=") || word.hasPrefix("--dir=") { return nil }
            words = words.dropFirst()
        }
        guard let word = words.first else { return nil }
        if word == "run" || word == "run-script" {
            return words.dropFirst().first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        }
        switch first {
        case "pnpm", "yarn": return pnpmCommands.contains(word) ? nil : word
        default: return nil
        }
    }

    private static func scripts(in packageJSON: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: packageJSON),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["scripts"] as? [String: Any] ?? [:]
    }

    private static func hasPackageJSON(_ folder: String) -> Bool {
        FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent("package.json"))
    }

    /// The file of a "permission denied" line: `zsh:1: permission denied: ./run.sh`
    /// or `sh: /repo/node_modules/.bin/next: Permission denied`.
    static func deniedFile(in lines: [String]) -> String? {
        for line in lines.reversed() {
            if let range = line.range(of: "permission denied: ") {
                let file = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !file.isEmpty { return file }
            }
            if let range = line.range(of: ": Permission denied") {
                let head = line[..<range.lowerBound]
                let file = head.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                if !file.isEmpty { return file }
            }
        }
        return nil
    }

    // MARK: - Words

    /// The sentence that the row, the banner and the log show.
    static func message(_ finding: Finding, name: String, appName: String = Flavor.current.displayName) -> String {
        switch finding {
        case .toolMissing(let tool, let searchedPath):
            "\(name) cannot start: `\(tool)` is not on \(appName)'s PATH. It looked in: \(searchedPath). Open Health to see where each tool was found."
        case .toolFoundNow(let tool, let path):
            ToolEnvironment.foundNowText(name: name, tool: tool, path: path, appName: appName)
        case .dependenciesMissing(let repo):
            "\(name) cannot start: its packages are not installed in \(repo)."
        case .scriptMissing(let script, let packageJSON):
            "\(name) cannot start: this branch has no script `\(script)` in \(packageJSON). Switch branch or pull, then restart \(name)."
        case .fileMissing(let file, let folder):
            "\(name) cannot start: this branch has no file `\(file)` in \(folder). Switch branch or pull, then restart \(name)."
        case .notExecutable(let file):
            "\(name) cannot start: \(file) is not executable (exit 126)."
        case .unknown(let command, let code):
            "\(name) cannot start: the shell could not run \(command) (exit \(code)). Does the current branch have it? Restart \(name) after the fix."
        }
    }

    /// The buttons, the most useful first.
    static func actions(_ finding: Finding) -> [RecoveryAction] {
        switch finding {
        case .toolMissing: [.openHealth, .openLog]
        case .toolFoundNow: [.restart]
        case .dependenciesMissing: [.installDependencies, .openLog]
        case .scriptMissing, .fileMissing: [.restart, .openLog]
        case .notExecutable, .unknown: [.openLog, .restart]
        }
    }
}
