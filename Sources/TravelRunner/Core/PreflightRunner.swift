import Foundation

@Observable
@MainActor
final class PreflightCheck: Identifiable {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated let metadata: [String: String]
    var result: PreflightResult = .pending

    nonisolated init(id: String, name: String, metadata: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.metadata = metadata
    }
}

enum PreflightResult: Sendable {
    case pending
    case passed(detail: String)
    case warning(message: String)
    case failed(message: String, fix: String?)

    var isPassed: Bool {
        if case .passed = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct PreflightRunner: Sendable {
    /// Runs the check commands. They get the PATH that the services get (see `ToolEnvironment`).
    var shell: any CommandRunning = LoginShell()
    /// The time of the wait for a container runtime that starts.
    var clock = RunnerClock.live
    /// False when the checks must change nothing: a container runtime that does
    /// not answer fails its check and is not opened.
    var opensContainerRuntime = true
    /// The checks of the registry for the preflight. Nil: only the steps of the stack.
    var environment: EnvironmentChecker?
    /// The profile whose checks of the registry run.
    var profile: RunProfile = .both
    /// A check command that hangs fails after this time and does not hold the start.
    static let checkTimeout: Duration = CheckRegistry.preflightLimit
    /// The metadata key of a check that comes from the registry.
    static let registryKey = "registry"

    /// The checks of a start: the fast checks of the registry for the profile
    /// (see `CheckRegistry.preflightSubset`), then the steps that need the
    /// services: the container runtime, the backend clone, the ports and the folders.
    @MainActor
    func allChecks(for services: [ServiceDefinition]) -> [PreflightCheck] {
        registryChecks() + stackChecks(for: services)
    }

    @MainActor
    private func registryChecks() -> [PreflightCheck] {
        (environment?.preflightSubset(profile: profile) ?? []).map {
            PreflightCheck(id: $0.id, name: $0.name, metadata: [Self.registryKey: "1"])
        }
    }

    private func stackChecks(for services: [ServiceDefinition]) -> [PreflightCheck] {
        var checks: [PreflightCheck] = [
            PreflightCheck(id: "docker", name: ContainerRuntime.detect().displayName),
        ]

        // `pnpm db:start` clones the backend baseline when there is no checkout of it.
        if let root = services.first(where: { $0.id == "supabase" })?.resolvedCwd, BackendBaseline.applies(root: root) {
            checks.append(PreflightCheck(id: "backend-baseline", name: "Backend migration baseline", metadata: ["root": root]))
        }

        let ports = Set(services.compactMap { $0.probe?.port })
        for port in ports.sorted() {
            checks.append(PreflightCheck(id: "port-\(port)", name: "Port \(port) available"))
        }

        // An app of the hackathon fork that an old checkout does not have is skipped
        // at its start. Its folder is not a condition for the rest of the stack.
        let cwds = Set(services.filter { !ServiceCatalog.forkAppIDs.contains($0.id) }.compactMap { $0.resolvedCwd })
        for cwd in cwds.sorted() {
            // A repo whose path services.json does not set.
            if cwd.isEmpty {
                let names = services.filter { $0.resolvedCwd == "" }.map { $0.name ?? $0.id }.sorted()
                checks.append(PreflightCheck(
                    id: "dir-unset",
                    name: "Folder of \(names.joined(separator: ", "))",
                    metadata: ["path": ""]
                ))
                continue
            }
            let dirName = URL(fileURLWithPath: cwd).lastPathComponent
            checks.append(PreflightCheck(
                id: "dir-\(dirName)",
                name: "\(dirName) exists",
                metadata: ["path": cwd]
            ))
        }

        return checks
    }

    /// The checks that only read: the checks of the registry, the ports and the
    /// folders. The container runtime step can open an app, and the backend step
    /// asks the network.
    @MainActor
    func readOnlyChecks(for services: [ServiceDefinition]) -> [PreflightCheck] {
        allChecks(for: services).filter {
            $0.metadata[Self.registryKey] != nil || $0.id.hasPrefix("port-") || $0.id.hasPrefix("dir-")
        }
    }

    /// Runs the checks in parallel. A result that comes after a cancel is dropped.
    func runAll(_ checks: [PreflightCheck]) async {
        await withTaskGroup(of: Void.self) { group in
            for check in checks {
                group.addTask {
                    let result = await self.run(check: check)
                    if Task.isCancelled { return }
                    await MainActor.run { check.result = result }
                }
            }
        }
    }

    func run(check: PreflightCheck) async -> PreflightResult {
        if check.metadata[Self.registryKey] != nil, let environment {
            return await environment.runForPreflight(check.id)
        }
        switch check.id {
        case "docker":
            let runtime = ContainerRuntime.detect()
            if await ContainerRuntime.isResponding(shell: shell) {
                return .passed(detail: runtime.displayName)
            }
            if opensContainerRuntime, await ContainerRuntime.ensureRunning(shell: shell, clock: clock) {
                return .passed(detail: "\(runtime.displayName) — auto-started")
            }
            return .failed(message: "\(runtime.displayName) not responding", fix: "Open \(runtime.appName) manually")

        case "backend-baseline":
            return await backendBaseline(root: check.metadata["root"] ?? "")

        default:
            if check.id.hasPrefix("port-") {
                let port = Int(check.id.dropFirst(5)) ?? 0
                let available = portAvailable(port)
                if available {
                    return .passed(detail: "Free")
                }
                let pidInfo = await shellOutput("lsof -ti TCP:\(port) -sTCP:LISTEN")
                let pidStr = pidInfo.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = Int(pidStr) {
                    let procName = await shellOutput("ps -p \(pid) -o comm=")
                    let name = URL(fileURLWithPath: procName.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent
                    return .failed(
                        message: "Port \(port) in use by \(name.isEmpty ? "unknown" : name) (PID \(pid))",
                        fix: "kill \(pid)"
                    )
                }
                return .failed(message: "Port \(port) in use", fix: "lsof -ti TCP:\(port) -sTCP:LISTEN | xargs kill")
            }

            if check.id.hasPrefix("dir-") {
                let path = check.metadata["path"] ?? ""
                if path.isEmpty {
                    return .failed(message: "No folder is set — open Settings → Reconfigure Repos",
                                   fix: nil)
                }
                let exists = FileManager.default.fileExists(atPath: path)
                return exists
                    ? .passed(detail: "Found")
                    : .failed(message: "Directory not found — open Settings → Reconfigure Repos",
                              fix: nil)
            }

            return .passed(detail: "OK")
        }
    }

    /// The managed clone of the backend baseline needs the remote: `db:start` clones it
    /// when it has no workspace, and every reset fetches it. Without access, a start that
    /// must clone stops here, before anything runs. With a clone or a workspace in place
    /// the start works, and the row warns. The checkout is the one the login shell of
    /// the script picks.
    private func backendBaseline(root: String) async -> PreflightResult {
        switch await BackendBaseline.resolve(root: root, shell: shell) {
        case .environment:
            return .passed(detail: "FB_AMATEUR_BACKEND_DIR")
        case .sibling:
            return .passed(detail: "Sibling checkout")
        case .managedClone(_, let cloned):
            // A script that names no remote: nothing to ask.
            guard let url = BackendBaseline.repositoryURL(root: root) else {
                return .passed(detail: cloned ? "Managed clone" : "Cloned on the first start")
            }
            let result = await shell.run(BackendBaseline.accessCommand(url: url), cwd: root, timeout: BackendBaseline.accessTimeout)
            if result.succeeded {
                return .passed(detail: cloned ? "Managed clone; the remote answers" : "Cloned on the first start; the remote answers")
            }
            let message = result.timedOut
                ? "\(BackendBaseline.noAccessText) (git did not answer in \(BackendBaseline.accessTimeout.components.seconds) s)"
                : BackendBaseline.noAccessText
            let mustClone = !cloned && !BackendBaseline.workspaceExists(root: root)
            return mustClone ? .failed(message: message, fix: "gh auth setup-git") : .warning(message: message)
        }
    }

    /// One check command. A cwd that does not exist is left out: the check of
    /// the folders reports it.
    private func run(_ command: String, cwd: String? = nil) async -> CommandResult {
        var isDirectory: ObjCBool = false
        let folder = cwd.flatMap {
            FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue ? $0 : nil
        }
        return await shell.run(command, cwd: folder, timeout: Self.checkTimeout)
    }

    /// The output of a check command. Empty when the command timed out or did not start.
    func shellOutput(_ command: String, cwd: String? = nil) async -> String {
        await run(command, cwd: cwd).stdout
    }

    private func portAvailable(_ port: Int) -> Bool {
        // A number that is not a port cannot be in use.
        guard let portNumber = UInt16(exactly: port) else { return true }
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var reuseAddr: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = portNumber.bigEndian
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
