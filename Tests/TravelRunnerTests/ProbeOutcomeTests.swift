import Foundation
import Network
import XCTest
@testable import TravelRunner

/// A probe check says why it failed, not only that it failed.
final class ProbeOutcomeTests: XCTestCase {
    // MARK: - The outcome itself

    func testStatusesMapToOutcomes() {
        XCTAssertEqual(ProbeOutcome.from(status: 200, location: nil), .ok)
        XCTAssertEqual(ProbeOutcome.from(status: 204, location: nil), .ok)
        XCTAssertEqual(ProbeOutcome.from(status: 307, location: "/login"), .redirect(to: "/login"))
        XCTAssertEqual(ProbeOutcome.from(status: 404, location: nil), .http(status: 404))
        XCTAssertEqual(ProbeOutcome.from(status: 500, location: nil), .http(status: 500))
    }

    func testUrlErrorsMapToOutcomes() {
        XCTAssertEqual(ProbeOutcome.from(urlError: URLError(.cannotConnectToHost)), .refused)
        XCTAssertEqual(ProbeOutcome.from(urlError: URLError(.timedOut)), .timedOut)
        XCTAssertEqual(ProbeOutcome.from(urlError: URLError(.cannotFindHost)), .dnsError)
        XCTAssertEqual(ProbeOutcome.from(urlError: URLError(.dnsLookupFailed)), .dnsError)
        guard case .other = ProbeOutcome.from(urlError: URLError(.networkConnectionLost)) else {
            return XCTFail("a lost connection is another failure")
        }
    }

    func testTcpErrorsMapToOutcomes() {
        XCTAssertEqual(TcpProbe.outcome(of: .posix(.ECONNREFUSED)), .refused)
        XCTAssertEqual(TcpProbe.outcome(of: .posix(.ECONNRESET)), .refused)
        XCTAssertEqual(TcpProbe.outcome(of: .posix(.ETIMEDOUT)), .timedOut)
        guard case .other = TcpProbe.outcome(of: .posix(.EHOSTUNREACH)) else {
            return XCTFail("an unreachable host is another failure")
        }
    }

    /// Only an answer of a server that runs counts as ready. Each failure has a
    /// negative control here.
    func testOnlyOkAndARedirectAreReady() {
        XCTAssertTrue(ProbeOutcome.ok.isReady)
        XCTAssertTrue(ProbeOutcome.redirect(to: "/login").isReady)
        let notReady: [ProbeOutcome] = [
            .refused, .timedOut, .http(status: 404), .http(status: 503), .notFoundThenRoot(.http(status: 500)), .dnsError,
            .noMatchYet, .other("x"),
        ]
        for outcome in notReady {
            XCTAssertFalse(outcome.isReady, outcome.summary)
        }
    }

    func testEachOutcomeHasWords() {
        XCTAssertEqual(ProbeOutcome.refused.summary, "connection refused")
        XCTAssertEqual(ProbeOutcome.timedOut.summary, "no answer in time")
        XCTAssertEqual(ProbeOutcome.http(status: 404).summary, "HTTP 404")
        XCTAssertEqual(ProbeOutcome.redirect(to: "/login").summary, "redirects to /login")
        XCTAssertEqual(ProbeOutcome.noMatchYet.summary, "ready line not seen yet")
    }

    // MARK: - HttpProbe with a fake request

    /// Answers each path with its status and records the requests.
    private final class FakeServer: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []
        let statuses: [String: Int]

        init(_ statuses: [String: Int]) { self.statuses = statuses }

        var paths: [String] { lock.withLock { requests.compactMap { $0.url?.path } } }
        var timeouts: [TimeInterval] { lock.withLock { requests.map(\.timeoutInterval) } }

        func send(_ request: URLRequest) throws -> HTTPURLResponse {
            lock.withLock { requests.append(request) }
            let url = try XCTUnwrap(request.url)
            let path = url.path.isEmpty ? "/" : url.path
            guard let status = statuses[path] else { throw URLError(.cannotConnectToHost) }
            return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
    }

    private func probe(_ server: FakeServer, url: String = "http://127.0.0.1:3002/api/health") -> HttpProbe {
        HttpProbe(url: url, requestTimeout: 5, send: { try server.send($0) })
    }

    func testA404OnTheHealthRouteFallsBackToTheRoot() async {
        let rootAnswers = FakeServer(["/api/health": 404, "/": 200])
        let outcome = await probe(rootAnswers).outcome()
        XCTAssertEqual(outcome, .ok)
        XCTAssertEqual(rootAnswers.paths, ["/api/health", "/"])
        XCTAssertEqual(rootAnswers.timeouts, [5, 5])

        // A root that answers with a redirect runs too.
        let rootRedirects = await probe(FakeServer(["/api/health": 404, "/": 307])).outcome()
        XCTAssertEqual(rootRedirects, .ok)

        // Negative controls: a 404 on the root keeps the 404; a 5xx or no answer
        // on the root is kept with it, so the reason can name it.
        let zombie = await probe(FakeServer(["/api/health": 404, "/": 404])).outcome()
        XCTAssertEqual(zombie, .http(status: 404))
        let broken = await probe(FakeServer(["/api/health": 404, "/": 500])).outcome()
        XCTAssertEqual(broken, .notFoundThenRoot(.http(status: 500)))
        XCTAssertEqual(broken.summary, "HTTP 404, and HTTP 500 at /")
        XCTAssertFalse(broken.isReady)
        let gone = await probe(FakeServer(["/api/health": 404])).outcome()
        XCTAssertEqual(gone, .notFoundThenRoot(.refused))
    }

