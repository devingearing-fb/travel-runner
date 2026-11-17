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
        let server = makeServer(port: 0)
        _ = await server.start(actions: Self.actions(status: "up"), logStore: LogStore())
        let boundPort = await server.boundPort
        let port = try XCTUnwrap(boundPort)

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
        let server = makeServer(port: 0)
        _ = await server.start(actions: Self.actions(status: "{}"), logStore: LogStore())
        let boundPort = await server.boundPort
        let port = try XCTUnwrap(boundPort)
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
        let blocked = makeServer(port: 0)
        _ = await blocked.start(
            actions: Self.actions(status: "{}", resetBlock: refusal, onDbChange: { blockedCalls.add($0) }),
            logStore: LogStore()
        )
        let blockedBound = await blocked.boundPort
        let blockedPort = try XCTUnwrap(blockedBound)
        for route in routes {
            let (code, body) = try await post(route, port: blockedPort)
            XCTAssertEqual(code, 409, route)
            XCTAssertEqual(body, refusal, route)
        }
        XCTAssertEqual(blockedCalls.all, [])

        // Control: with no refusal, every route runs its action.
        let openCalls = Calls()
        let open = makeServer(port: 0)
        _ = await open.start(
            actions: Self.actions(status: "{}", onDbChange: { openCalls.add($0) }),
            logStore: LogStore()
        )
        let openBound = await open.boundPort
        let openPort = try XCTUnwrap(openBound)
        for route in routes {
            let (code, _) = try await post(route, port: openPort)
            XCTAssertEqual(code, 200, route)
        }
        XCTAssertEqual(openCalls.all, ["reset", "run", "retry", "step"])
    }
}
