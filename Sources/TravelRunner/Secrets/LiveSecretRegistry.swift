import Foundation
import FlyingFox

actor LiveSecretRegistry {
    private var server: HTTPServer?
    private let secretStore: SecretStore
    private let portRange: ClosedRange<UInt16>
    private(set) var activePort: UInt16?

    init(secretStore: SecretStore, portRange: ClosedRange<UInt16> = 19999...20009) {
        self.secretStore = secretStore
        self.portRange = portRange
    }

    func start() async throws {
        for port in portRange {
            do {
                let server = HTTPServer(address: .loopback(port: port))

                let store = self.secretStore
                await server.appendRoute("GET /secret") { _ in
                    if let value = await store.get("STRIPE_WEBHOOK_SECRET"),
                       let updatedAt = await store.getUpdatedAt("STRIPE_WEBHOOK_SECRET") {
                        let json = """
                        {"value":"\(value)","updated_at":"\(updatedAt.ISO8601Format())"}
                        """
                        return HTTPResponse(
                            statusCode: .ok,
                            headers: [.contentType: "application/json"],
                            body: Data(json.utf8)
                        )
                    }
                    return HTTPResponse(
                        statusCode: .serviceUnavailable,
                        body: Data(#"{"error":"no_secret"}"#.utf8)
                    )
                }

                await server.appendRoute("GET /health") { _ in
                    HTTPResponse(
                        statusCode: .ok,
                        body: Data(#"{"status":"ok"}"#.utf8)
                    )
                }

                self.server = server
                self.activePort = port

                Task { try await server.run() }

                try await Task.sleep(for: .milliseconds(100))

                print("[Registry] Listening on http://127.0.0.1:\(port)")
                return
            } catch {
                continue
            }
        }
        throw RegistryError.noAvailablePort
    }

    func stop() async {
        await server?.stop()
        server = nil
        activePort = nil
    }

    enum RegistryError: Error {
        case noAvailablePort
    }
}
