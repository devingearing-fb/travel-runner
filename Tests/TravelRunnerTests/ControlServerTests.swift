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

    private static func actions(status: String) -> ControlServer.Actions {
        ControlServer.Actions(
            getStatus: { status },
            getLogs: { _, _ in "[]" },
            restartService: { _ in },
            clearCacheRestart: { _ in },
            startAll: {},
            stopAll: {},
            toggleLan: {},
            restartCascade: { _ in },
            dbReset: {},
            dbSetupRun: { _ in },
            dbSetupRetry: { _ in },
            dbSetupCancel: {},
            dbSetupStatus: { "{}" },
            dbSetupRunStep: { _ in },
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
            "Control API is not listening on 127.0.0.1:\(port): Address already in use. Another app or another copy of the runner may hold the port."
        )
        let boundPort = await server.boundPort
        XCTAssertEqual(boundPort, port)
        let v6 = await status(host: "[::1]", port: port)
        XCTAssertEqual(v6, "v6 only")
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
}
