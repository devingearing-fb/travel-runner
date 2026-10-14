import Foundation
import XCTest
@testable import TravelRunner

final class ConfigLoaderTests: XCTestCase {
    private let monorepo = "/work/TRAVEL BOOKING/fb-travel-monolith"

    func testVersionTwoConfigUpgradesToMonorepoAndKeepsCustomServices() throws {
        let versionTwo: [String: Any] = [
            "version": 2,
            "registry_port_range": [19999, 20009],
            "paths": [
                "booking_portal": "/work/TRAVEL BOOKING/travel-booking-portal",
                "travel_data": "/work/TRAVEL BOOKING/fb-travel-data",
                "partner_portal": "/work/TRAVEL BOOKING/fb-amateur-travel-partner-portal",
                "universal_login": "/work/fb-amateur-universal-login",
                "stream_services": "/work/stream-services",
            ],
            "services": [
                service(id: "supabase"),
                service(id: "yalc-link"),
                service(id: "travel-portal", dependsOn: ["stripe"]),
                service(id: "cache-apply-transport", cwd: "/work/TRAVEL BOOKING/travel-load-test"),
                service(id: "custom-local-tool", dependsOn: ["supabase"]),
            ],
        ]
        var searchedFrom: String?
        let upgraded = try ConfigLoader.upgradedData(
            JSONSerialization.data(withJSONObject: versionTwo),
            findMonorepo: { path in
                searchedFrom = path
                return self.monorepo
            }
        )
        let config = try JSONDecoder().decode(ServiceConfig.self, from: upgraded)
        let byID = Dictionary(uniqueKeysWithValues: config.services.map { ($0.id, $0) })

        XCTAssertEqual(searchedFrom, "/work/TRAVEL BOOKING/travel-booking-portal")
        XCTAssertEqual(config.version, 3)
        XCTAssertEqual(config.paths, RepoPaths(
            monorepo: monorepo,
            universalLogin: "/work/fb-amateur-universal-login",
            streamServices: "/work/stream-services",
            loadTest: "/work/TRAVEL BOOKING/travel-load-test"
        ))
        XCTAssertEqual(config.resolvedProfile, .both)
        XCTAssertNil(byID["yalc-link"])
        XCTAssertEqual(byID["custom-local-tool"]?.dependsOn, ["supabase"])
        XCTAssertEqual(byID["travel-portal"]?.resolvedCwd, monorepo + "/apps/booking-portal")
        XCTAssertEqual(Set(ServiceCatalog.canonicalIDs).subtracting(byID.keys), [])
        XCTAssertNoThrow(try ServiceGraph(services: config.services))
    }

    func testOldConfigWithoutMonorepoNeedsSetup() throws {
        let versionTwo: [String: Any] = [
            "version": 2,
            "paths": ["booking_portal": "/work/travel-booking-portal"],
            "services": [service(id: "supabase")],
        ]
        XCTAssertThrowsError(
            try ConfigLoader.upgradedData(JSONSerialization.data(withJSONObject: versionTwo), findMonorepo: { _ in nil })
        ) { error in
            guard case ConfigLoader.ConfigError.monorepoNotFound = error else {
                return XCTFail("unexpected error \(error)")
            }
        }
    }

    func testUpgradeIsStableAndRebuildsCanonicalServices() throws {
        let root: [String: Any] = [
            "version": 3,
            "paths": ["monorepo": monorepo, "universal_login": "/work/login"],
            "profile": "partner",
            "services": [service(id: "stream-qstash", cmd: ["stale"])],
        ]
        let once = try ConfigLoader.upgradedData(JSONSerialization.data(withJSONObject: root), findMonorepo: { _ in nil })
        let twice = try ConfigLoader.upgradedData(once, findMonorepo: { _ in nil })
        let config = try JSONDecoder().decode(ServiceConfig.self, from: twice)

        XCTAssertEqual(once, twice)
        XCTAssertEqual(config.resolvedProfile, .partner)
        XCTAssertEqual(config.services.filter { $0.id == "stream-qstash" }.count, 1)
        XCTAssertEqual(config.services.first { $0.id == "stream-qstash" }?.cmd, ["./node_modules/.bin/qstash", "dev"])
    }

    func testUnknownProfileFallsBackToBoth() throws {
        let root: [String: Any] = ["paths": ["monorepo": monorepo], "profile": "everything", "services": []]
        let config = try JSONDecoder().decode(
            ServiceConfig.self,
            from: ConfigLoader.upgradedData(JSONSerialization.data(withJSONObject: root), findMonorepo: { _ in nil })
        )
        XCTAssertEqual(config.resolvedProfile, .both)
    }

    private func service(
        id: String,
        cmd: [String] = ["true"],
        cwd: String = "/work",
        dependsOn: [String] = []
    ) -> [String: Any] {
        ["id": id, "cmd": cmd, "cwd": cwd, "depends_on": dependsOn]
    }
}