    func testOnlyA404FallsBack() async {
        let server = FakeServer(["/api/health": 500, "/": 200])
        let outcome = await probe(server).outcome()
        XCTAssertEqual(outcome, .http(status: 500))
        XCTAssertEqual(server.paths, ["/api/health"])

        // A 404 on the root itself has nothing to fall back to.
        let root = FakeServer(["/": 404])
        let rootOutcome = await probe(root, url: "http://127.0.0.1:3002/").outcome()
        XCTAssertEqual(rootOutcome, .http(status: 404))
        XCTAssertEqual(root.paths, ["/"])
    }

    func testAFailedRequestSaysWhy() async {
        let outcome = await probe(FakeServer([:])).outcome()
        XCTAssertEqual(outcome, .refused)
    }

    func testTheFactoryPassesTheRequestTimeout() throws {
        let config = ProbeConfig(
            type: .http, port: 3002, host: nil, url: "http://127.0.0.1:3002/api/health", pattern: nil, artifact: nil, timeout: nil
        )
        let starting = try XCTUnwrap(ProbeFactory.makeProbe(for: config) as? HttpProbe)
        XCTAssertEqual(starting.requestTimeout, 60)
        let liveness = try XCTUnwrap(ProbeFactory.makeProbe(for: config, requestTimeout: 5) as? HttpProbe)
        XCTAssertEqual(liveness.requestTimeout, 5)
    }

    // MARK: - Real probes on loopback

    func testHttpProbeDoesNotFollowARedirect() async throws {
        let server = try await LoopbackHTTPServer.start(response: "HTTP/1.1 302 Found\r\nLocation: /login\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }

        let outcome = await HttpProbe(url: "http://127.0.0.1:\(server.port)/api/health", requestTimeout: 5).outcome()

        XCTAssertEqual(outcome, .redirect(to: "/login"))
        XCTAssertEqual(server.requestLines, ["GET /api/health HTTP/1.1"], "the probe must not ask for /login")
    }

    func testHttpProbeReadsTheStatus() async throws {
        let server = try await LoopbackHTTPServer.start(response: "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        defer { server.stop() }

        let outcome = await HttpProbe(url: "http://127.0.0.1:\(server.port)/", requestTimeout: 5).outcome()

        XCTAssertEqual(outcome, .http(status: 503))
    }

    func testProbesOfAClosedPortSayRefused() async throws {
        let port = try Self.closedPort()
        let tcp = await TcpProbe(port: port).outcome()
        XCTAssertEqual(tcp, .refused)
        // Now and then, after other loopback requests of the run, URLSession reports
        // a refused connect as "The network connection was lost." (a reset). The
        // supervisor checks again; so does the test, up to three times.
        var http = ProbeOutcome.noMatchYet
        for _ in 0..<3 {
            http = await HttpProbe(url: "http://127.0.0.1:\(port)/", requestTimeout: 5).outcome()
            if http == .refused { break }
        }
        XCTAssertEqual(http, .refused)
    }

    /// A loopback port whose listener is closed. `close` frees the port at once, so a
    /// connect is refused. (An NWListener cancels later, and a socket that is only
    /// bound drops the connect on macOS, so the probe times out.)
    private static func closedPort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw POSIXError(.EMFILE) }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(sock, 1) == 0 else { throw POSIXError(.EADDRNOTAVAIL) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &length) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    func testTcpProbeOfAListenerIsOk() async throws {
        let server = try await LoopbackHTTPServer.start(response: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
        defer { server.stop() }
        let outcome = await TcpProbe(port: server.port).outcome()
        XCTAssertEqual(outcome, .ok)
    }

    func testStdoutProbeWaitsForItsLine() async throws {
        let probe = try StdoutProbe(pattern: "Ready on")
        let before = await probe.outcome()
        XCTAssertEqual(before, .noMatchYet)
        _ = probe.feed(line: "compiling…")
        let stillWaiting = await probe.outcome()
        XCTAssertEqual(stillWaiting, .noMatchYet)
        _ = probe.feed(line: "Ready on http://localhost:3000")
        let after = await probe.outcome()
        XCTAssertEqual(after, .ok)
    }
}

/// An HTTP server on an ephemeral loopback port that gives one fixed answer and
/// records the request line of each request.
private final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let response: String
    private let queue = DispatchQueue(label: "loopback-http")
    private let lock = NSLock()
    private var lines: [String] = []
    private(set) var port = 0

    var requestLines: [String] { lock.withLock { lines } }

    private init(response: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.response = response
    }

    static func start(response: String) async throws -> LoopbackHTTPServer {
        let server = try LoopbackHTTPServer(response: response)
        try await server.listen()
        return server
    }

    private func listen() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = Int(self?.listener.port?.rawValue ?? 0)
                    if once.claim() { continuation.resume() }
                case .failed(let error):
                    if once.claim() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self else { return }
            if let data, let text = String(data: data, encoding: .utf8),
               let first = text.components(separatedBy: "\r\n").first {
                self.lock.withLock { self.lines.append(first) }
            }
            connection.send(content: Data(self.response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    func stop() {
        listener.cancel()
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
