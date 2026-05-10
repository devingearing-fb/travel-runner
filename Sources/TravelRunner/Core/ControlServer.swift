import Foundation
import FlyingFox

actor ControlServer {
    private var server: HTTPServer?
    private let port: UInt16 = 19900

    struct Actions: Sendable {
        let getStatus: @Sendable () async -> String
        let getLogs: @Sendable (String, Int) async -> String
        let restartService: @Sendable (String) async -> Void
        let clearCacheRestart: @Sendable (String) async -> Void
        let startAll: @Sendable () async -> Void
        let stopAll: @Sendable () async -> Void
        let toggleLan: @Sendable () async -> Void
        let restartCascade: @Sendable (String) async -> Void
    }

    func start(actions: Actions, logStore: LogStore) async throws {
        let server = HTTPServer(address: .loopback(port: port))

        await server.appendRoute("GET /api/status") { _ in
            let json = await actions.getStatus()
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: Data(json.utf8))
        }

        await server.appendRoute("GET /api/logs/*") { request in
            let path = request.path
            let parts = path.split(separator: "/")
            guard parts.count >= 3 else {
                return HTTPResponse(statusCode: .badRequest, body: Data("Usage: /api/logs/{serviceId}?lines=N".utf8))
            }
            let serviceId = String(parts[2])
            let lines = Int(request.query.first(where: { $0.name == "lines" })?.value ?? "50") ?? 50
            let json = await actions.getLogs(serviceId, lines)
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: Data(json.utf8))
        }

        await server.appendRoute("POST /api/restart/*") { request in
            let parts = request.path.split(separator: "/")
            guard parts.count >= 3 else {
                return HTTPResponse(statusCode: .badRequest, body: Data("Usage: /api/restart/{serviceId}".utf8))
            }
            let serviceId = String(parts[2])
            await actions.restartService(serviceId)
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        await server.appendRoute("POST /api/clear-cache-restart/*") { request in
            let parts = request.path.split(separator: "/")
            guard parts.count >= 3 else {
                return HTTPResponse(statusCode: .badRequest, body: Data("Usage: /api/clear-cache-restart/{serviceId}".utf8))
            }
            let serviceId = String(parts[2])
            await actions.clearCacheRestart(serviceId)
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        await server.appendRoute("POST /api/start-all") { _ in
            await actions.startAll()
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        await server.appendRoute("POST /api/stop-all") { _ in
            await actions.stopAll()
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        await server.appendRoute("POST /api/toggle-lan") { _ in
            await actions.toggleLan()
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        await server.appendRoute("POST /api/restart-cascade/*") { request in
            let parts = request.path.split(separator: "/")
            guard parts.count >= 3 else {
                return HTTPResponse(statusCode: .badRequest, body: Data("Usage: /api/restart-cascade/{serviceId}".utf8))
            }
            let serviceId = String(parts[2])
            await actions.restartCascade(serviceId)
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        self.server = server
        Task { try await server.run() }
        print("[ControlAPI] Listening on http://127.0.0.1:\(port)")
    }

    func stop() async {
        await server?.stop()
        server = nil
    }
}
