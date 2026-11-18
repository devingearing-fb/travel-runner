import Foundation
import FlyingFox
import FlyingSocks

actor ControlServer {
    private var servers: [HTTPServer] = []
    private let port: UInt16
    /// The port the API listens on. Differs from the requested port only when that was 0.
    private(set) var boundPort: UInt16?
    /// Why a server stopped before it listened, by host.
    private var runErrors: [String: String] = [:]

    init(port: UInt16 = LaunchEnvironment.controlPort()) {
        self.port = port
    }

    /// One loopback address the API could not listen on.
    struct BindFailure: Sendable, Equatable {
        let host: String
        let port: UInt16
        let reason: String

        var message: String {
            "Control API is not listening on \(host):\(port): \(reason)."
        }

        /// One line for all failed addresses, or nil when there are none.
        /// Addresses that failed for the same reason share one sentence.
        static func summary(_ failures: [BindFailure]) -> String? {
            guard let first = failures.first else { return nil }
            guard failures.count > 1 else { return first.message }
            if failures.allSatisfy({ $0.reason == first.reason }) {
                let addresses = failures.map { "\($0.host):\($0.port)" }.joined(separator: " or ")
                return "Control API is not listening on \(addresses): \(first.reason)."
            }
            let addresses = failures.map { "\($0.host):\($0.port) (\($0.reason))" }.joined(separator: " or ")
            return "Control API is not listening on \(addresses)."
        }

        /// The likely cause and what to do. The runner binds only at launch, so the fix needs a relaunch.
        static func advice(appName: String = Flavor.current.displayName) -> String {
            "Another app or another copy of the runner may hold the port. Quit it, then quit and reopen \(appName)."
        }
    }

    struct Actions: Sendable {
        let getStatus: @Sendable () async -> String
        /// The checks of a start that change nothing, with their results.
        let getPreflight: @Sendable () async -> String
        /// The health and its reason.
        let getHealth: @Sendable () async -> String
        /// Each service with its phase and its reason.
        let getServices: @Sendable () async -> String
        /// The diagnostics snapshot of an issue, for now.
        let getDiagnostics: @Sendable () async -> String
        /// The events of `events.jsonl` that made no issue.
        let getEvents: @Sendable () async -> String
        /// The ids that have logs: the services and the DB steps (`db-setup-<step>`).
        let listLogs: @Sendable () async -> String
        let getLogs: @Sendable (String, Int) async -> ControlResult
        /// The service, and true when a restart of Supabase stops its containers too.
        let restartService: @Sendable (String, Bool) async -> ControlResult
        let clearCacheRestart: @Sendable (String) async -> ControlResult
        let startAll: @Sendable () async -> ControlResult
        let stopAll: @Sendable () async -> ControlResult
        let toggleLan: @Sendable () async -> ControlResult
        let restartCascade: @Sendable (String) async -> ControlResult
        /// The JSON body of the refusal while this runner is too old to reset the
        /// checkout (`Compatibility`), or nil. The four routes that change the
        /// database ask it first.
        let dbResetBlock: @Sendable () async -> String?
        let dbReset: @Sendable () async -> ControlResult
        let dbSetupRun: @Sendable (String) async -> ControlResult
        let dbSetupRetry: @Sendable (String) async -> ControlResult
        let dbSetupCancel: @Sendable () async -> ControlResult
        let dbSetupStatus: @Sendable () async -> String
        let dbSetupRunStep: @Sendable (String) async -> ControlResult
        let debugListIssues: @Sendable () async -> String
        let debugCapture: @Sendable (String) async -> ControlResult
        let debugCloseIssue: @Sendable (String, String?) async -> ControlResult
        let toggleDbMode: @Sendable () async -> ControlResult
        let getProfile: @Sendable () async -> String
        let setProfile: @Sendable (String) async -> ControlResult
    }

    /// Listens on `[::1]` and on `127.0.0.1`, so `localhost` works whichever family the
    /// client picks. Returns the addresses that failed; the other address keeps serving.
    @discardableResult
    func start(actions: Actions, logStore: LogStore) async -> [BindFailure] {
        var failures: [BindFailure] = []

        let v6 = HTTPServer(address: .loopback(port: port))
        await addRoutes(to: v6, actions: actions)
        var actualPort = port
        if let failure = await listen(v6, host: "[::1]", port: port) {
            failures.append(failure)
        } else if case .ip6(_, let listening)? = await v6.listeningAddress {
            actualPort = listening
        }

        do {
            let v4 = HTTPServer(address: try .inet(ip4: "127.0.0.1", port: actualPort))
            await addRoutes(to: v4, actions: actions)
            if let failure = await listen(v4, host: "127.0.0.1", port: actualPort) {
                failures.append(failure)
            } else if case .ip4(_, let listening)? = await v4.listeningAddress {
                actualPort = listening
            }
        } catch {
            failures.append(BindFailure(host: "127.0.0.1", port: actualPort, reason: Self.reason(error)))
        }

        boundPort = servers.isEmpty ? nil : actualPort
        if let summary = BindFailure.summary(failures) {
            print("[ControlAPI] \(summary) \(BindFailure.advice())")
        }
        if !servers.isEmpty {
            print("[ControlAPI] Listening on http://localhost:\(actualPort)")
        }
        return failures
    }

    /// Runs the server and waits until it listens. Returns the failure when it cannot.
    private func listen(_ server: HTTPServer, host: String, port: UInt16) async -> BindFailure? {
        runErrors[host] = nil
        Task {
            do {
                try await server.run()
            } catch {
                self.runErrors[host] = Self.reason(error)
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await server.isListening {
                servers.append(server)
                return nil
            }
            if let reason = runErrors[host] {
                return BindFailure(host: host, port: port, reason: reason)
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await server.stop()
        return BindFailure(host: host, port: port, reason: "the server did not start in 5 seconds")
    }

    private static func reason(_ error: any Error) -> String {
        if case .failed(_, _, let message)? = error as? SocketError { return message }
        return error.localizedDescription
    }

    private func addRoutes(to server: HTTPServer, actions: Actions) async {
        await server.appendRoute("GET /api/status") { _ in
            Self.json(await actions.getStatus())
        }

        await server.appendRoute("GET /api/preflight") { _ in
            Self.json(await actions.getPreflight())
        }

        await server.appendRoute("GET /api/health") { _ in
            Self.json(await actions.getHealth())
        }

        await server.appendRoute("GET /api/services") { _ in
            Self.json(await actions.getServices())
        }

        await server.appendRoute("GET /api/diagnostics") { _ in
            Self.json(await actions.getDiagnostics())
        }

        await server.appendRoute("GET /api/events") { _ in
            Self.json(await actions.getEvents())
        }

        await server.appendRoute("GET /api/logs") { _ in
            Self.json(await actions.listLogs())
        }

        await server.appendRoute("GET /api/logs/*") { request in
            let serviceId = Self.pathValue(request, after: 2)
            let lines: Int
            switch Self.lines(request) {
            case .success(let value): lines = value
            case .failure(let refusal): return refusal.response
            }
            return await actions.getLogs(serviceId, lines).response
        }

        await server.appendRoute("POST /api/restart/*") { request in
            let stack: Bool
            switch Self.flag(request, "stack") {
            case .success(let value): stack = value
            case .failure(let refusal): return refusal.response
            }
            return await actions.restartService(Self.pathValue(request, after: 2), stack).response
        }

        await server.appendRoute("POST /api/clear-cache-restart/*") { request in
            await actions.clearCacheRestart(Self.pathValue(request, after: 2)).response
        }

        await server.appendRoute("POST /api/start-all") { _ in
            await actions.startAll().response
        }

        await server.appendRoute("POST /api/stop-all") { _ in
            await actions.stopAll().response
        }

        await server.appendRoute("POST /api/toggle-lan") { _ in
            await actions.toggleLan().response
        }

        await server.appendRoute("POST /api/db-reset") { _ in
            if let blocked = await actions.dbResetBlock() { return Self.resetBlocked(blocked) }
            return await actions.dbReset().response
        }

        await server.appendRoute("POST /api/db-setup") { request in
            let profile: String
            switch Self.profile(inBody: try? await request.bodyData) {
            case .success(let value): profile = value
            case .failure(let refusal): return refusal.response
            }
            if let blocked = await actions.dbResetBlock() { return Self.resetBlocked(blocked) }
            return await actions.dbSetupRun(profile).response
        }

        await server.appendRoute("POST /api/db-setup/retry/*") { request in
            if let blocked = await actions.dbResetBlock() { return Self.resetBlocked(blocked) }
            return await actions.dbSetupRetry(Self.pathValue(request, after: 3)).response
        }

        await server.appendRoute("POST /api/db-setup/cancel") { _ in
            await actions.dbSetupCancel().response
        }

        await server.appendRoute("GET /api/db-setup/status") { _ in
            Self.json(await actions.dbSetupStatus())
        }

        await server.appendRoute("POST /api/db-setup/step/*") { request in
            if let blocked = await actions.dbResetBlock() { return Self.resetBlocked(blocked) }
            return await actions.dbSetupRunStep(Self.pathValue(request, after: 3)).response
        }

        await server.appendRoute("GET /api/debug/issues") { _ in
            Self.json(await actions.debugListIssues())
        }

        await server.appendRoute("POST /api/debug/issues") { request in
            let description: String
            switch Self.string("description", inBody: try? await request.bodyData) {
            case .success(let value): description = value ?? "Manual capture via API"
            case .failure(let refusal): return refusal.response
            }
            return await actions.debugCapture(description).response
        }

        await server.appendRoute("POST /api/debug/issues/close/*") { request in
            let resolution: String?
            switch Self.string("resolution", inBody: try? await request.bodyData) {
            case .success(let value): resolution = value
            case .failure(let refusal): return refusal.response
            }
            return await actions.debugCloseIssue(Self.pathValue(request, after: 4), resolution).response
        }

        await server.appendRoute("POST /api/restart-cascade/*") { request in
            await actions.restartCascade(Self.pathValue(request, after: 2)).response
        }

        await server.appendRoute("GET /api/profile") { _ in
            Self.json(await actions.getProfile())
        }

        await server.appendRoute("POST /api/profile/*") { request in
            await actions.setProfile(Self.pathValue(request, after: 2)).response
        }

        await server.appendRoute("POST /api/toggle-db-mode") { _ in
            await actions.toggleDbMode().response
        }

        // Last: a request that no route above takes gets a JSON 404.
        await server.appendRoute("/*") { request in
            ControlResult.notFound("no route \(request.method.rawValue) \(request.path)").response
        }
    }

    // MARK: - Request values

    /// 200 with a JSON body.
    static func json(_ body: String) -> HTTPResponse {
        ControlResult.json(body).response
    }

    /// The path from component `index` on: `/api/restart/<id>` has its id at 2.
    /// An issue id can hold a slash, so the rest of the path is one value.
    static func pathValue(_ request: HTTPRequest, after index: Int) -> String {
        request.path.split(separator: "/").dropFirst(index).joined(separator: "/")
    }

    /// `?lines=N` of `/api/logs/<id>`: 50 when it is not there, 400 when it is not a positive number.
    static func lines(_ request: HTTPRequest) -> Result<Int, ControlResult> {
        guard let text = request.query.first(where: { $0.name == "lines" })?.value else { return .success(50) }
        guard let value = Int(text), value > 0 else {
            return .failure(.badRequest("lines must be a positive number, not '\(text)'"))
        }
        return .success(value)
    }

    /// A yes/no query value: absent, `0` or `false` is no; `1` or `true` is yes.
    static func flag(_ request: HTTPRequest, _ name: String) -> Result<Bool, ControlResult> {
        guard let text = request.query.first(where: { $0.name == name })?.value else { return .success(false) }
        switch text.lowercased() {
        case "", "1", "true", "yes": return .success(true)
        case "0", "false", "no": return .success(false)
        default: return .failure(.badRequest("\(name) must be 1 or 0, not '\(text)'"))
        }
    }

    /// The `profile` of a db-setup body. No body, or an object without it, is `reset`.
    /// A body that is not a JSON object, or a profile that is not a string, is a 400:
    /// a bad request must never reset the database by default.
    static func profile(inBody body: Data?) -> Result<String, ControlResult> {
        string("profile", inBody: body).map { $0 ?? "reset" }
    }

    /// One string field of a JSON object body; nil when the body or the field is not there.
    static func string(_ field: String, inBody body: Data?) -> Result<String?, ControlResult> {
        guard let body, !body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
            return .success(nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .failure(.badRequest("the body must be a JSON object"))
        }
        guard let value = object[field] else { return .success(nil) }
        guard let text = value as? String else { return .failure(.badRequest("\(field) must be a string")) }
        return .success(text)
    }

    func stop() async {
        for server in servers {
            await server.stop()
        }
        servers = []
        boundPort = nil
    }

    /// 409: the runner is too old for the checkout, and the database was not touched.
    static func resetBlocked(_ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: .conflict, headers: [.contentType: "application/json"], body: Data(body.utf8))
    }
}

/// What a control API action did. Each case has its status code and JSON body
/// (`plans/…FRICTION_PLAN` 4.6, C7): a route never says ok when nothing ran.
enum ControlResult: Error, Equatable, Sendable {
    /// 200 with this body.
    case json(String)
    /// 200: done before the answer (a profile change).
    case done
    /// 202: the action runs now or after the operation before it.
    case accepted
    /// 202: Start All waits for the stop that runs.
    case queuedAfterStop
    case unknownService(String, known: [String])
    case unknownProfile(String, known: [String])
    case unknownStep(String, known: [String])
    /// 404 with this text: an issue, a log or a route that is not there.
    case notFound(String)
    /// 409: the same action already runs or waits. The text says which.
    case alreadyQueued(String)
    case alreadyStarting
    case stackStopped
    case stackStopping
    /// 409: a DB setup runs; the name of its step.
    case runActive(step: String)
    /// 409 with the reason.
    case refused(String)
    /// 422: no seed scenario is valid.
    case invalidScenario(String)
    /// 400: a parameter or a body that the route cannot read.
    case badRequest(String)

    static let stackStoppedText = "The stack is stopped. POST /api/start-all first."
    static let stackStoppingText = "The stack is stopping. Wait for it to stop, then POST /api/start-all."

    var statusCode: HTTPStatusCode {
        switch self {
        case .json, .done: .ok
        case .accepted, .queuedAfterStop: .accepted
        case .unknownService, .unknownStep, .notFound: .notFound
        case .unknownProfile, .badRequest: .badRequest
        case .alreadyQueued, .alreadyStarting, .stackStopped, .stackStopping, .runActive, .refused: .conflict
        case .invalidScenario: HTTPStatusCode(422, phrase: "Unprocessable Content")
        }
    }

    var body: String {
        var fields: [String: Any]
        switch self {
        case .json(let body): return body
        case .done: fields = ["ok": true]
        case .accepted: fields = ["ok": true, "accepted": true]
        case .queuedAfterStop: fields = ["ok": true, "accepted": true, "state": "queued_after_stop"]
        case .unknownService(let id, let known): fields = ["error": "unknown service '\(id)'", "known": known]
        case .unknownProfile(let name, let known): fields = ["error": "unknown profile '\(name)'", "known_profiles": known]
        case .unknownStep(let id, let known): fields = ["error": "unknown step '\(id)'", "known_steps": known]
        case .notFound(let text), .alreadyQueued(let text), .refused(let text), .invalidScenario(let text),
             .badRequest(let text):
            fields = ["error": text]
        case .alreadyStarting: fields = ["error": ActionFeedback.startInProgress]
        case .stackStopped: fields = ["error": Self.stackStoppedText]
        case .stackStopping: fields = ["error": Self.stackStoppingText]
        case .runActive(let step): fields = ["error": "a DB setup run is in progress (step: \(step))"]
        }
        if fields["ok"] == nil { fields["ok"] = false }
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    var response: HTTPResponse {
        HTTPResponse(statusCode: statusCode, headers: [.contentType: "application/json"], body: Data(body.utf8))
    }
}
