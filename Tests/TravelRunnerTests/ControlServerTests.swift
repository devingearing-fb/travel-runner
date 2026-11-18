import Darwin
import Foundation
import XCTest
@testable import TravelRunner

/// The control API on the loopback addresses. Every server here takes a port from the system.
final class ControlServerTests: XCTestCase {
    private var servers: [ControlServer] = []
    private var sockets: [Int32] = []

    override func tearDown() async throws {
        for server in servers { await server.stop() }
        for fd in sockets { close(fd) }
    }

    // MARK: - Helpers

    private static func actions(
        status: String,
        resetBlock: String? = nil,
        onDbChange: @escaping @Sendable (String) -> Void = { _ in }
    ) -> ControlServer.Actions {
        ControlServer.Actions(
            getStatus: { status },
            getPreflight: { "{\"checks\":[]}" },
            getHealth: { "{}" },
            getServices: { "[]" },
            getDiagnostics: { "{}" },
            getEvents: { "[]" },
            listLogs: { "{}" },
            getLogs: { _, _ in .json("[]") },
            restartService: { _, _ in .accepted },
            clearCacheRestart: { _ in .accepted },
            startAll: { .accepted },
            stopAll: { .accepted },
            toggleLan: { .accepted },
            restartCascade: { _ in .accepted },
            dbResetBlock: { resetBlock },
            dbReset: { onDbChange("reset"); return .accepted },
            dbSetupRun: { _ in onDbChange("run"); return .accepted },
            dbSetupRetry: { _ in onDbChange("retry"); return .accepted },
            dbSetupCancel: { .accepted },
            dbSetupStatus: { "{}" },
            dbSetupRunStep: { _ in onDbChange("step"); return .accepted },
            debugListIssues: { "[]" },
            debugStatus: { #"{"enabled":false,"open_issues":0}"# },
            debugCapture: { _ in .accepted },
            debugCloseIssue: { _, _ in .done },
            toggleDbMode: { .accepted },
            getProfile: { "{}" },
            setProfile: { _ in .done }
        )
    }

    private func makeServer(port: UInt16) -> ControlServer {
        let server = ControlServer(port: port)
        servers.append(server)
        return server
    }

    /// A server on a port from the system that listens on both loopback addresses.
    /// The system picks a port that is free on [::1]; another program can hold it on
    /// 127.0.0.1, and a request there then reaches that program. Such a port is
    /// skipped. Returns the server and its port.
    private func startOnFreePort(actions: ControlServer.Actions) async throws -> (ControlServer, UInt16) {
        for _ in 0..<10 {
            let server = makeServer(port: 0)
            let failures = await server.start(actions: actions, logStore: LogStore())
            let boundPort = await server.boundPort
            if failures.isEmpty, let port = boundPort { return (server, port) }
            await server.stop()
        }
        throw XCTSkip("no port was free on both loopback addresses")
    }

    /// The body of GET /api/status on one host, or nil when nothing answers.
    private func status(host: String, port: UInt16) async -> String? {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let url = URL(string: "http://\(host):\(port)/api/status"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Listens on 127.0.0.1 only, on a port from the system. Returns that port.
    private func holdIPv4Port() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        sockets.append(fd)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr -> Bool in
                Darwin.bind(fd, ptr, len) == 0 && listen(fd, 1) == 0 && getsockname(fd, ptr, &len) == 0
            }
        }
        XCTAssertTrue(bound)
        return UInt16(bigEndian: addr.sin_port)
    }

    // MARK: - Tests

