import Foundation
import XCTest
@testable import TravelRunner

final class Phase5TopologyTests: XCTestCase {
    func testBundledPhase5TransportRunsAfterAuthenticatedApplyEndpoint() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configURL = packageRoot
            .appendingPathComponent("Sources/TravelRunner/Resources/default-services.json")
        let config = try JSONDecoder().decode(ServiceConfig.self, from: Data(contentsOf: configURL))
        let byID = Dictionary(uniqueKeysWithValues: config.services.map { ($0.id, $0) })
        let portal = try XCTUnwrap(byID["travel-portal"])
        let transport = try XCTUnwrap(byID["cache-apply-transport"])
        let packageInstall = try XCTUnwrap(byID["yalc-link"])

        XCTAssertEqual(
            packageInstall.cmd,
            ["bash", "./scripts/yalc-link-consumers.sh"]
        )
        XCTAssertTrue(packageInstall.resolvedCwd?.hasSuffix("fb-travel-data") == true)

        XCTAssertEqual(portal.env?["CACHE_APPLY_MODE"], "full")
        XCTAssertEqual(portal.env?["CACHE_APPLY_SECRET_CURRENT"], transport.env?["CACHE_APPLY_SECRET"])
        XCTAssertGreaterThanOrEqual(Int(portal.env?["CACHE_APPLY_RATE_LIMIT_PER_MINUTE"] ?? "") ?? 0, 162)
        XCTAssertEqual(transport.resolvedType, .oneshot)
        XCTAssertEqual(transport.resolvedRestart, .never)
        XCTAssertEqual(transport.dependsOn, ["travel-portal"])
        XCTAssertEqual(transport.cmd, ["npm", "run", "test:cache-transport:runner"])
        XCTAssertTrue(transport.resolvedCwd?.hasSuffix("travel-load-test") == true)

