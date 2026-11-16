import Foundation

/// The PATH of every command that the runner starts: services, DB steps, checks,
/// the Stripe probe and the diagnostics. No other code resolves tools.
///
/// A login shell (`zsh -l -c`) does not read `~/.zshrc`, so it misses the tools
/// that nvm, fnm, pnpm and the other managers put on PATH there. The sources, in
/// the order of the PATH:
///
/// 1. the PATH of the user's own interactive shell (`resolve` reads it),
/// 2. the PATH of the login shell that runs the command,
/// 3. the static tool directories that exist,
/// 4. the Node of a version manager that fits the `.nvmrc` of the checkout.
final class ToolEnvironment: @unchecked Sendable {
    /// The environment of the app. `resolve` fills it at launch.
    static let shared = ToolEnvironment()

    /// What the user's own shell gave.
    struct Capture: Sendable, Equatable {
        /// The program of the user's shell, such as `/bin/zsh`.
        var shell: String?
        /// The PATH of the interactive shell. It has what the rc file adds.
        var shellPath: [String] = []
        /// The PATH of the plain login shell.
        var loginPath: [String] = []
        /// The other allowed variables of the interactive shell.
        var variables: [String: String] = [:]
        /// Why the interactive shell gave no PATH. Nil when it did.
        var note: String?
    }

    /// The variables that the runner takes from the interactive shell, besides PATH.
    static let allowedVariables: Set<String> = [
        "PNPM_HOME", "VOLTA_HOME", "DOCKER_HOST", "DOCKER_CONTEXT", "NPM_CONFIG_USERCONFIG", "COREPACK_HOME",
    ]

    /// The Node major to look for when the checkout has no `.nvmrc`.
    static let defaultNodeMajor = 22

    static let captureTimeout: Duration = .seconds(5)
    private static let loginPathMarker = "__TR_LOGIN_PATH__"
    private static let envStart = "__TR_ENV_START__"
    private static let envEnd = "__TR_ENV_END__"

    /// Prints the PATH of the login shell, then the environment of the user's own
    /// shell, started as a login and interactive shell so that it reads the rc file.
    static let captureCommand = "print -r -- \"\(loginPathMarker)$PATH\"; "
        + "\"${SHELL:-/bin/zsh}\" -l -i -c 'printf \"\(envStart)\\n\"; env; printf \"\(envEnd)\\n\"'"

    /// True inside `resolve`. Its own command runs in the plain login shell and
    /// does not wait for the resolve to end.
    @TaskLocal private static var isResolving = false

    private let home: String
    private let lock = NSLock()
    private var current: Capture
    private var inFlight: Task<Void, Never>?
    private var lastRunner: (any CommandRunning)?

    init(home: String = NSHomeDirectory(), capture: Capture = Capture()) {
        self.home = home
        self.current = capture
    }

    var capture: Capture {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    // MARK: - Resolve

    /// Reads the user's shell again. It runs at launch, on "Re-check All", and
    /// after a service ends with exit 127.
    func resolve(runner: any CommandRunning) async {
        await beginResolve(runner: runner).value
    }

    /// Starts `resolve` and returns at once. A command that starts after this
    /// call waits for the result (see `settled`).
    @discardableResult
    func beginResolve(runner: any CommandRunning) -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        lastRunner = runner
        if let inFlight { return inFlight }
        let task = Task { [self] in
            let result = await Self.$isResolving.withValue(true) {
                await runner.run(Self.captureCommand, environment: ["TERM": "dumb"], timeout: Self.captureTimeout)
            }
            finishResolve(result)
        }
        inFlight = task
        return task
    }

    /// Runs the last `resolve` again. It does nothing before the first one.
    func refresh() {
        lock.lock()
        let runner = lastRunner
        lock.unlock()
        if let runner { beginResolve(runner: runner) }
    }

    /// Returns when no `resolve` runs.
    func settled() async {
        guard !Self.isResolving else { return }
        await resolveInFlight?.value
    }

