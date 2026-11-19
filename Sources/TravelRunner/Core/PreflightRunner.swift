import Foundation

@Observable
@MainActor
final class PreflightCheck: Identifiable {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated let metadata: [String: String]
    var result: PreflightResult = .pending
    /// A line of a check that waits, such as the wait for the container runtime.
    var progress: String?

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
    /// Who listens on a port, with the ownership of the supervisor. Nil reads the
    /// listeners with `lsof` and knows no process of the runner.
    var inspectPort: (@Sendable (Int) async -> [PortOwner.Occupant])? = nil
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

        // A service of an optional repo that is not there is skipped: its port is free to be busy.
        let ports = Set(services.filter { ServiceCatalog.missingOptionalRepo($0) == nil }.compactMap { $0.probe?.port })
        // A port of a reuse_if_running service (Supabase) is in use when its stack runs.
        let reused = Set(services.filter(\.shouldReuseIfRunning).compactMap { $0.probe?.port })
        for port in ports.sorted() {
            checks.append(PreflightCheck(
                id: "port-\(port)", name: "Port \(port) available", metadata: reused.contains(port) ? ["reuse": "true"] : [:]
            ))
        }

        // An app of the hackathon fork that an old checkout does not have is skipped
        // at its start, and so are Travel Core and a service of an optional repo (stream
        // services, load test). Their folders are not a condition for the rest of the stack.
        let cwds = Set(services.filter {
            !ServiceCatalog.forkAppIDs.contains($0.id) && ServiceCatalog.optionalRepoServices[$0.id] == nil
                && !ServiceCatalog.optionalAppIDs.contains($0.id)
        }.compactMap { $0.resolvedCwd })
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
            // "Run Checks Now" changes nothing: a runtime that does not answer is not opened.
            let probe = opensContainerRuntime
                ? await ContainerRuntime.ensureRunning(shell: shell, clock: clock) { line in
                    Task { @MainActor in check.progress = line }
                }
                : await ContainerRuntime.probe(shell: shell)
            await MainActor.run { check.progress = nil }
            let runtime = probe.runtime
            switch probe {
            case .running(let context):
                return .passed(detail: context.opened ? "\(runtime.displayName) — auto-started" : runtime.displayName)
            case .cliMissing:
                return .failed(message: ContainerRuntimeProbe.cliMissingText, fix: "Install OrbStack or Docker Desktop, then press Retry")
            case .permissionDenied:
                return .failed(message: probe.failureText(waited: nil) ?? "", fix: "Quit and reopen \(runtime.appName)")
            case .daemonDown:
                // "Run Checks Now" opens nothing, so it did not wait.
                let waited: Duration? = opensContainerRuntime ? ContainerRuntime.startTimeout : nil
                return .failed(message: probe.failureText(waited: waited) ?? "", fix: "Open \(runtime.appName)")
            }

        case "backend-baseline":
            return await backendBaseline(root: check.metadata["root"] ?? "")

        default:
            if check.id.hasPrefix("port-") {
                // A number that is not a port cannot be in use.
                guard let port = Int(check.id.dropFirst(5)), UInt16(exactly: port) != nil else {
                    return .passed(detail: "Free")
                }
                let occupants = await occupants(of: port)
                return Self.portResult(occupants, reused: check.metadata["reuse"] == "true")
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

    /// The listeners of the port, from `lsof`: it sees IPv4 and IPv6 on any address.
    /// A test bind on 127.0.0.1 with SO_REUSEADDR did not see a server on `*` or `::1`.
    private func occupants(of port: Int) async -> [PortOwner.Occupant] {
        if let inspectPort { return await inspectPort(port) }
        return PortOwner.classify(await PortOwner.listeners(on: port), PortOwner.Knowledge())
    }

    /// The row of a port. A port in use only warns: the start of its service stops
    /// the runner's own processes and refuses with a button for the others, so the
    /// rest of the stack still starts.
    static func portResult(_ occupants: [PortOwner.Occupant], reused: Bool) -> PreflightResult {
        if let foreign = occupants.first(where: { $0.owner == .foreign }) {
            var place = "PID \(foreign.listener.pid)"
            if let cwd = foreign.cwd { place += ", \(PortOwner.displayPath(cwd))" }
            return .warning(
                message: "In use by \(foreign.listener.command) (\(place)), which \(Flavor.current.displayName) did not start"
            )
        }
        if let container = occupants.first(where: { $0.owner == .containerRuntime }) {
            return reused
                ? .passed(detail: "In use by \(container.listener.command) (a container) — reused")
                : .warning(message: "Published by \(container.listener.command) (a container) — stop that container")
        }
        // Start stops the processes of the last session before these checks, so an
        // own occupant here is one that the start of its service stops.
        if !occupants.isEmpty { return .passed(detail: "In use by \(Flavor.current.displayName)") }
        return .passed(detail: "Free")
    }
}
