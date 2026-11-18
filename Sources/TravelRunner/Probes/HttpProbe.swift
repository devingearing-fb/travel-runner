import Foundation

struct HttpProbe: Probe {
    let url: String
    /// The limit of one request: 60 s while a service starts, 5 s for a liveness check.
    var requestTimeout: TimeInterval = 60
    /// A page check, not a health route: a 4xx other than 404 (a 401 of a login
    /// page) is a server that serves pages, so it counts as ready.
    var acceptsClientErrors = false
    /// Sends one request and does not follow a redirect. Tests give a fake.
    var send: @Sendable (URLRequest) async throws -> HTTPURLResponse = HttpProbe.sendWithoutRedirects

    func outcome() async -> ProbeOutcome {
        guard let target = URL(string: url) else { return .other("not a URL: \(url)") }
        let response: HTTPURLResponse
        do {
            response = try await send(request(target))
        } catch {
            return .from(urlError: error)
        }
        if acceptsClientErrors, (400..<500).contains(response.statusCode), response.statusCode != 404 { return .ok }
        let first = ProbeOutcome.from(status: response.statusCode, location: response.value(forHTTPHeaderField: "Location"))
        // A 404 on a health route: the branch may not have that route. Then any
        // answer below 500 on / counts. A 404 there too is the zombie server that
        // answers 404 for every route, so it does not count. A 5xx or no answer
        // on / is kept, so the reason can name it.
        guard response.statusCode == 404, !["", "/"].contains(target.path),
              let root = URL(string: "/", relativeTo: target)?.absoluteURL else { return first }
        let rootResponse: HTTPURLResponse
        do {
            rootResponse = try await send(request(root))
        } catch {
            return .notFoundThenRoot(.from(urlError: error))
        }
        let status = rootResponse.statusCode
        if status == 404 { return first }
        return status < 500 ? .ok : .notFoundThenRoot(.http(status: status))
    }

    private func request(_ target: URL) -> URLRequest {
        var request = URLRequest(url: target)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    static let sendWithoutRedirects: @Sendable (URLRequest) async throws -> HTTPURLResponse = { request in
        let (_, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects())
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http
    }
}

/// Refuses each redirect, so the answer is the redirect itself.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
