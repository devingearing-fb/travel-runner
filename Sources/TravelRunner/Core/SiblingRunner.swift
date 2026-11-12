import Foundation

/// The other runner app on this Mac (`Flavor.sibling`).
///
/// The two apps use the same ports for Supabase, the login and the portals, and
/// each one stops what it finds on those ports. Thus an app does not start a
/// stack, write the login's env, or clear the ports while the other app runs one.
enum SiblingRunner {
    /// Phases of a service that has, or will soon have, a process.
    static let activePhases: Set<String> = ["STARTING", "RUNNING", "STOPPING"]

    /// The services of the `/api/status` answer that run now, sorted.
    /// A service with no process (Supabase that the app only found on its port) counts
    /// too: the app that shows it as running uses it.
    static func activeServices(statusJSON data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let services = root["services"] as? [String: Any] else { return [] }
        return services.compactMap { id, value in
            guard let phase = (value as? [String: Any])?["phase"] as? String,
                  activePhases.contains(phase.uppercased()) else { return nil }
            return id
        }.sorted()
    }

    static func statusURL(of flavor: Flavor) -> URL {
        URL(string: "\(flavor.controlURL)/api/status")!
    }

    private static func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    /// The services that the other app runs now. Empty when that app is not open.
    static func activeServices(of flavor: Flavor = Flavor.current.sibling, timeout: TimeInterval = 1.5) async -> [String] {
        await activeServices(at: statusURL(of: flavor), timeout: timeout)
    }

    static func activeServices(at url: URL, timeout: TimeInterval) async -> [String] {
        guard let (data, _) = try? await URLSession.shared.data(for: request(url, timeout: timeout)) else { return [] }
        return activeServices(statusJSON: data)
    }

    /// The same for code that cannot wait in a task (app launch and app quit).
    static func activeServicesNow(of flavor: Flavor = Flavor.current.sibling, timeout: TimeInterval = 1.0) -> [String] {
        activeServicesNow(at: statusURL(of: flavor), timeout: timeout)
    }

    static func activeServicesNow(at url: URL, timeout: TimeInterval) -> [String] {
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = URLSession.shared.dataTask(with: request(url, timeout: timeout)) { data, _, _ in
            if let data { box.set(activeServices(statusJSON: data)) }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 0.5) == .timedOut { task.cancel() }
        return box.value
    }

    /// What the person reads when this app refuses to start.
    static func refusal(activeServices: [String], sibling: Flavor = Flavor.current.sibling) -> String {
        "\(sibling.displayName) runs a stack now (\(activeServices.joined(separator: ", "))). "
            + "The two apps use the same ports. Stop the stack there, then start again."
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []

        func set(_ value: [String]) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        var value: [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }
}
