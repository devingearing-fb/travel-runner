import Foundation

/// Extra PATH directories for the commands that the runner starts. A login shell
/// (`zsh -l -c`) does not read `~/.zshrc`, so it misses the tools that nvm, fnm,
/// pnpm and the other managers put on PATH there.
enum ToolPath {
    /// The Node major to look for when the checkout has no `.nvmrc`.
    static let defaultNodeMajor = 22

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

    /// The directories to add: each static directory that exists, then the Node of
    /// a version manager that fits the `.nvmrc` of the checkout.
    static func directories(
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

    /// `command` with `directories` at the end of PATH. The login shell sets PATH
    /// before the command runs, so the change must be in the command itself. The
    /// PATH of the user's own login shell stays first.
    static func wrap(_ command: String, directories: [String]) -> String {
        guard !directories.isEmpty else { return command }
        let extra = directories.map(ShellQuote.quote).joined(separator: ":")
        return "export PATH=\"$PATH\":\(extra); \(command)"
    }

    /// The first word of a service command, when the shell finds it through PATH.
    static func toolName(of command: [String]) -> String? {
        guard let tool = command.first, !tool.isEmpty, !tool.contains("/") else { return nil }
        return tool
    }

    /// The PATH that a command from `wrap` gets, when `tool` is not on it. Nil when
    /// the shell finds the tool, when the shell itself cannot run, or when the login
    /// profile does not end within `timeout`.
    static func searchedPath(
        missing tool: String,
        directories: [String],
        timeout: TimeInterval = 10,
        shellArguments: [String] = ["-l", "-c"]
    ) async -> String? {
        let probe = "command -v -- \(ShellQuote.quote(tool)) >/dev/null 2>&1 && exit 0; print -r -- \"$PATH\"; exit 3"
        let command = wrap(probe, directories: directories)
        return await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            let answer = OneAnswer(continuation)
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = shellArguments + [command]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                // Status 3 means that the PATH is in the pipe. `availableData` does not
                // wait for the end of the pipe, which a background process of the
                // profile can hold open.
                guard proc.terminationStatus == 3, proc.terminationReason == .exit else {
                    answer.give(nil)
                    return
                }
                let output = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self)
                answer.give(output.split(separator: "\n").last.map(String.init))
            }
            do { try process.run() } catch {
                answer.give(nil)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard answer.give(nil) else { return }
                process.terminate()
            }
        }
    }

    /// Resumes the continuation once: with the answer of the shell or with the timeout.
    private final class OneAnswer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?

        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }

        /// False when the answer was already given.
        @discardableResult
        func give(_ value: String?) -> Bool {
            let waiting = lock.withLock { () -> CheckedContinuation<String?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: value)
            return waiting != nil
        }
    }

    /// What the user reads when a tool is not on PATH.
    static func notFoundText(tool: String, searchedPath: String, appName: String = Flavor.current.displayName) -> String {
        "\(tool) was not found. \(appName) looked in: \(searchedPath). Install \(tool) or add its folder to ~/.zprofile, then restart the service."
    }
}