        let graph = try ServiceGraph(services: config.services)
        let levels = graph.startOrder()
        let portalLevel = try XCTUnwrap(levels.firstIndex(where: { $0.contains("travel-portal") }))
        let transportLevel = try XCTUnwrap(levels.firstIndex(where: { $0.contains("cache-apply-transport") }))
        XCTAssertGreaterThan(transportLevel, portalLevel)
    }

    func testBundledPhase6AuditRunsAfterTransport() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configURL = packageRoot
            .appendingPathComponent("Sources/TravelRunner/Resources/default-services.json")
        let config = try JSONDecoder().decode(ServiceConfig.self, from: Data(contentsOf: configURL))
        let byID = Dictionary(uniqueKeysWithValues: config.services.map { ($0.id, $0) })
        let transport = try XCTUnwrap(byID["cache-apply-transport"])
        let audit = try XCTUnwrap(byID["cache-cutover-audit"])

        XCTAssertEqual(audit.cmd, ["npm", "run", "audit:p6"])
        XCTAssertEqual(Set(audit.dependsOn), Set(["cache-apply-transport", "cache-cdc-rehearsal"]))
        XCTAssertEqual(audit.resolvedType, .oneshot)
        XCTAssertEqual(audit.resolvedRestart, .never)
        XCTAssertTrue(audit.resolvedCwd?.hasSuffix("travel-load-test") == true)

        let levels = try ServiceGraph(services: config.services).startOrder()
        let transportLevel = try XCTUnwrap(levels.firstIndex(where: { $0.contains(transport.id) }))
        let auditLevel = try XCTUnwrap(levels.firstIndex(where: { $0.contains(audit.id) }))
        XCTAssertGreaterThan(auditLevel, transportLevel)
    }

    func testBundledRunnerOwnsFullCacheCDCChain() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configURL = packageRoot
            .appendingPathComponent("Sources/TravelRunner/Resources/default-services.json")
        let config = try JSONDecoder().decode(ServiceConfig.self, from: Data(contentsOf: configURL))
        let byID = Dictionary(uniqueKeysWithValues: config.services.map { ($0.id, $0) })
        let expected = Set([
            "stream-services-install",
            "stream-qstash",
            "stream-db-setup",
            "stream-services",
            "stream-qstash-wire",
            "stream-sequin",
            "cache-cdc-rehearsal",
            "capacity-contention",
            "capacity-block-edit-race",
            "capacity-overflow",
        ])
        XCTAssertTrue(expected.isSubset(of: Set(byID.keys)))
        XCTAssertTrue(config.paths?.streamServices?.hasSuffix("stream-services") == true)

        let portal = try XCTUnwrap(byID["travel-portal"])
        let qstash = try XCTUnwrap(byID["stream-qstash"])
        let stream = try XCTUnwrap(byID["stream-services"])
        let wire = try XCTUnwrap(byID["stream-qstash-wire"])
        let sequin = try XCTUnwrap(byID["stream-sequin"])
        let rehearsal = try XCTUnwrap(byID["cache-cdc-rehearsal"])
        let dbSetup = try XCTUnwrap(byID["stream-db-setup"])
        let contention = try XCTUnwrap(byID["capacity-contention"])
        let blockEditRace = try XCTUnwrap(byID["capacity-block-edit-race"])
        let overflow = try XCTUnwrap(byID["capacity-overflow"])
        let audit = try XCTUnwrap(byID["cache-cutover-audit"])

        XCTAssertEqual(qstash.cmd, ["./node_modules/.bin/qstash", "dev"])
        XCTAssertEqual(qstash.probe?.port, 8080)
        XCTAssertEqual(stream.probe?.port, 3003)
        XCTAssertEqual(sequin.probe?.port, 7376)
        XCTAssertEqual(stream.env?["CACHE_APPLY_SECRET_CURRENT"], portal.env?["CACHE_APPLY_SECRET_CURRENT"])
        XCTAssertEqual(stream.env?["TRAVEL_CACHE_APPLY_URL"], "http://127.0.0.1:3002/api/cache/apply")
        XCTAssertEqual(wire.resolvedType, .oneshot)
        XCTAssertEqual(rehearsal.cmd, ["npm", "run", "test:cache-cdc:runner"])
        XCTAssertEqual(dbSetup.dependsOn, ["supabase", "capacity-overflow"])
        // Local CDC infrastructure is portal-owned; only production logic runs in stream-services.
        XCTAssertEqual(dbSetup.cmd, ["./scripts/local-cdc/runner-db-setup.sh"])
        XCTAssertTrue(dbSetup.env?["STREAM_SERVICES_DIR"]?.hasSuffix("stream-services") == true)
        XCTAssertEqual(sequin.cmd, ["./scripts/local-cdc/run-sequin.sh"])
        XCTAssertEqual(wire.cmd, ["./scripts/local-cdc/qstash-wire.sh"])
        for infra in [qstash, dbSetup, wire, sequin] {
            XCTAssertTrue(infra.resolvedCwd?.hasSuffix("travel-booking-portal") == true, infra.id)
        }
        XCTAssertTrue(stream.resolvedCwd?.hasSuffix("stream-services") == true)
        XCTAssertEqual(contention.dependsOn, ["cache-apply-transport"])
        XCTAssertEqual(blockEditRace.dependsOn, ["capacity-contention"])
        XCTAssertEqual(overflow.dependsOn, ["capacity-block-edit-race"])
        XCTAssertEqual(rehearsal.resolvedType, .oneshot)
        XCTAssertEqual(rehearsal.env?["TRAVEL_RUNNER_CONTROL_URL"], "http://[::1]:19900")
        XCTAssertFalse(qstash.shouldReuseIfRunning)
        XCTAssertFalse(stream.shouldReuseIfRunning)
        XCTAssertFalse(sequin.shouldReuseIfRunning)
        XCTAssertEqual(Set(audit.dependsOn), Set(["cache-apply-transport", "cache-cdc-rehearsal"]))

        let graph = try ServiceGraph(services: config.services)
        let levels = graph.startOrder()
        func level(_ id: String) throws -> Int {
            try XCTUnwrap(levels.firstIndex(where: { $0.contains(id) }))
        }
        XCTAssertLessThan(try level("supabase"), try level("stream-db-setup"))
        XCTAssertLessThan(try level("cache-apply-transport"), try level("capacity-contention"))
        XCTAssertLessThan(try level("capacity-contention"), try level("capacity-block-edit-race"))
        XCTAssertLessThan(try level("capacity-block-edit-race"), try level("capacity-overflow"))
        XCTAssertLessThan(try level("capacity-overflow"), try level("stream-db-setup"))
        XCTAssertLessThan(try level("stream-qstash"), try level("stream-services"))
        XCTAssertLessThan(try level("stream-services"), try level("stream-qstash-wire"))
        XCTAssertLessThan(try level("stream-qstash-wire"), try level("stream-sequin"))
        XCTAssertLessThan(try level("stream-sequin"), try level("cache-cdc-rehearsal"))
        XCTAssertLessThan(try level("cache-cdc-rehearsal"), try level("cache-cutover-audit"))

        let qstashCascade = graph.dependents(of: "stream-qstash")
        XCTAssertTrue(Set([
            "stream-services",
            "stream-qstash-wire",
            "stream-sequin",
            "cache-cdc-rehearsal",
            "cache-cutover-audit",
        ]).isSubset(of: qstashCascade))
    }

}
