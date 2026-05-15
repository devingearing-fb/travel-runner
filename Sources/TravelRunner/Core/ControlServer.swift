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
        let dbReset: @Sendable () async -> Void
        let dbSetupRun: @Sendable (String) async -> Void
        let dbSetupRetry: @Sendable (String) async -> Void
        let dbSetupCancel: @Sendable () async -> Void
        let dbSetupStatus: @Sendable () async -> String
        let dbSetupRunStep: @Sendable (String) async -> Void
        let debugListIssues: @Sendable () async -> String
        let debugCapture: @Sendable (String) async -> String
        let debugCloseIssue: @Sendable (String, String?) async -> String
        let yalcRelink: @Sendable () async -> Void
        let yalcToggleAuto: @Sendable () async -> Void
        let yalcStatus: @Sendable () async -> String
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

        await server.appendRoute("POST /api/db-reset") { _ in
            await actions.dbReset()
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        await server.appendRoute("POST /api/db-setup") { request in
            let body = try? await request.bodyData
            let profile: String
            if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let p = json["profile"] as? String {
                profile = p
            } else {
                profile = "reset"
            }
            await actions.dbSetupRun(profile)
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        await server.appendRoute("POST /api/db-setup/retry/*") { request in
            let parts = request.path.split(separator: "/")
            guard parts.count >= 4 else {
                return HTTPResponse(statusCode: .badRequest, body: Data("Usage: /api/db-setup/retry/{stepId}".utf8))
            }
            let stepId = String(parts[3])
            await actions.dbSetupRetry(stepId)
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        await server.appendRoute("POST /api/db-setup/cancel") { _ in
            await actions.dbSetupCancel()
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        await server.appendRoute("GET /api/db-setup/status") { _ in
            let json = await actions.dbSetupStatus()
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: Data(json.utf8))
        }

        await server.appendRoute("POST /api/db-setup/step/*") { request in
            let parts = request.path.split(separator: "/")
            guard parts.count >= 4 else {
                return HTTPResponse(statusCode: .badRequest, body: Data("Usage: /api/db-setup/step/{stepId}".utf8))
            }
            let stepId = String(parts[3])
            await actions.dbSetupRunStep(stepId)
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        await server.appendRoute("GET /api/debug/issues") { _ in
            let json = await actions.debugListIssues()
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: Data(json.utf8))
        }

        await server.appendRoute("POST /api/debug/issues") { request in
            let body = try? await request.bodyData
            let desc: String
            if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let d = json["description"] as? String { desc = d }
            else { desc = "Manual capture via API" }
            let result = await actions.debugCapture(desc)
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: Data(result.utf8))
        }

        await server.appendRoute("POST /api/debug/issues/close/*") { request in
            let parts = request.path.split(separator: "/")
            guard parts.count >= 5 else {
                return HTTPResponse(statusCode: .badRequest, body: Data("Usage: /api/debug/issues/close/{id}".utf8))
            }
            let id = String(parts[4...].joined(separator: "/"))
            let body = try? await request.bodyData
            let resolution: String?
            if let body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                resolution = json["resolution"] as? String
            } else { resolution = nil }
            let result = await actions.debugCloseIssue(id, resolution)
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: Data(result.utf8))
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

        await server.appendRoute("GET /api/yalc/status") { _ in
            let json = await actions.yalcStatus()
            return HTTPResponse(statusCode: .ok, headers: [.contentType: "application/json"], body: Data(json.utf8))
        }

        await server.appendRoute("POST /api/yalc/relink") { _ in
            await actions.yalcRelink()
            return HTTPResponse(statusCode: .ok, body: Data("{\"ok\":true}".utf8))
        }

        await server.appendRoute("POST /api/yalc/toggle-auto") { _ in
            await actions.yalcToggleAuto()
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
