import Foundation

/// What one probe check found. A failed check says why, so the row and the
/// triage card can name the cause instead of "not ready".
enum ProbeOutcome: Equatable, Sendable {
    case ok
    /// Nothing listens on the port.
    case refused
    /// The connection or the request took longer than its limit.
    case timedOut
    /// The server answered with a status that is not a ready answer.
    case http(status: Int)
    /// The server answered with a redirect. The probe does not follow it.
    case redirect(to: String)
    /// The host name did not resolve.
    case dnsError
    /// A stdout probe has not seen its line yet.
    case noMatchYet
    case other(String)

    /// True when the service counts as ready. A redirect is an answer of a server
    /// that runs and routes, so it counts.
    var isReady: Bool {
        switch self {
        case .ok, .redirect: true
        default: false
        }
    }

    /// Short text for the row, the triage card and `/api/status`.
    var summary: String {
        switch self {
        case .ok: "ready"
        case .refused: "connection refused"
        case .timedOut: "no answer in time"
        case .http(let status): "HTTP \(status)"
        case .redirect(let to): "redirects to \(to)"
        case .dnsError: "host name not found"
        case .noMatchYet: "ready line not seen yet"
        case .other(let text): text
        }
    }

    /// The outcome of a failed URL request.
    static func from(urlError error: Error) -> ProbeOutcome {
        guard let urlError = error as? URLError else { return .other(error.localizedDescription) }
        switch urlError.code {
        case .cannotConnectToHost: return .refused
        case .timedOut: return .timedOut
        case .cannotFindHost, .dnsLookupFailed: return .dnsError
        default: return .other(urlError.localizedDescription)
        }
    }

    /// The outcome of an HTTP status. 2xx is ready, 3xx is a redirect, the rest is not ready.
    static func from(status: Int, location: String?) -> ProbeOutcome {
        switch status {
        case 200..<300: .ok
        case 300..<400: .redirect(to: location ?? "an unknown place")
        default: .http(status: status)
        }
    }
}
