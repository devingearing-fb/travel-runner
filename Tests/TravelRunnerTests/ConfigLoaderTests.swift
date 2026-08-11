import Foundation
import XCTest
@testable import TravelRunner

final class ConfigLoaderTests: XCTestCase {
    func testVersionOneConfigUpgradePreservesCustomServicesAndAddsCanonicalCDCChain() throws {
        let versionOne: [String: Any] = [
            "version": 1,
            "registry_port_range": [19999, 20009],
            "paths": [
                "booking_portal": "/workspace/travel-booking-portal",
                "universal_login": "/workspace/universal-login",
            ],
            "services": [
                service(id: "supabase"),
                service(id: "travel-portal"),
                service(id: "cache-apply-transport", cwd: "/workspace/travel-load-test", type: "oneshot", dependsOn: ["travel-portal"]),
                service(id: "cache-cutover-audit", cwd: "/workspace/travel-load-test", type: "oneshot", dependsOn: ["cache-apply-transport"]),
                service(id: "capacity-contention", type: "oneshot", dependsOn: ["cache-cutover-audit"]),
                service(id: "capacity-block-edit-race", type: "oneshot", dependsOn: ["capacity-contention"]),
                service(id: "capacity-overflow", type: "oneshot", dependsOn: ["capacity-block-edit-race"]),
                service(id: "custom-local-tool", dependsOn: ["supabase"]),
            ],
        ]
        let original = try JSONSerialization.data(withJSONObject: versionOne)
        let upgraded = try ConfigLoader.upgradedData(
            original,
            streamServicesPath: "/workspace/stream-services"
        )
        let config = try JSONDecoder().decode(ServiceConfig.self, from: upgraded)
        let byID = Dictionary(uniqueKeysWithValues: config.services.map { ($0.id, $0) })

        XCTAssertEqual(config.version, 2)
        XCTAssertEqual(config.paths?.streamServices, "/workspace/stream-services")
        XCTAssertNotNil(byID["custom-local-tool"])
        XCTAssertEqual(byID["custom-local-tool"]?.dependsOn, ["supabase"])

        let streamIDs = [
            "stream-services-install",
            "stream-qstash",
            "stream-db-setup",
            "stream-services",
            "stream-qstash-wire",
            "stream-sequin",
        ]
        for id in streamIDs {
            XCTAssertEqual(config.services.filter { $0.id == id }.count, 1, id)
            XCTAssertEqual(byID[id]?.resolvedCwd, "/workspace/stream-services")
        }
        XCTAssertEqual(config.services.filter { $0.id == "cache-cdc-rehearsal" }.count, 1)
        XCTAssertEqual(byID["cache-cdc-rehearsal"]?.resolvedCwd, "/workspace/travel-load-test")
        XCTAssertEqual(
            byID["cache-cdc-rehearsal"]?.env?["TRAVEL_RUNNER_CONTROL_URL"],
            "http://[::1]:19900"
        )
        XCTAssertEqual(
            Set(try XCTUnwrap(byID["cache-cutover-audit"]).dependsOn),
            Set(["cache-apply-transport", "cache-cdc-rehearsal"])
        )
        XCTAssertEqual(byID["capacity-contention"]?.dependsOn, ["cache-apply-transport"])
        XCTAssertEqual(
            byID["stream-db-setup"]?.dependsOn,
            ["supabase", "capacity-overflow"]
        )
        XCTAssertNoThrow(try ServiceGraph(services: config.services))
    }

    func testConfigUpgradeIsStableAndReplacesStaleCanonicalNodes() throws {
        let root: [String: Any] = [
            "version": 1,
            "registry_port_range": [19999, 20009],
            "services": [
                service(id: "supabase"),
                service(id: "travel-portal"),
                service(id: "stream-qstash", cmd: ["stale"]),
            ],
        ]
        let input = try JSONSerialization.data(withJSONObject: root)
        let once = try ConfigLoader.upgradedData(input, streamServicesPath: "/workspace/stream-services")
        let twice = try ConfigLoader.upgradedData(once, streamServicesPath: "/workspace/stream-services")
        let config = try JSONDecoder().decode(ServiceConfig.self, from: twice)
        let qstash = try XCTUnwrap(config.services.first { $0.id == "stream-qstash" })

        XCTAssertEqual(once, twice)
        XCTAssertEqual(config.services.filter { $0.id == "stream-qstash" }.count, 1)
        XCTAssertEqual(qstash.cmd, ["npx", "--no-install", "qstash", "dev"])
    }

    private func service(
        id: String,
        cmd: [String] = ["true"],
        cwd: String = "/workspace",
        type: String? = nil,
        dependsOn: [String] = []
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "cmd": cmd,
            "cwd": cwd,
            "depends_on": dependsOn,
        ]
        if let type { value["type"] = type }
        return value
    }
}
