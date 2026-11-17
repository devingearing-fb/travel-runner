import Foundation

/// Answers the requests of a session without the network. Each session has its
/// own handler, so tests that run at the same time do not share answers.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// The answer of a request: a status code, or an error for no answer.
    typealias Handler = @Sendable (URLRequest) -> Result<Int, URLError>

    private static let header = "X-Stub-Session"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]

    /// A session whose requests go to `handler`, and a way to read them afterwards.
    static func session(_ handler: @escaping Handler) -> (session: URLSession, requests: @Sendable () -> [URLRequest]) {
        let id = UUID().uuidString
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [header: id]
        return (URLSession(configuration: configuration), {
            lock.lock()
            defer { lock.unlock() }
            return requests[id] ?? []
        })
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.header) ?? ""
        Self.lock.lock()
        let handler = Self.handlers[id]
        Self.requests[id, default: []].append(request)
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch handler(request) {
        case .success(let status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
