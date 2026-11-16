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

    // MARK: - A custom service that cannot run

    private func load(customServices: [[String: Any]]) throws -> (config: ServiceConfig, data: Data) {
        let root: [String: Any] = ["version": 3, "paths": ["monorepo": monorepo], "services": customServices]
        let data = try ConfigLoader.upgradedData(JSONSerialization.data(withJSONObject: root), findMonorepo: { _ in nil })
        return (try JSONDecoder().decode(ServiceConfig.self, from: data), data)
    }

    func testATcpProbeWithNoPortSkipsTheServiceAndKeepsTheRest() throws {
        var foo = service(id: "foo")
        foo["probe"] = ["type": "tcp"]
        var good = service(id: "good")
        good["probe"] = ["type": "tcp", "port": 4100]

        let (config, _) = try load(customServices: [foo, good])

        XCTAssertEqual(
            config.skippedServices.map(\.message),
            ["services.json: custom service \"foo\" was skipped — probe type tcp needs a port (1–65535)."]
        )
        XCTAssertNil(config.services.first { $0.id == "foo" })
        XCTAssertEqual(config.services.first { $0.id == "good" }?.probe?.port, 4100)
        XCTAssertEqual(Set(ServiceCatalog.canonicalIDs).subtracting(config.services.map(\.id)), [])
        XCTAssertNoThrow(try ServiceGraph(services: config.services))
    }

    func testEachKindOfBadCustomServiceHasItsOwnReason() throws {
        let cases: [(probe: [String: Any]?, drop: String?, reason: String)] = [
            (["type": "tcp", "port": 0], nil, "probe type tcp needs a port (1–65535)"),
            (["type": "tcp", "port": 70000], nil, "probe type tcp needs a port (1–65535)"),
            (["type": "tcp", "port": "3000"], nil, "its \"probe.port\" has the wrong kind of value"),
            (["type": "http"], nil, "probe type http needs a url or a port (1–65535)"),
            (["type": "http", "url": "localhost:3000"], nil, "probe type http needs an http or https url"),
            (["type": "http", "port": -1], nil, "probe port -1 is not a port (1–65535)"),
            (["type": "stdout_regex"], nil, "probe type stdout_regex needs a pattern"),
            (["type": "stdout_regex", "pattern": "ready ("], nil,
             "probe type stdout_regex needs a pattern that is a valid regular expression"),
            (["type": "ping"], nil, "its probe type is not known (use tcp, http or stdout_regex)"),
            (nil, "cmd", "it has no \"cmd\""),
            (nil, "depends_on", "it has no \"depends_on\""),
        ]
        for testCase in cases {
            var foo = service(id: "foo")
            if let probe = testCase.probe { foo["probe"] = probe }
            if let drop = testCase.drop { foo[drop] = nil }
            let (config, _) = try load(customServices: [foo])
            XCTAssertEqual(
                config.skippedServices, [SkippedService(id: "foo", reason: testCase.reason)], "\(testCase)"
            )
            XCTAssertNil(config.services.first { $0.id == "foo" }, "\(testCase)")
        }
    }

    /// The graph rejects a service whose dependency is not there. A dependent of a
    /// skipped service is skipped too, so the rest of the file still loads.
    func testADependentOfASkippedServiceIsSkippedAndTheRestLoad() throws {
        var foo = service(id: "foo")
        foo["probe"] = ["type": "tcp"]
        let bar = service(id: "bar", dependsOn: ["foo"])
        let baz = service(id: "baz", dependsOn: ["bar", "good"])
        let good = service(id: "good")

        let (config, _) = try load(customServices: [baz, bar, foo, good])

        XCTAssertEqual(
            config.skippedServices.map(\.message),
            [
                "services.json: custom service \"foo\" was skipped — probe type tcp needs a port (1–65535).",
                "services.json: custom service \"bar\" was skipped — depends on \"foo\", which was skipped.",
                "services.json: custom service \"baz\" was skipped — depends on \"bar\", which was skipped.",
            ]
        )
        XCTAssertEqual(Set(config.services.map(\.id)).intersection(["foo", "bar", "baz", "good"]), ["good"])
        XCTAssertEqual(Set(ServiceCatalog.canonicalIDs).subtracting(config.services.map(\.id)), [])
        XCTAssertNoThrow(try ServiceGraph(services: config.services))
    }

    /// Negative control: a dependency that is present skips nothing.
    func testADependentOfAGoodServiceIsNotSkipped() throws {
        let (config, _) = try load(customServices: [service(id: "bar", dependsOn: ["good"]), service(id: "good")])
        XCTAssertEqual(config.skippedServices, [])
        XCTAssertNotNil(config.services.first { $0.id == "bar" })
    }

    func testAWrongElementOfAListIsNamedByItsPlace() throws {
        var foo = service(id: "foo")
        foo["cmd"] = ["a", 5]
        let (config, _) = try load(customServices: [foo])
        XCTAssertEqual(
            config.skippedServices, [SkippedService(id: "foo", reason: "its \"cmd[1]\" has the wrong kind of value")]
        )
    }

    func testGoodProbesAreNotSkipped() throws {
        let probes: [[String: Any]] = [
            ["type": "tcp", "port": 1], ["type": "tcp", "port": 65535, "host": "0.0.0.0"],
            ["type": "http", "port": 3000], ["type": "http", "url": "https://localhost:3000/health"],
            ["type": "stdout_regex", "pattern": "ready in \\d+ms", "port": 3000],
        ]
        for probe in probes {
            var foo = service(id: "foo")
            foo["probe"] = probe
            let (config, _) = try load(customServices: [foo])
            XCTAssertEqual(config.skippedServices, [], "\(probe)")
            XCTAssertNotNil(config.services.first { $0.id == "foo" }, "\(probe)")
        }
    }

    /// The upgrade writes the file again. The owner's bad service must still be there
    /// to correct, with every field as it was written.
    func testASkippedServiceStaysInTheFileAsWritten() throws {
        var foo = service(id: "foo")
        foo["probe"] = ["type": "tcp", "note": "port goes here"]
        let (_, once) = try load(customServices: [foo, service(id: "good")])

        let twice = try ConfigLoader.upgradedData(once, findMonorepo: { _ in nil })
        XCTAssertEqual(once, twice)

        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: twice) as? [String: Any])
        let services = try XCTUnwrap(root["services"] as? [[String: Any]])
        let kept = try XCTUnwrap(services.first { $0["id"] as? String == "foo" })
        XCTAssertEqual(kept as NSDictionary, foo as NSDictionary)
        XCTAssertEqual(services.filter { $0["id"] as? String == "foo" }.count, 1)
    }

    func testAConfigWithNoBadServiceIsWrittenAsBefore() throws {
        let (config, data) = try load(customServices: [service(id: "good")])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(config.skippedServices, [])
        XCTAssertEqual(data, try encoder.encode(config))
    }

    func testAServiceWithNoIdIsNamedAsSuch() {
        XCTAssertEqual(
            SkippedService(id: nil, reason: "it has no \"id\"").message,
            "services.json: a custom service with no id was skipped — it has no \"id\"."
        )
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
