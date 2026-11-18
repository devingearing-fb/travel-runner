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
            getLogs: { _, _ in "[]" },
            restartService: { _ in },
            clearCacheRestart: { _ in },
            startAll: {},
            stopAll: {},
            toggleLan: {},
            restartCascade: { _ in },
            dbResetBlock: { resetBlock },
            dbReset: { onDbChange("reset") },
            dbSetupRun: { _ in onDbChange("run") },
            dbSetupRetry: { _ in onDbChange("retry") },
            dbSetupCancel: {},
            dbSetupStatus: { "{}" },
            dbSetupRunStep: { _ in onDbChange("step") },
            debugListIssues: { "[]" },
            debugCapture: { _ in "{}" },
            debugCloseIssue: { _, _ in "{}" },
            toggleDbMode: {},
            getProfile: { "{}" },
            setProfile: { _ in true }
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
            XCTAssertEqual(code, 200, route)
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
    private static func recording(_ calls: Recorder) -> ControlServer.Actions {
        ControlServer.Actions(
            getStatus: { calls.add("status"); return #"{"a":"status"}"# },
            getPreflight: { calls.add("preflight"); return #"{"a":"preflight"}"# },
            getLogs: { id, lines in calls.add("logs \(id) \(lines)"); return #"{"a":"logs"}"# },
            restartService: { calls.add("restart \($0)") },
            clearCacheRestart: { calls.add("clear-cache-restart \($0)") },
            startAll: { calls.add("start-all") },
            stopAll: { calls.add("stop-all") },
            toggleLan: { calls.add("toggle-lan") },
            restartCascade: { calls.add("restart-cascade \($0)") },
            dbResetBlock: { nil },
            dbReset: { calls.add("db-reset") },
            dbSetupRun: { calls.add("db-setup \($0)") },
            dbSetupRetry: { calls.add("db-setup-retry \($0)") },
            dbSetupCancel: { calls.add("db-setup-cancel") },
            dbSetupStatus: { calls.add("db-setup-status"); return #"{"a":"db-setup-status"}"# },
            dbSetupRunStep: { calls.add("db-setup-step \($0)") },
            debugListIssues: { calls.add("issues"); return #"{"a":"issues"}"# },
            debugCapture: { calls.add("capture \($0)"); return #"{"a":"capture"}"# },
            debugCloseIssue: { id, resolution in
                calls.add("close \(id) \(resolution ?? "nil")"); return #"{"a":"close"}"#
            },
            toggleDbMode: { calls.add("toggle-db-mode") },
            getProfile: { calls.add("profile"); return #"{"a":"profile"}"# },
            setProfile: { name in calls.add("set-profile \(name)"); return name == "booking" }
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
        let ok = #"{"ok":true}"#
        let rows: [(method: String, path: String, body: String?, code: Int, answer: String, calls: [String])] = [
            ("GET", "/api/status", nil, 200, #"{"a":"status"}"#, ["status"]),
            ("GET", "/api/preflight", nil, 200, #"{"a":"preflight"}"#, ["preflight"]),
            ("GET", "/api/logs/travel-portal?lines=7", nil, 200, #"{"a":"logs"}"#, ["logs travel-portal 7"]),
            ("GET", "/api/logs/travel-portal", nil, 200, #"{"a":"logs"}"#, ["logs travel-portal 50"]),
            ("GET", "/api/logs/travel-portal?lines=many", nil, 200, #"{"a":"logs"}"#, ["logs travel-portal 50"]),
            ("POST", "/api/restart/partner-portal", nil, 200, ok, ["restart partner-portal"]),
            ("POST", "/api/clear-cache-restart/travel-portal", nil, 200, ok, ["clear-cache-restart travel-portal"]),
            ("POST", "/api/restart-cascade/supabase", nil, 200, ok, ["restart-cascade supabase"]),
            ("POST", "/api/start-all", nil, 200, ok, ["start-all"]),
            ("POST", "/api/stop-all", nil, 200, ok, ["stop-all"]),
            ("POST", "/api/toggle-lan", nil, 200, ok, ["toggle-lan"]),
            ("POST", "/api/toggle-db-mode", nil, 200, ok, ["toggle-db-mode"]),
            ("POST", "/api/db-reset", nil, 200, ok, ["db-reset"]),
            ("POST", "/api/db-setup", #"{"profile":"seed"}"#, 200, ok, ["db-setup seed"]),
            ("POST", "/api/db-setup", nil, 200, ok, ["db-setup reset"]),
            ("POST", "/api/db-setup", "not json", 200, ok, ["db-setup reset"]),
            ("POST", "/api/db-setup/retry/load-hotels", nil, 200, ok, ["db-setup-retry load-hotels"]),
            ("POST", "/api/db-setup/step/verify-data", nil, 200, ok, ["db-setup-step verify-data"]),
            ("POST", "/api/db-setup/cancel", nil, 200, ok, ["db-setup-cancel"]),
            ("GET", "/api/db-setup/status", nil, 200, #"{"a":"db-setup-status"}"#, ["db-setup-status"]),
            ("GET", "/api/debug/issues", nil, 200, #"{"a":"issues"}"#, ["issues"]),
            ("POST", "/api/debug/issues", #"{"description":"portal hangs"}"#, 200, #"{"a":"capture"}"#,
             ["capture portal hangs"]),
            ("POST", "/api/debug/issues", nil, 200, #"{"a":"capture"}"#, ["capture Manual capture via API"]),
            ("POST", "/api/debug/issues/close/2026/abc", #"{"resolution":"fixed"}"#, 200, #"{"a":"close"}"#,
             ["close 2026/abc fixed"]),
            ("POST", "/api/debug/issues/close/abc", nil, 200, #"{"a":"close"}"#, ["close abc nil"]),
            ("GET", "/api/profile", nil, 200, #"{"a":"profile"}"#, ["profile"]),
            ("POST", "/api/profile/booking", nil, 200, ok, ["set-profile booking"]),
            ("POST", "/api/profile/nonsense", nil, 400, #"{"ok":false,"error":"unknown profile"}"#,
             ["set-profile nonsense"]),
        ]
        for row in rows {
            let name = "\(row.method) \(row.path)"
            let (code, body) = try await request(row.method, row.path, body: row.body, port: port)
            XCTAssertEqual(code, row.code, name)
            XCTAssertEqual(body, row.answer, name)
            XCTAssertEqual(calls.take(), row.calls, name)
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
            ("POST", "/api/unknown"),
            ("GET", "/"),
        ]
        for row in rows {
            let name = "\(row.method) \(row.path)"
            let (code, _) = try await request(row.method, row.path, port: port)
            XCTAssertNotEqual(code, 200, name)
            XCTAssertEqual(calls.take(), [], name)
        }
    }
}