    func testBothLoopbackFamiliesAnswer() async throws {
        let server = makeServer(port: 0)
        let failures = await server.start(actions: Self.actions(status: #"{"marker":"one"}"#), logStore: LogStore())
        XCTAssertEqual(failures, [])
        let boundPort = await server.boundPort
        let port = try XCTUnwrap(boundPort)
        XCTAssertNotEqual(port, 0)

        let v4 = await status(host: "127.0.0.1", port: port)
        let v6 = await status(host: "[::1]", port: port)
        XCTAssertEqual(v4, #"{"marker":"one"}"#)
        XCTAssertEqual(v6, #"{"marker":"one"}"#)
    }

    func testATakenPortGivesAFailureForEachAddress() async throws {
        let first = makeServer(port: 0)
        let firstFailures = await first.start(actions: Self.actions(status: "first"), logStore: LogStore())
        XCTAssertEqual(firstFailures, [])
        let boundPort = await first.boundPort
        let port = try XCTUnwrap(boundPort)

        let second = makeServer(port: port)
        let failures = await second.start(actions: Self.actions(status: "second"), logStore: LogStore())

        XCTAssertEqual(failures.map(\.host), ["[::1]", "127.0.0.1"])
        XCTAssertEqual(failures.map(\.port), [port, port])
        for failure in failures {
            XCTAssertTrue(failure.reason.contains("Address already in use"), failure.reason)
            XCTAssertTrue(failure.message.contains("\(failure.host):\(port)"), failure.message)
        }
        let secondPort = await second.boundPort
        XCTAssertNil(secondPort)

        // The first server still owns the port.
        let v4 = await status(host: "127.0.0.1", port: port)
        let v6 = await status(host: "[::1]", port: port)
        XCTAssertEqual(v4, "first")
        XCTAssertEqual(v6, "first")
    }

    func testOneTakenAddressLeavesTheOtherServing() async throws {
        let port = try holdIPv4Port()
        let server = makeServer(port: port)
        let failures = await server.start(actions: Self.actions(status: "v6 only"), logStore: LogStore())

        XCTAssertEqual(failures.map(\.host), ["127.0.0.1"])
        XCTAssertEqual(
            failures.first?.message,
            "Control API is not listening on 127.0.0.1:\(port): Address already in use."
        )
        XCTAssertEqual(ControlServer.BindFailure.summary(failures), failures.first?.message)
        let boundPort = await server.boundPort
        XCTAssertEqual(boundPort, port)
        let v6 = await status(host: "[::1]", port: port)
        XCTAssertEqual(v6, "v6 only")
    }

    // MARK: - Banner text

    func testNoFailuresGiveNoBannerText() {
        XCTAssertNil(ControlServer.BindFailure.summary([]))
    }

    func testTwoAddressesWithOneReasonShareOneLine() {
        let failures = [
            ControlServer.BindFailure(host: "[::1]", port: 19900, reason: "Address already in use"),
            ControlServer.BindFailure(host: "127.0.0.1", port: 19900, reason: "Address already in use"),
        ]
        XCTAssertEqual(
            ControlServer.BindFailure.summary(failures),
            "Control API is not listening on [::1]:19900 or 127.0.0.1:19900: Address already in use."
        )
    }

    func testTwoAddressesWithDifferentReasonsKeepBothReasons() {
        let failures = [
            ControlServer.BindFailure(host: "[::1]", port: 19900, reason: "Address already in use"),
            ControlServer.BindFailure(host: "127.0.0.1", port: 19900, reason: "Permission denied"),
        ]
        XCTAssertEqual(
            ControlServer.BindFailure.summary(failures),
            "Control API is not listening on [::1]:19900 (Address already in use) or 127.0.0.1:19900 (Permission denied)."
        )
    }

    func testAdviceSaysWhatToDo() {
        XCTAssertEqual(
            ControlServer.BindFailure.advice(appName: "Travel Runner"),
            "Another app or another copy of the runner may hold the port. Quit it, then quit and reopen Travel Runner."
        )
    }

    func testStopFreesBothAddresses() async throws {
        let (server, port) = try await startOnFreePort(actions: Self.actions(status: "up"))

        await server.stop()

        let v4 = await status(host: "127.0.0.1", port: port)
        let v6 = await status(host: "[::1]", port: port)
        XCTAssertNil(v4)
        XCTAssertNil(v6)
    }

    /// The four routes that change the database answer 409 while the runner is too
    /// old for the checkout, and run nothing.
    /// The release smoke test asks this route (`scripts/smoke.sh`).
    func testThePreflightRouteGivesTheAnswerOfTheAction() async throws {
        let (_, port) = try await startOnFreePort(actions: Self.actions(status: "{}"))
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/preflight"))
        let (data, response) = try await session.data(from: url)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"checks":[]}"#)
    }

    func testTheDatabaseRoutesRefuseWhileTheRunnerIsTooOld() async throws {
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var names: [String] = []
            func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
        }
        let routes = ["/api/db-reset", "/api/db-setup", "/api/db-setup/retry/reset-database", "/api/db-setup/step/reset-database"]
        let refusal = #"{"error":"runner_too_old","ok":false}"#

        func post(_ path: String, port: UInt16) async throws -> (Int, String) {
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = 5
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
            request.httpMethod = "POST"
            let (data, response) = try await session.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
        }

        let blockedCalls = Calls()
        let (_, blockedPort) = try await startOnFreePort(
            actions: Self.actions(status: "{}", resetBlock: refusal, onDbChange: { blockedCalls.add($0) })
        )
        for route in routes {
            let (code, body) = try await post(route, port: blockedPort)
            XCTAssertEqual(code, 409, route)
            XCTAssertEqual(body, refusal, route)
        }
        XCTAssertEqual(blockedCalls.all, [])

        // Control: with no refusal, every route runs its action.
        let openCalls = Calls()
        let (_, openPort) = try await startOnFreePort(
            actions: Self.actions(status: "{}", onDbChange: { openCalls.add($0) })
        )
        for route in routes {
            let (code, _) = try await post(route, port: openPort)
            XCTAssertEqual(code, 202, route)
        }
        XCTAssertEqual(openCalls.all, ["reset", "run", "retry", "step"])
    }

    // MARK: - Routes

    /// The actions that the routes called, with what each got.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func add(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
        func take() -> [String] { lock.lock(); defer { entries = []; lock.unlock() }; return entries }
    }

    /// Actions that record each call and answer with a body that names the action.
    /// `answer` gives the result of an action by its record; nil is `.accepted`.
    private static func recording(
        _ calls: Recorder, answer: @escaping @Sendable (String) -> ControlResult? = { _ in nil }
    ) -> ControlServer.Actions {
        @Sendable func act(_ entry: String) -> ControlResult {
            calls.add(entry)
            return answer(entry) ?? .accepted
        }
        return ControlServer.Actions(
            getStatus: { calls.add("status"); return #"{"a":"status"}"# },
            getPreflight: { calls.add("preflight"); return #"{"a":"preflight"}"# },
            getHealth: { calls.add("health"); return #"{"a":"health"}"# },
            getServices: { calls.add("services"); return #"{"a":"services"}"# },
            getDiagnostics: { calls.add("diagnostics"); return #"{"a":"diagnostics"}"# },
            getEvents: { calls.add("events"); return #"{"a":"events"}"# },
            listLogs: { calls.add("log-ids"); return #"{"a":"log-ids"}"# },
            getLogs: { id, lines in
                calls.add("logs \(id) \(lines)")
                return answer("logs \(id) \(lines)") ?? .json(#"{"a":"logs"}"#)
            },
            restartService: { id, stack in act("restart \(id)\(stack ? " stack" : "")") },
            clearCacheRestart: { act("clear-cache-restart \($0)") },
            startAll: { act("start-all") },
            stopAll: { act("stop-all") },
            toggleLan: { act("toggle-lan") },
            restartCascade: { act("restart-cascade \($0)") },
            dbResetBlock: { nil },
            dbReset: { act("db-reset") },
            dbSetupRun: { act("db-setup \($0)") },
            dbSetupRetry: { act("db-setup-retry \($0)") },
            dbSetupCancel: { act("db-setup-cancel") },
            dbSetupStatus: { calls.add("db-setup-status"); return #"{"a":"db-setup-status"}"# },
            dbSetupRunStep: { act("db-setup-step \($0)") },
            debugListIssues: { calls.add("issues"); return #"{"a":"issues"}"# },
            debugStatus: { calls.add("debug-status"); return #"{"a":"debug-status"}"# },
            debugCapture: { act("capture \($0)") },
            debugCloseIssue: { id, resolution in act("close \(id) \(resolution ?? "nil")") },
            toggleDbMode: { act("toggle-db-mode") },
            getProfile: { calls.add("profile"); return #"{"a":"profile"}"# },
            setProfile: { name in act("set-profile \(name)") }
        )
    }

    private func request(
        _ method: String, _ path: String, body: String? = nil, port: UInt16
    ) async throws -> (code: Int, body: String) {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(path)")))
        request.httpMethod = method
        if let body {
            request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    /// Each route calls its one action with the values of the path, the query and
    /// the body, and answers with what the action gave.
    func testEachRouteCallsItsActionWithTheRequestValues() async throws {
        let calls = Recorder()
        let (_, port) = try await startOnFreePort(actions: Self.recording(calls))
        let accepted = #"{"accepted":true,"ok":true}"#
        let rows: [(method: String, path: String, body: String?, code: Int, answer: String, calls: [String])] = [
            ("GET", "/api/status", nil, 200, #"{"a":"status"}"#, ["status"]),
            ("GET", "/api/preflight", nil, 200, #"{"a":"preflight"}"#, ["preflight"]),
            ("GET", "/api/health", nil, 200, #"{"a":"health"}"#, ["health"]),
            ("GET", "/api/services", nil, 200, #"{"a":"services"}"#, ["services"]),
            ("GET", "/api/diagnostics", nil, 200, #"{"a":"diagnostics"}"#, ["diagnostics"]),
            ("GET", "/api/events", nil, 200, #"{"a":"events"}"#, ["events"]),
            ("GET", "/api/logs", nil, 200, #"{"a":"log-ids"}"#, ["log-ids"]),
            ("GET", "/api/logs/travel-portal?lines=7", nil, 200, #"{"a":"logs"}"#, ["logs travel-portal 7"]),
            ("GET", "/api/logs/travel-portal", nil, 200, #"{"a":"logs"}"#, ["logs travel-portal 50"]),
            ("GET", "/api/logs/db-setup-load-hotels", nil, 200, #"{"a":"logs"}"#, ["logs db-setup-load-hotels 50"]),
            ("POST", "/api/restart/partner-portal", nil, 202, accepted, ["restart partner-portal"]),
            ("POST", "/api/restart/supabase?stack=1", nil, 202, accepted, ["restart supabase stack"]),
            ("POST", "/api/clear-cache-restart/travel-portal", nil, 202, accepted, ["clear-cache-restart travel-portal"]),
            ("POST", "/api/restart-cascade/supabase", nil, 202, accepted, ["restart-cascade supabase"]),
            ("POST", "/api/start-all", nil, 202, accepted, ["start-all"]),
            ("POST", "/api/stop-all", nil, 202, accepted, ["stop-all"]),
            ("POST", "/api/toggle-lan", nil, 202, accepted, ["toggle-lan"]),
            ("POST", "/api/toggle-db-mode", nil, 202, accepted, ["toggle-db-mode"]),
            ("POST", "/api/db-reset", nil, 202, accepted, ["db-reset"]),
            ("POST", "/api/db-setup", #"{"profile":"seed"}"#, 202, accepted, ["db-setup seed"]),
            ("POST", "/api/db-setup", nil, 202, accepted, ["db-setup reset"]),
            ("POST", "/api/db-setup", "{}", 202, accepted, ["db-setup reset"]),
            ("POST", "/api/db-setup/retry/load-hotels", nil, 202, accepted, ["db-setup-retry load-hotels"]),
            ("POST", "/api/db-setup/step/verify-data", nil, 202, accepted, ["db-setup-step verify-data"]),
            ("POST", "/api/db-setup/cancel", nil, 202, accepted, ["db-setup-cancel"]),
            ("GET", "/api/db-setup/status", nil, 200, #"{"a":"db-setup-status"}"#, ["db-setup-status"]),
            ("GET", "/api/debug/issues", nil, 200, #"{"a":"issues"}"#, ["issues"]),
            ("GET", "/api/debug/status", nil, 200, #"{"a":"debug-status"}"#, ["debug-status"]),
            ("POST", "/api/debug/issues", #"{"description":"portal hangs"}"#, 202, accepted, ["capture portal hangs"]),
            ("POST", "/api/debug/issues", nil, 202, accepted, ["capture Manual capture via API"]),
            ("POST", "/api/debug/issues/close/2026/abc", #"{"resolution":"fixed"}"#, 202, accepted,
             ["close 2026/abc fixed"]),
            ("POST", "/api/debug/issues/close/abc", nil, 202, accepted, ["close abc nil"]),
            ("GET", "/api/profile", nil, 200, #"{"a":"profile"}"#, ["profile"]),
            ("POST", "/api/profile/booking", nil, 202, accepted, ["set-profile booking"]),
        ]
        for row in rows {
            let name = "\(row.method) \(row.path)"
            let (code, body) = try await request(row.method, row.path, body: row.body, port: port)
            XCTAssertEqual(code, row.code, name)
            XCTAssertEqual(body, row.answer, name)
            XCTAssertEqual(calls.take(), row.calls, name)
        }
    }

    /// A parameter or a body that the route cannot read is a 400, and runs nothing:
    /// a body that is not JSON must never reset the database by default.
    func testAMalformedRequestIsA400AndRunsNothing() async throws {
        let calls = Recorder()
        let (_, port) = try await startOnFreePort(actions: Self.recording(calls))
        let rows: [(method: String, path: String, body: String?, error: String)] = [
            ("POST", "/api/db-setup", "not json", "the body must be a JSON object"),
            ("POST", "/api/db-setup", #"["reset"]"#, "the body must be a JSON object"),
            ("POST", "/api/db-setup", #"{"profile":7}"#, "profile must be a string"),
            ("GET", "/api/logs/travel-portal?lines=many", nil, "lines must be a positive number, not 'many'"),
            ("GET", "/api/logs/travel-portal?lines=0", nil, "lines must be a positive number, not '0'"),
            ("POST", "/api/restart/supabase?stack=maybe", nil, "stack must be 1 or 0, not 'maybe'"),
            ("POST", "/api/debug/issues", "not json", "the body must be a JSON object"),
            ("POST", "/api/debug/issues/close/abc", #"{"resolution":1}"#, "resolution must be a string"),
        ]
        for row in rows {
            let name = "\(row.method) \(row.path) \(row.body ?? "")"
            let (code, body) = try await request(row.method, row.path, body: row.body, port: port)
            XCTAssertEqual(code, 400, name)
            XCTAssertEqual(body, #"{"error":"\#(row.error)","ok":false}"#, name)
            XCTAssertEqual(calls.take(), [], name)
        }
    }

    /// Each refusal of an action has its status and a body that says why.
    func testEachRefusalHasItsStatusAndReason() async throws {
        let calls = Recorder()
        let answers: [String: ControlResult] = [
            "restart nope": .unknownService("nope", known: ["supabase", "travel-portal"]),
            "restart travel-portal": .alreadyQueued("Booking Portal is already restarting."),
            "clear-cache-restart travel-portal": .stackStopped,
            "restart-cascade supabase": .stackStopping,
            "start-all": .queuedAfterStop,
            "toggle-lan": .alreadyQueued("A LAN mode change is already running."),
            "toggle-db-mode": .refused("A start is in progress — wait for it to finish, or stop the stack, then switch."),
            "db-setup nonsense": .unknownProfile("nonsense", known: ["fast", "reset"]),
            "db-setup reset": .runActive(step: "Reset & Seed Data"),
            "db-reset": .invalidScenario("Choose a valid seed scenario before resetting the database."),
            "db-setup-step nope": .unknownStep("nope", known: ["load-hotels", "verify-data"]),
            "db-setup-cancel": .refused("No database setup is running."),
            "capture x": .refused("issue capture is off"),
            "close gone nil": .notFound("issue not found"),
            "set-profile nonsense": .unknownProfile("nonsense", known: ["booking", "partner", "both", "full"]),
            "logs nope 50": .notFound("no log 'nope'"),
            "stop-all": .runnerQuitting,
            "db-setup-retry load-hotels": .alreadyQueued("A database setup already waits for the running start or step."),
        ]
        let (_, port) = try await startOnFreePort(actions: Self.recording(calls, answer: { answers[$0] }))
        let rows: [(method: String, path: String, body: String?, code: Int, answer: String)] = [
            ("POST", "/api/restart/nope", nil, 404,
             #"{"error":"unknown service 'nope'","known":["supabase","travel-portal"],"ok":false}"#),
            ("POST", "/api/restart/travel-portal", nil, 409, #"{"error":"Booking Portal is already restarting.","ok":false}"#),
            ("POST", "/api/clear-cache-restart/travel-portal", nil, 409,
             #"{"error":"The stack is stopped. POST /api/start-all first.","ok":false}"#),
            ("POST", "/api/restart-cascade/supabase", nil, 409,
             #"{"error":"The stack is stopping. Wait for it to stop, then POST /api/start-all.","ok":false}"#),
            ("POST", "/api/start-all", nil, 202, #"{"accepted":true,"ok":true,"state":"queued_after_stop"}"#),
            ("POST", "/api/toggle-lan", nil, 409, #"{"error":"A LAN mode change is already running.","ok":false}"#),
            ("POST", "/api/toggle-db-mode", nil, 409,
             #"{"error":"A start is in progress — wait for it to finish, or stop the stack, then switch.","ok":false}"#),
            ("POST", "/api/db-setup", #"{"profile":"nonsense"}"#, 400,
             #"{"error":"unknown profile 'nonsense'","known_profiles":["fast","reset"],"ok":false}"#),
            ("POST", "/api/db-setup", nil, 409, #"{"error":"a DB setup run is in progress (step: Reset & Seed Data)","ok":false}"#),
            ("POST", "/api/db-reset", nil, 422,
             #"{"error":"Choose a valid seed scenario before resetting the database.","ok":false}"#),
            ("POST", "/api/db-setup/step/nope", nil, 404,
             #"{"error":"unknown step 'nope'","known_steps":["load-hotels","verify-data"],"ok":false}"#),
            ("POST", "/api/db-setup/cancel", nil, 409, #"{"error":"No database setup is running.","ok":false}"#),
            ("POST", "/api/debug/issues", #"{"description":"x"}"#, 409, #"{"error":"issue capture is off","ok":false}"#),
            ("POST", "/api/debug/issues/close/gone", nil, 404, #"{"error":"issue not found","ok":false}"#),
            ("POST", "/api/profile/nonsense", nil, 400,
             #"{"error":"unknown profile 'nonsense'","known_profiles":["booking","partner","both","full"],"ok":false}"#),
            ("GET", "/api/logs/nope", nil, 404, #"{"error":"no log 'nope'","ok":false}"#),
            ("POST", "/api/stop-all", nil, 409, #"{"error":"The runner is quitting.","ok":false}"#),
            ("POST", "/api/db-setup/retry/load-hotels", nil, 409,
             #"{"error":"A database setup already waits for the running start or step.","ok":false}"#),
        ]
        for row in rows {
            let name = "\(row.method) \(row.path)"
            let (code, body) = try await request(row.method, row.path, body: row.body, port: port)
            XCTAssertEqual(code, row.code, name)
            XCTAssertEqual(body, row.answer, name)
        }
    }

    /// A route with no id, a wrong method or an unknown path runs no action.
    func testARequestThatMatchesNoRouteRunsNothing() async throws {
        let calls = Recorder()
        let (_, port) = try await startOnFreePort(actions: Self.recording(calls))
        let rows: [(method: String, path: String)] = [
            ("GET", "/api/start-all"),
            ("GET", "/api/db-reset"),
            ("POST", "/api/status"),
            ("GET", "/api/restart/travel-portal"),
            ("POST", "/api/restart/"),
            ("POST", "/api/clear-cache-restart/"),
            ("POST", "/api/db-setup/retry/"),
            ("POST", "/api/unknown"),
            ("GET", "/"),
        ]
        for row in rows {
            let name = "\(row.method) \(row.path)"
            let (code, body) = try await request(row.method, row.path, port: port)
            XCTAssertEqual(code, 404, name)
            XCTAssertTrue(body.hasPrefix(#"{"error":"no route "#), "\(name): \(body)")
            XCTAssertEqual(calls.take(), [], name)
        }
    }
}