    private var resolveInFlight: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return inFlight
    }

    private func finishResolve(_ result: CommandResult) {
        var parsed = Self.parseCapture(result.stdout)
        if result.timedOut {
            parsed.note = "Your shell did not answer in \(Self.captureTimeout.components.seconds) s."
        }
        lock.lock()
        defer { lock.unlock() }
        // A shell that fails once does not take away what an earlier read found.
        if parsed.shellPath.isEmpty {
            parsed.shell = parsed.shell ?? current.shell
            parsed.shellPath = current.shellPath
            parsed.variables = current.variables
        }
        if parsed.loginPath.isEmpty { parsed.loginPath = current.loginPath }
        current = parsed
        inFlight = nil
    }

    /// Reads the output of `captureCommand`. Only the lines between the two marks
    /// are the environment: an rc file can print its own text before them.
    static func parseCapture(_ output: String) -> Capture {
        var capture = Capture()
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        if let login = lines.last(where: { $0.hasPrefix(loginPathMarker) }) {
            capture.loginPath = directories(inPath: String(login.dropFirst(loginPathMarker.count)))
        }
        guard let start = lines.lastIndex(of: envStart),
              let end = lines[start...].firstIndex(of: envEnd) else {
            capture.note = "Your shell did not print its environment."
            return capture
        }
        for line in lines[(start + 1)..<end] {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equals])
            let value = String(line[line.index(after: equals)...])
            if key == "PATH" {
                capture.shellPath = directories(inPath: value)
            } else if key == "SHELL" {
                capture.shell = value
            } else if allowedVariables.contains(key), !value.isEmpty {
                capture.variables[key] = value
            }
        }
        if capture.shellPath.isEmpty { capture.note = "Your shell did not print a PATH." }
        return capture
    }

    /// The absolute directories of a PATH value, each one once.
    static func directories(inPath path: String) -> [String] {
        var seen = Set<String>()
        return path.split(separator: ":").map(normalized).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    private static func normalized(_ directory: Substring) -> String {
        var directory = String(directory)
        while directory.count > 1, directory.hasSuffix("/") { directory.removeLast() }
        return directory
    }

    // MARK: - PATH

    /// Where Homebrew, the container runtimes and the version managers keep their tools.
    static func staticDirectories(home: String) -> [String] {
        [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.docker/bin",
            "\(home)/.orbstack/bin",
            "\(home)/Library/pnpm",
            "\(home)/.local/share/pnpm",
            "\(home)/.volta/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.local/bin",
        ]
    }

    /// The Node major in the `.nvmrc` of `cwd` or of a folder above it.
    static func nodeMajor(forCwd cwd: String?, fileManager: FileManager = .default) -> Int? {
        guard let cwd else { return nil }
        var directory = URL(fileURLWithPath: cwd).standardizedFileURL
        for _ in 0..<8 {
            let file = directory.appendingPathComponent(".nvmrc").path
            if let data = fileManager.contents(atPath: file) {
                return NodeLocator.major(ofVersionOutput: String(decoding: data, as: UTF8.self))
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    /// Sources 3 and 4: each static directory that exists, then the Node of a
    /// version manager that fits the `.nvmrc` of the checkout.
    static func fallbackDirectories(
        cwd: String?,
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> [String] {
        var directories = staticDirectories(home: home).filter { path in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        let major = nodeMajor(forCwd: cwd, fileManager: fileManager) ?? defaultNodeMajor
        let installs = NodeLocator.installs(home: home, fileManager: fileManager)
        if let node = NodeLocator.pick(installs, minimumMajor: major), !directories.contains(node.binDirectory) {
            directories.append(node.binDirectory)
        }
        return directories
    }

    /// `command` with the PATH of this environment, for `zsh -l -c`. The login
    /// shell sets PATH before the command runs, so the change must be in the
    /// command itself.
    func wrap(_ command: String, cwd: String?) -> String {
        // The command of `resolve` reads the plain login shell.
        if Self.isResolving { return command }
        let capture = self.capture
        let fallback = Self.fallbackDirectories(cwd: cwd, home: home).filter { !capture.shellPath.contains($0) }
        return Self.wrap(command, before: capture.shellPath, after: fallback, variables: capture.variables)
    }

    /// `before` goes in front of the PATH of the login shell and `after` goes
    /// behind it. A variable is set only when the login shell does not have it.
    static func wrap(
        _ command: String, before: [String], after: [String], variables: [String: String] = [:]
    ) -> String {
        var prefix = ""
        if !before.isEmpty || !after.isEmpty {
            let path = (before.map(ShellQuote.quote) + ["\"$PATH\""] + after.map(ShellQuote.quote)).joined(separator: ":")
            // `typeset -U` drops the repeats: the two shells share most of their PATH.
            prefix += "export PATH=\(path); typeset -U path; "
        }
        for key in variables.keys.sorted() {
            prefix += "[ -n \"$\(key)\" ] || \(key)=\(ShellQuote.quote(variables[key] ?? "")); export \(key); "
        }
        return prefix + command
    }

    // MARK: - Missing tools

    /// The first word of a service command, when the shell finds it through PATH.
    static func toolName(of command: [String]) -> String? {
        guard let tool = command.first, !tool.isEmpty, !tool.contains("/") else { return nil }
        return tool
    }

    /// Where the shell of a command finds a tool.
    enum Lookup: Sendable, Equatable {
        /// What `command -v` prints: the path of the tool.
        case found(String)
        /// The PATH of the command. The tool is not on it.
        case missing(searchedPath: String)
    }

    /// Asks the shell of `runner` for `tool`. Nil when the shell itself cannot run.
    static func lookup(_ tool: String, cwd: String?, runner: any CommandRunning) async -> Lookup? {
        let probe = "found=$(command -v -- \(ShellQuote.quote(tool)) 2>/dev/null) && { print -r -- \"$found\"; exit 0 }; "
            + "print -r -- \"$PATH\"; exit 3"
        let result = await runner.run(probe, cwd: cwd, timeout: .seconds(10))
        guard !result.timedOut, result.exitCode == 0 || result.exitCode == 3,
              let line = result.stdout.split(whereSeparator: \.isNewline).last.map(String.init) else { return nil }
        return result.exitCode == 0 ? .found(line) : .missing(searchedPath: line)
    }

    /// What exit 127 of a service says about the tool of its command.
    enum MissingTool: Sendable, Equatable {
        /// The tool is not on the PATH, also after a new read of the shell.
        case notFound(searchedPath: String)
        /// The PATH of the launch did not have the tool. The new read of the shell has it.
        case foundNow(path: String)
    }

    /// After exit 127: looks for the tool on the PATH of the launch, reads the
    /// shell again, and looks once more. The tool can be new on this Mac, and the
    /// next start of the service waits for the new read. Nil when the PATH of
    /// the launch had the tool (the exit code then comes from inside the command),
    /// or when the shell cannot run.
    func diagnoseMissing(tool: String, cwd: String?, runner: any CommandRunning) async -> MissingTool? {
        let atLaunch = await Self.lookup(tool, cwd: cwd, runner: runner)
        refresh()
        guard case .missing(let launchPath) = atLaunch else { return nil }
        // This command waits for the new read.
        switch await Self.lookup(tool, cwd: cwd, runner: runner) {
        case .found(let path): return .foundNow(path: path)
        case .missing(let searchedPath): return .notFound(searchedPath: searchedPath)
        case nil: return .notFound(searchedPath: launchPath)
        }
    }

    /// What the user reads when the new read of the shell found the tool.
    static func foundNowText(
        name: String, tool: String, path: String, appName: String = Flavor.current.displayName
    ) -> String {
        "\(name) could not find \(tool) when it started. \(appName) read your shell again and found it at \(path). Restart \(name)."
    }

    /// What the user reads when a tool is not on PATH.
    static func notFoundText(tool: String, searchedPath: String, appName: String = Flavor.current.displayName) -> String {
        "\(tool) was not found. \(appName) looked in: \(searchedPath). Install \(tool) or add its folder to ~/.zprofile, then restart the service."
    }

    // MARK: - Tools report

    /// The tools that the "Tools" block of the diagnostics shows.
    static let reportedTools = ["node", "pnpm", "docker", "stripe"]

    private static let reportPathMarker = "__TR_PATH__"
    private static let reportToolMarker = "__TR_TOOL__"

    /// One tool gets this time to say where it is and which version it has.
    static let reportTimeout: Duration = .seconds(10)

    /// Prints the PATH, then the path of the tool and the output of its `--version`.
    static func reportCommand(tool: String) -> String {
        let name = ShellQuote.quote(tool)
        return "print -r -- \"\(reportPathMarker)$PATH\"; "
            + "found=$(command -v -- \(name) 2>/dev/null) || found=; "
            + "print -r -- \"\(reportToolMarker)$found\"; "
            + "[ -n \"$found\" ] && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \(name) --version 2>/dev/null | head -n 5; "
            + "exit 0"
    }

    /// Where each tool is and which version it has, for a command with this cwd.
    /// Each tool has its own command and its own timeout, so a tool that hangs
    /// does not hide the others.
    func report(
        runner: any CommandRunning, cwd: String? = nil, tools: [String] = ToolEnvironment.reportedTools
    ) async -> [ToolReport] {
        let capture = self.capture
        return await withTaskGroup(of: (Int, ToolReport).self) { group in
            for (index, tool) in tools.enumerated() {
                group.addTask {
                    let result = await runner.run(Self.reportCommand(tool: tool), cwd: cwd, timeout: Self.reportTimeout)
                    return (index, Self.parseReport(result, tool: tool, capture: capture))
                }
            }
            var reports: [(Int, ToolReport)] = []
            for await report in group { reports.append(report) }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Reads the result of `reportCommand`. A tool is "not found" only when the
    /// shell said so. A command that timed out, was cancelled or did not run
    /// gives a tool that was not read.
    static func parseReport(_ result: CommandResult, tool: String, capture: Capture) -> ToolReport {
        var searched = ""
        var found: String?
        var versionLines: [String] = []
        for line in result.stdout.split(whereSeparator: \.isNewline).map(String.init) {
            if found != nil {
                versionLines.append(line)
            } else if line.hasPrefix(reportToolMarker) {
                found = String(line.dropFirst(reportToolMarker.count))
            } else if line.hasPrefix(reportPathMarker) {
                searched = String(line.dropFirst(reportPathMarker.count))
            }
        }
        let limit = "\(reportTimeout.components.seconds) s"
        guard let found else {
            let why = result.timedOut ? "the shell did not answer in \(limit)" : "the shell command did not run"
            return ToolReport(name: tool, path: nil, version: nil, origin: nil, searchedPath: searched, problem: why)
        }
        guard !found.isEmpty else {
            return ToolReport(name: tool, path: nil, version: nil, origin: nil, searchedPath: searched)
        }
        return ToolReport(
            name: tool, path: found,
            version: ToolVersion.find(in: versionLines.joined(separator: "\n")),
            origin: found.hasPrefix("/") ? origin(ofToolAt: found, capture: capture) : nil,
            searchedPath: searched,
            problem: result.timedOut ? "\(tool) --version did not answer in \(limit)" : nil
        )
    }

    /// Which source put the folder of this tool on the PATH. Nil when the shell
    /// was not read, so the sources are not known.
    static func origin(ofToolAt path: String, capture: Capture) -> ToolReport.Origin? {
        guard !capture.loginPath.isEmpty else { return nil }
        let directory = (path as NSString).deletingLastPathComponent
        if capture.loginPath.contains(directory) { return .loginShell }
        if capture.shellPath.contains(directory) {
            return .rcFile(rcFile(ofShell: capture.shell), manager: manager(ofDirectory: directory))
        }
        return .runner
    }

    /// The file where an interactive shell of this kind gets its PATH additions.
    static func rcFile(ofShell shell: String?) -> String {
        switch shell.map({ ($0 as NSString).lastPathComponent }) {
        case "zsh", nil: "~/.zshrc"
        case "bash": "~/.bashrc"
        case "fish": "~/.config/fish/config.fish"
        default: "your shell profile"
        }
    }

    /// The tool manager that owns a PATH directory, when the path names one.
    static func manager(ofDirectory directory: String) -> String? {
        let known: [(String, String)] = [
            ("/.nvm/", "nvm"), ("/fnm", "fnm"), ("/.volta/", "Volta"), ("/mise/", "mise"), ("/.asdf/", "asdf"),
            ("/pnpm", "pnpm"), ("/.orbstack/", "OrbStack"), ("/.docker/", "Docker Desktop"), ("/homebrew/", "Homebrew"),
        ]
        let path = directory + "/"
        return known.first { path.contains($0.0) }?.1
    }
}

/// One row of the "Tools" block of the diagnostics.
struct ToolReport: Sendable, Equatable, Identifiable {
    enum Origin: Sendable, Equatable {
        /// The plain login shell has it.
        case loginShell
        /// Only the rc file of the interactive shell adds it.
        case rcFile(String, manager: String?)
        /// Only the runner's own directories have it.
        case runner
    }

    let name: String
    /// Nil when the tool is not on the PATH, or when it was not read.
    let path: String?
    /// Without the "v".
    let version: String?
    let origin: Origin?
    /// The PATH of the commands of the runner.
    let searchedPath: String
    /// Why the runner could not read the tool, or its version. Nil when it could.
    var problem: String?

    var id: String { name }
    var isFound: Bool { path != nil }
    /// True when the runner does not know if the tool is there.
    var isUnread: Bool { path == nil && problem != nil }

    /// What the user reads about this tool.
    func text(appName: String = Flavor.current.displayName) -> String {
        guard let path else {
            if let problem { return "\(appName) could not read \(name): \(problem). Click Look Again." }
            return "\(name) was not found. \(appName) looked in: \(searchedPath)."
        }
        if let problem { return "\(name) is at \(path). \(problem). Click Look Again." }
        let which = version.map { "v\($0) at \(path)" } ?? path
        switch origin {
        case .rcFile(let file, let manager):
            let source = manager.map { "\(file) (\($0))" } ?? file
            return "\(name) comes from \(source). \(appName) found it and will use \(which)."
        case .runner:
            return "\(name) is not on the PATH of your shell. \(appName) found it and will use \(which)."
        case .loginShell, nil:
            return "\(name) \(which)."
        }
    }
}

enum ToolVersion {
    private static let versionLine = #"^v?\d+\.\d+(\.\d+)?(-[0-9A-Za-z.-]+)?$"#

    /// The last line of the output that is only a version, without the "v". Other
    /// lines are notices. A prerelease such as "11.0.0-rc.1" is a version.
    static func parse(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.range(of: versionLine, options: .regularExpression) != nil }
            .map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
    }

    /// `parse`, or the first version inside a line such as "Docker version 27.0.3, build …".
    static func find(in output: String) -> String? {
        if let version = parse(output) { return version }
        return output.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression).map { String(output[$0]) }
    }
}
