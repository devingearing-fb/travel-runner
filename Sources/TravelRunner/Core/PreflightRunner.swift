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
    /// Who listens on a port, with the ownership of the supervisor. Nil reads the
    /// listeners with `lsof` and knows no process of the runner.
    var inspectPort: (@Sendable (Int) async -> [PortOwner.Occupant])? = nil
    /// A check command that hangs fails after this time and does not hold the start.
    static let checkTimeout: Duration = .seconds(15)

    func allChecks(for services: [ServiceDefinition]) -> [PreflightCheck] {
        var checks: [PreflightCheck] = [
            PreflightCheck(id: "docker", name: ContainerRuntime.detect().displayName),
            // The cwd of a portal: the Node of its `.nvmrc` is the one the services get.
            PreflightCheck(
                id: "node-version", name: "Node.js \u{2265} 22",
                metadata: (nodeCwd(for: services)).map { ["cwd": $0] } ?? [:]
            ),
            // The booking portal: the CLI uses the test key of its env.
            PreflightCheck(
                id: "stripe-auth", name: "Stripe CLI Auth",
                metadata: services.first(where: { $0.id == "travel-portal" })?.resolvedCwd.map { ["cwd": $0] } ?? [:]
            ),
        ]

        // `pnpm db:start` clones the backend baseline when there is no checkout of it.
        if let root = services.first(where: { $0.id == "supabase" })?.resolvedCwd, BackendBaseline.applies(root: root) {
            checks.append(PreflightCheck(id: "backend-baseline", name: "Backend migration baseline", metadata: ["root": root]))
        }

        for (serviceID, label) in [("travel-portal", "Booking"), ("partner-portal", "Partner")] {
            guard let cwd = services.first(where: { $0.id == serviceID })?.resolvedCwd else { continue }
            checks.append(PreflightCheck(
                id: "env-diff-\(serviceID)",
                name: "\(label) env variables",
                metadata: ["cwd": cwd]
            ))
        }

        let ports = Set(services.compactMap { $0.probe?.port })
        // A port of a reuse_if_running service (Supabase) is in use when its stack runs.
        let reused = Set(services.filter(\.shouldReuseIfRunning).compactMap { $0.probe?.port })
        for port in ports.sorted() {
            checks.append(PreflightCheck(
                id: "port-\(port)", name: "Port \(port) available", metadata: reused.contains(port) ? ["reuse": "true"] : [:]
            ))
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

    /// The checks that only read: Node, the ports and the folders. The others can
    /// start a container runtime or ask Stripe.
    func readOnlyChecks(for services: [ServiceDefinition]) -> [PreflightCheck] {
        allChecks(for: services).filter {
            $0.id == "node-version" || $0.id.hasPrefix("port-") || $0.id.hasPrefix("dir-")
        }
    }

    private func nodeCwd(for services: [ServiceDefinition]) -> String? {
        services.first(where: { $0.id == "travel-portal" })?.resolvedCwd ?? services.compactMap(\.resolvedCwd).first
    }

    func run(check: PreflightCheck) async -> PreflightResult {
        switch check.id {
        case "docker":
            let runtime = ContainerRuntime.detect()
            if await ContainerRuntime.isResponding(shell: shell) {
                return .passed(detail: runtime.displayName)
            }
            if await ContainerRuntime.ensureRunning(shell: shell, clock: clock) {
                return .passed(detail: "\(runtime.displayName) — auto-started")
            }
            return .failed(message: "\(runtime.displayName) not responding", fix: "Open \(runtime.appName) manually")

        case "node-version":
            let result = await run("node --version", cwd: check.metadata["cwd"])
            if result.timedOut {
                return .failed(
                    message: Shell.timeoutText("node --version", after: Self.checkTimeout),
                    fix: "Run node --version in a terminal to see what it waits for"
                )
            }
            // A login profile can print lines first ("Now using node v22.3.0"): the
            // version is the last line that is only a version.
            guard let number = ToolVersion.parse(result.stdout) else {
                let printed = result.trimmedOutput
                if printed.isEmpty || result.exitCode == 127 {
                    return .failed(message: "Node.js not found", fix: "Install Node 22 via nvm or brew")
                }
                // Something answered (nvm: "N/A version is not installed"): show what it said.
                let lastLine = printed.components(separatedBy: .newlines).last ?? printed
                return .failed(
                    message: "node --version printed no version: \(lastLine)",
                    fix: "Run node --version in the portal folder"
                )
            }
            let version = "v\(number)"
            let major = EnvironmentChecker.major(of: number) ?? 0
            if major >= 22 {
                return .passed(detail: version)
            } else if major >= 18 {
                return .warning(message: "\(version) — recommend v22+")
            } else {
                return .failed(message: "\(version) — require v18+", fix: "Install Node 22 via nvm or brew")
            }

        case "stripe-auth":
            let hasStripe = await run("which stripe >/dev/null 2>&1").succeeded
            if !hasStripe { return .warning(message: "Not installed — Stripe will be skipped") }
            let key = StripeLauncher.resolve(bookingPortal: check.metadata["cwd"])
            let auth = await shell.run(
                StripeLauncher.authCheckCommand, environment: key.environment, timeout: Self.checkTimeout
            )
            if auth.timedOut {
                return .warning(
                    message: "\(Shell.timeoutText("stripe balance retrieve", after: Self.checkTimeout)) — Stripe will be skipped"
                )
            }
            switch key.mode {
            case .testKey(let source):
                return auth.succeeded
                    ? .passed(detail: "Test key from \(source)")
                    : .warning(message: "Stripe did not accept STRIPE_SECRET_KEY from \(source), or there is no network — Stripe will be skipped; import a current .env")
            case .login:
                return auth.succeeded
                    ? .passed(detail: "Authenticated")
                    : .warning(message: "Session invalid or expired — Stripe will be skipped; run: stripe login")
            }

        case "backend-baseline":
            return await backendBaseline(root: check.metadata["root"] ?? "")

        case let id where id.hasPrefix("env-diff"):
            // The monolith's scripts/env-check.mjs checks the app's shared .env (a teammate's
            // copy or pnpm env:pull) and the blank .env.local keys that would hide it. A missing
            // or stale file warns: local mode still runs, and remote mode refuses to switch.
            let cwd = check.metadata["cwd"] ?? ""
            let app: SharedEnvFiles.App = id == "env-diff-partner-portal" ? .partner : .booking
            let monorepo = ((cwd as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            let output = await shellOutput(SharedEnvFiles.command(monorepo: monorepo, app: app), cwd: monorepo)
            switch SharedEnvFiles.status(SharedEnvFiles.decode(output, app: app)) {
            case .passing(let detail): return .passed(detail: detail)
            case .warning(let message), .failing(let message): return .warning(message: message)
            case .pending, .fixing: return .warning(message: "Not checked")
            }

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
        let leftover = occupants.contains { occupant in
            if case .ownLeftover = occupant.owner { return true }
            return false
        }
        if leftover { return .passed(detail: "Held by a process from the last session — Start stops it") }
        if !occupants.isEmpty { return .passed(detail: "In use by \(Flavor.current.displayName)") }
        return .passed(detail: "Free")
    }
}
