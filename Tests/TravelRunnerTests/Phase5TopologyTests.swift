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
            ["npm", "install", "--prefer-offline", "--no-audit", "--no-fund"]
        )

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
}
