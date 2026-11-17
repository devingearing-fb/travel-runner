import Foundation
import XCTest
@testable import TravelRunner

/// The seams of a launch that nobody watches (`scripts/smoke.sh`), and the fixture
/// that the smoke test launches against.
final class LaunchEnvironmentTests: XCTestCase {
    func testTheConfigFolderComesFromTheEnvironment() {
        XCTAssertEqual(
            LaunchEnvironment.configDir(flavor: .standard, environment: ["TRAVEL_RUNNER_CONFIG_DIR": "/tmp/smoke/config/"]),
            "/tmp/smoke/config"
        )
        // Controls: without the value, and with a path that is not absolute, the folder of the flavor.
        let standard = NSString(string: "~/.config/travel-runner").expandingTildeInPath
        XCTAssertEqual(LaunchEnvironment.configDir(flavor: .standard, environment: [:]), standard)
        XCTAssertEqual(
            LaunchEnvironment.configDir(flavor: .standard, environment: ["TRAVEL_RUNNER_CONFIG_DIR": "relative"]), standard
        )
        XCTAssertEqual(
            LaunchEnvironment.configDir(flavor: .hackathon, environment: [:]),
            NSString(string: "~/.config/travel-runner-hackathon").expandingTildeInPath
        )
    }

    func testTheControlPortComesFromTheEnvironment() {
        XCTAssertEqual(
            LaunchEnvironment.controlPort(flavor: .standard, environment: ["TRAVEL_RUNNER_CONTROL_PORT": "45123"]), 45123
        )
        XCTAssertEqual(
            LaunchEnvironment.controlURL(flavor: .standard, environment: ["TRAVEL_RUNNER_CONTROL_PORT": "45123"]),
            "http://[::1]:45123"
        )
        // Controls: no value, and values that are not a port, give the port of the flavor.
        XCTAssertEqual(LaunchEnvironment.controlPort(flavor: .standard, environment: [:]), 19900)
        XCTAssertEqual(LaunchEnvironment.controlPort(flavor: .hackathon, environment: [:]), 19901)
        for bad in ["0", "-1", "65536", "abc", ""] {
            XCTAssertEqual(
                LaunchEnvironment.controlPort(flavor: .standard, environment: ["TRAVEL_RUNNER_CONTROL_PORT": bad]),
                19900, bad
            )
        }
        XCTAssertEqual(LaunchEnvironment.controlURL(flavor: .standard, environment: [:]), Flavor.standard.controlURL)
    }

    func testOnlyTheValueOneIsASmokeLaunch() {
        XCTAssertTrue(LaunchEnvironment.isSmoke(environment: ["TRAVEL_RUNNER_SMOKE": "1"]))
        XCTAssertFalse(LaunchEnvironment.isSmoke(environment: [:]))
        XCTAssertFalse(LaunchEnvironment.isSmoke(environment: ["TRAVEL_RUNNER_SMOKE": "true"]))
    }

    /// `scripts/smoke.sh` writes a services.json with only `paths.monorepo` and expects
    /// a config. The fixture must stay a folder that the app takes for the monorepo.
    func testTheSmokeFixtureIsAMonorepoAndGivesAConfig() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mini-monorepo").path
        XCTAssertTrue(RepoDetector.isMonorepo(fixture, flavor: .standard))
        // Control: the folder above it is no monorepo.
        XCTAssertFalse(RepoDetector.isMonorepo((fixture as NSString).deletingLastPathComponent, flavor: .standard))

        let file = try JSONSerialization.data(withJSONObject: ["paths": ["monorepo": fixture], "services": []])
        let config = try JSONDecoder().decode(ServiceConfig.self, from: ConfigLoader.upgradedData(file))
        XCTAssertEqual(config.paths?.monorepo, fixture)
        XCTAssertTrue(config.services.contains { $0.id == "travel-portal" })
        XCTAssertEqual(Compatibility.requirement(manifestPath: Compatibility.manifestPath(root: fixture)), .none)
    }
}
