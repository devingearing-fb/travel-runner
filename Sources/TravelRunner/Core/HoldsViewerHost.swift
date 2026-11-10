import Foundation

/// One copy of the monolith's holds viewer (`scripts/holds-viewer`).
///
/// The viewer is the reader for the Rooms tab. It is in the monolith, next to
/// the code that writes the Redis keys, so the key model has one home. The
/// runner only starts it and shows its page.
struct HoldsViewerCopy: Equatable, Sendable {
    enum Origin: Equatable, Sendable {
        /// A folder that the `holdsViewerPath` default names.
        case override
        /// The checkout that the runner runs.
        case workingTree
        /// `origin/dev`, extracted to the cache. `tree` is the git tree id of the folder.
        case originDev(tree: String)
    }

    let origin: Origin
    /// The folder that has `server.mjs`.
    let directory: String

    var serverScript: String {
        (directory as NSString).appendingPathComponent("server.mjs")
    }

    var label: String {
        switch origin {
        case .override: "a folder you set"
        case .workingTree: "your checkout"
        case .originDev(let tree): "origin/dev (\(tree.prefix(7)))"
        }
    }
}

enum HoldsViewerLocator {
    static let relativePath = "scripts/holds-viewer"
    static let remoteRef = "origin/dev"

    static var defaultCacheRoot: String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("travel-runner/holds-viewer").path
    }

    /// The copy to run, in this order:
    /// 1. the override folder;
    /// 2. the checkout, when its branch has the viewer;
    /// 3. `origin/dev`. A teammate on an old branch still gets the tab, and the
    ///    Dev source has no relation to the branch.
    static func locate(monorepo: String, overridePath: String?, cacheRoot: String) -> HoldsViewerCopy? {
        let fm = FileManager.default
        if let overridePath, !overridePath.isEmpty {
            let directory = NSString(string: overridePath).expandingTildeInPath
            let copy = HoldsViewerCopy(origin: .override, directory: directory)
            if fm.fileExists(atPath: copy.serverScript) { return copy }
        }
        let inTree = HoldsViewerCopy(
            origin: .workingTree,
            directory: (monorepo as NSString).appendingPathComponent(relativePath)
        )
        if fm.fileExists(atPath: inTree.serverScript) { return inTree }
        return extractFromRemote(monorepo: monorepo, cacheRoot: cacheRoot)
    }

    /// Extracts the viewer of `origin/dev` to `<cacheRoot>/<tree id>`. The viewer
    /// has no packages, so the extracted folder runs as it is. The tree id
    /// changes only when the viewer changes, so one extract serves until then.
    static func extractFromRemote(monorepo: String, cacheRoot: String) -> HoldsViewerCopy? {
        guard let tree = git(["rev-parse", "--quiet", "--verify", "\(remoteRef):\(relativePath)"], in: monorepo),
              tree.count >= 40, tree.allSatisfy(\.isHexDigit) else { return nil }

        let fm = FileManager.default
        let target = (cacheRoot as NSString).appendingPathComponent(tree)
        let copy = HoldsViewerCopy(
            origin: .originDev(tree: tree),
            directory: (target as NSString).appendingPathComponent(relativePath)
        )
        if fm.fileExists(atPath: copy.serverScript) { return copy }

        // Extract to a temporary folder, then rename: a half-written copy never runs.
        let staging = target + ".tmp-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: staging) }
        do { try fm.createDirectory(atPath: staging, withIntermediateDirectories: true) } catch { return nil }
        let archive = (staging as NSString).appendingPathComponent("viewer.tar")
        guard run("/usr/bin/git", ["-C", monorepo, "archive", "--format=tar", "-o", archive, remoteRef, relativePath]),
              run("/usr/bin/tar", ["-xf", archive, "-C", staging]) else { return nil }
        try? fm.removeItem(atPath: archive)
        try? fm.removeItem(atPath: target)
        do { try fm.moveItem(atPath: staging, toPath: target) } catch { return nil }
        guard fm.fileExists(atPath: copy.serverScript) else { return nil }

        // Older extracts are of no use.
        for entry in (try? fm.contentsOfDirectory(atPath: cacheRoot)) ?? [] where entry != tree {
            try? fm.removeItem(atPath: (cacheRoot as NSString).appendingPathComponent(entry))
        }
        return copy
    }

    private static func git(_ arguments: [String], in directory: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

/// Starts and stops the holds viewer for the Rooms tab.
///
/// The viewer is not a service of the graph: start-all, the profiles and the
/// circuit breaker do not see it. It runs while the tab is in use, and it
/// stops a while after the tab goes away.
@Observable
@MainActor
final class HoldsViewerHost {
    enum Unavailable: Equatable {
        case noMonorepo
        case noViewer
        case nodeNotFound
    }

    enum State: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case unavailable(Unavailable)
        case failed(String)
    }

    static let overrideDefaultsKey = "holdsViewerPath"
    /// The environments that the tab offers. Stg and prd stay in the browser tool.
    static let environments = "local,dev"

    private(set) var state: State = .stopped
    private(set) var copy: HoldsViewerCopy?
    /// The process id of the viewer, for the kill at quit.
    private(set) var pid: Int32?
    /// The query of the page when the tab was last on screen (source, view,
    /// event, hotel). It starts empty at each launch, so a launch starts on Local.
    var lastQuery: String?

    /// The monolith checkout. The supervisor sets it, because the config can change.
    var monorepo: @MainActor () -> String? = { nil }

    private let runner = ProcessRunner()
    private let serviceID = "holds-viewer"
    private let nodeCommand: String
    private let cacheRoot: String
    private let defaults: UserDefaults
    private let idleSeconds: Double
    private var generation = 0
    private var idleTask: Task<Void, Never>?
    private var tabVisible = false
    private var recentOutput: [String] = []

    init(
        nodeCommand: String = "node",
        cacheRoot: String = HoldsViewerLocator.defaultCacheRoot,
        defaults: UserDefaults = .standard,
        idleSeconds: Double = 600
    ) {
        self.nodeCommand = nodeCommand
        self.cacheRoot = cacheRoot
        self.defaults = defaults
        self.idleSeconds = idleSeconds
    }

    /// The page for the tab. `embed=1` hides the page's own title.
    func pageURL(port: Int) -> URL {
        var query = lastQuery ?? "env=local&view=rooms"
        if !query.contains("embed=1") { query += "&embed=1" }
        return URL(string: "http://127.0.0.1:\(port)/?\(query)")!
    }

    /// The same page for a browser, with the page's title.
    func browserURL(port: Int) -> URL {
        let query = (lastQuery ?? "env=local&view=rooms")
            .split(separator: "&").filter { $0 != "embed=1" }.joined(separator: "&")
        return URL(string: "http://127.0.0.1:\(port)/?\(query)")!
    }

    func tabAppeared() {
        tabVisible = true
        idleTask?.cancel()
        idleTask = nil
        Task { await ensureRunning() }
    }

    func tabDisappeared() {
        tabVisible = false
        idleTask?.cancel()
        let seconds = idleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.tabVisible else { return }
            await self.stop()
        }
    }

    func restart() async {
        await stop()
        await ensureRunning()
    }

    /// Starts the viewer when it does not run, and starts it again when the copy
    /// to run has changed (a branch change, a new commit on `origin/dev`).
    func ensureRunning() async {
        if state == .starting { return }
        guard let repo = monorepo(), !repo.isEmpty else {
            await stopProcess()
            copy = nil
            state = .unavailable(.noMonorepo)
            return
        }

        let overridePath = defaults.string(forKey: Self.overrideDefaultsKey)
        let cacheRoot = self.cacheRoot
        let located = await Task.detached {
            HoldsViewerLocator.locate(monorepo: repo, overridePath: overridePath, cacheRoot: cacheRoot)
        }.value

        if case .running = state, located == copy, await runner.isRunning(serviceID: serviceID) { return }
        await stopProcess()

        guard let located else {
            copy = nil
            state = .unavailable(.noViewer)
            return
        }
        copy = located
        state = .starting
        recentOutput = []
        generation += 1
        let launch = generation
        let port = Self.freePort()

        let definition = ServiceDefinition(
            id: serviceID,
            name: "Holds viewer",
            cmd: [
                nodeCommand, located.serverScript,
                "--envs", Self.environments,
                "--port", String(port),
                "--no-open",
                "--main-checkout", repo,
            ],
            cwd: repo, probe: nil, type: .daemon, restart: .never,
            dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil
        )
        do {
            pid = try await runner.start(
                service: definition,
                onStdout: { [weak self] lines in Task { @MainActor in self?.keep(lines) } },
                onStderr: { [weak self] lines in Task { @MainActor in self?.keep(lines) } },
                onTermination: { [weak self] termination in
                    Task { @MainActor in self?.processEnded(termination, launch: launch) }
                }
            )
        } catch {
            pid = nil
            state = .failed("The holds viewer did not start: \(error.localizedDescription)")
            return
        }

        // Wait until the page answers. The end of the process changes the state too.
        for _ in 0..<100 {
            guard launch == generation, state == .starting else { return }
            if await Self.answers(port: port) {
                guard launch == generation, state == .starting else { return }
                state = .running(port: port)
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard launch == generation, state == .starting else { return }
        await stopProcess()
        state = .failed("The holds viewer did not answer in 15 seconds.")
    }

    func stop() async {
        await stopProcess()
        state = .stopped
    }

    private func stopProcess() async {
        generation += 1
        await runner.stop(serviceID: serviceID)
        pid = nil
    }

    private func keep(_ lines: [String]) {
        recentOutput = Array((recentOutput + lines).suffix(6))
    }

    private func processEnded(_ termination: ProcessRunner.Termination, launch: Int) {
        // A stop by this host, or the end of an older launch, changes nothing.
        guard launch == generation, !termination.stoppedByRunner else { return }
        pid = nil
        switch ServiceTermination.classify(termination) {
        case .commandNotRunnable:
            state = .unavailable(.nodeNotFound)
        default:
            let detail = recentOutput.last.map { " \($0)" } ?? ""
            state = .failed("The holds viewer stopped (\(ServiceTermination.describe(termination))).\(detail)")
        }
    }

    private static func answers(port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/envs")!)
        request.timeoutInterval = 1
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// A port that is free now, from the system.
    static func freePort() -> Int {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return 4870 }
        defer { Darwin.close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 4870 }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
