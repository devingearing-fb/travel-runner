import XCTest
@testable import TravelRunner

final class ServiceGraphTests: XCTestCase {
    func testTopologicalSort() throws {
        let services = [
            ServiceDefinition(id: "a", cmd: ["echo"], cwd: nil, probe: nil, type: .oneshot, restart: nil, dependsOn: [], env: nil),
            ServiceDefinition(id: "b", cmd: ["echo"], cwd: nil, probe: nil, type: .oneshot, restart: nil, dependsOn: ["a"], env: nil),
            ServiceDefinition(id: "c", cmd: ["echo"], cwd: nil, probe: nil, type: .oneshot, restart: nil, dependsOn: ["b"], env: nil),
        ]
        let graph = try ServiceGraph(services: services)
        XCTAssertEqual(graph.sortedIDs, ["a", "b", "c"])
    }

    func testCycleDetection() {
        let services = [
            ServiceDefinition(id: "a", cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["c"], env: nil),
            ServiceDefinition(id: "b", cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["a"], env: nil),
            ServiceDefinition(id: "c", cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["b"], env: nil),
        ]
        XCTAssertThrowsError(try ServiceGraph(services: services))
    }

    func testUnknownDependency() {
        let services = [
            ServiceDefinition(id: "a", cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["nonexistent"], env: nil),
        ]
        XCTAssertThrowsError(try ServiceGraph(services: services))
    }

    func testStartOrderLevels() throws {
        let services = [
            ServiceDefinition(id: "db", cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: [], env: nil),
            ServiceDefinition(id: "api", cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["db"], env: nil),
            ServiceDefinition(id: "web", cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["db"], env: nil),
            ServiceDefinition(id: "proxy", cmd: ["echo"], cwd: nil, probe: nil, type: nil, restart: nil, dependsOn: ["api", "web"], env: nil),
        ]
        let graph = try ServiceGraph(services: services)
        let levels = graph.startOrder()
        XCTAssertEqual(levels[0], ["db"])
        XCTAssertEqual(Set(levels[1]), Set(["api", "web"]))
        XCTAssertEqual(levels[2], ["proxy"])
    }
}
