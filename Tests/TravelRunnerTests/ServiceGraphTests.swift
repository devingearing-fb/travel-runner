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
}
