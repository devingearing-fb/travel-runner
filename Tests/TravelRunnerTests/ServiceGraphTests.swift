import XCTest
@testable import TravelRunner

final class ServiceGraphTests: XCTestCase {
    func testTopologicalSort() throws {
        let services = [
            ServiceDefinition(id: "a", name: nil, cmd: ["echo"], cwd: nil, probe: nil, type: .oneshot, restart: nil, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil),
            ServiceDefinition(id: "b", name: nil, cmd: ["echo"], cwd: nil, probe: nil, type: .oneshot, restart: nil, dependsOn: ["a"], env: nil, phase: nil, reuseIfRunning: nil),
            ServiceDefinition(id: "c", name: nil, cmd: ["echo"], cwd: nil, probe: nil, type: .oneshot, restart: nil, dependsOn: ["b"], env: nil, phase: nil, reuseIfRunning: nil),
        ]
        let graph = try ServiceGraph(services: services)
        XCTAssertEqual(graph.sortedIDs, ["a", "b", "c"])
    }

    func testCycleDetection() {
        let services = [
            ServiceDefinition(id: "a", name: nil, cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["c"], env: nil, phase: nil, reuseIfRunning: nil),
            ServiceDefinition(id: "b", name: nil, cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["a"], env: nil, phase: nil, reuseIfRunning: nil),
            ServiceDefinition(id: "c", name: nil, cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["b"], env: nil, phase: nil, reuseIfRunning: nil),
        ]
        XCTAssertThrowsError(try ServiceGraph(services: services))
    }

    func testUnknownDependency() {
        let services = [
            ServiceDefinition(id: "a", name: nil, cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["nonexistent"], env: nil, phase: nil, reuseIfRunning: nil),
        ]
        XCTAssertThrowsError(try ServiceGraph(services: services))
    }

    func testStartOrderLevels() throws {
        let services = [
            ServiceDefinition(id: "db", name: nil, cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: [], env: nil, phase: nil, reuseIfRunning: nil),
            ServiceDefinition(id: "api", name: nil, cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["db"], env: nil, phase: nil, reuseIfRunning: nil),
            ServiceDefinition(id: "web", name: nil, cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["db"], env: nil, phase: nil, reuseIfRunning: nil),
            ServiceDefinition(id: "proxy", name: nil, cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["api", "web"], env: nil, phase: nil, reuseIfRunning: nil),
        ]
        let graph = try ServiceGraph(services: services)
        let levels = graph.startOrder()
        XCTAssertEqual(levels[0], ["db"])
        XCTAssertEqual(Set(levels[1]), Set(["api", "web"]))
        XCTAssertEqual(levels[2], ["proxy"])
    }

    /// S2: the portal started only after Stripe had its webhook secret, and
    /// waited up to 30 s more for it. Stripe now needs only the database, and no
    /// service needs Stripe, so Start All does not wait for it.
    func testThePortalDoesNotWaitForStripe() throws {
        let paths = RepoPaths(
            monorepo: "/work/fb-travel-monolith", universalLogin: "/work/universal-login",
            streamServices: "/work/stream-services", loadTest: "/work/travel-load-test"
        )
        let graph = try ServiceGraph(services: ServiceCatalog.services(paths: paths, flavor: .standard))
        XCTAssertEqual(graph.nodes["stripe"]?.dependsOn, ["supabase"])
        XCTAssertEqual(graph.nodes["travel-portal"]?.dependsOn, ["universal-login"])
        XCTAssertEqual(graph.dependents(of: "stripe"), [])

        let levels = graph.startOrder()
        let stripeLevel = try XCTUnwrap(levels.firstIndex { $0.contains("stripe") })
        XCTAssertEqual(levels[stripeLevel - 1], ["supabase"], "Stripe starts as soon as the database is up")
        XCTAssertTrue(levels[stripeLevel].contains("universal-login"))
    }
}
