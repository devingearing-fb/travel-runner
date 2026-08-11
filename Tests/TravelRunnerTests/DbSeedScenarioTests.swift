import Foundation
import XCTest
@testable import TravelRunner

final class DbSeedScenarioTests: XCTestCase {
    func testFolderDiscoveryOrdersAndMergesEffectiveSettings() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try writeFolderManifest(fixture)
        try writeScenario(descriptor(
            id: "sold-out", order: 30, baseID: "standard",
            settings: [
                "variables": ["game_night_name": "Sold Out Night", "remaining_rooms": 0],
                "dynamicVariables": [
                    "previous_date": relativeDate(days: -1),
                    "same_date": relativeDate(days: 0),
                ],
            ]
        ), fixture)
        try writeScenario(descriptor(id: "schema-only", order: 20), fixture)
        try writeScenario(descriptor(
            id: "standard", order: 10, isDefault: true,
            settings: [
                "variables": ["game_night_name": "Game Night", "is_featured": true],
                "dynamicVariables": ["game_night_start_date": relativeDate(days: 14)],
            ]
        ), fixture)

        let catalog = try DbManifestLoader.loadSeedScenarios(from: fixture.manifest.path)

        XCTAssertEqual(catalog.defaultID, "standard")
        XCTAssertEqual(catalog.items.map(\.id), ["standard", "schema-only", "sold-out"])
        XCTAssertEqual(catalog.items.map(\.fileSummary), ["seed.sql", "seed.sql", "seed.sql + 1 overlay"])
        XCTAssertEqual(catalog.items[0].variables, [
            .init(name: "game_night_name", value: "\"Game Night\""),
            .init(name: "game_night_start_date", value: "today + 14 days (America/New_York)"),
            .init(name: "is_featured", value: "true"),
        ])
        XCTAssertEqual(catalog.items[1].variables, [])
        XCTAssertEqual(catalog.items[2].variables, [
            .init(name: "game_night_name", value: "\"Sold Out Night\""),
            .init(name: "game_night_start_date", value: "today + 14 days (America/New_York)"),
            .init(name: "is_featured", value: "true"),
            .init(name: "previous_date", value: "today - 1 day (America/New_York)"),
            .init(name: "remaining_rooms", value: "0"),
            .init(name: "same_date", value: "today (America/New_York)"),
        ])
    }

    func testLegacyManifestWithoutSeedScenariosSynthesizesStandard() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try writeSQL("-- seed", fixture.root.appendingPathComponent("supabase/seed.sql"))
        try writeJSON(["version": 1, "steps": []], fixture.manifest)
        let catalog = try DbManifestLoader.loadSeedScenarios(from: fixture.manifest.path)
        XCTAssertEqual(catalog.defaultID, "standard")
        XCTAssertEqual(catalog.items, [standardScenario])
    }

    func testEmbeddedV2CatalogIsRejectedInsteadOfTreatedAsLegacy() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try writeJSON([
            "version": 2,
            "seedScenarios": ["default": "standard", "items": []],
        ], fixture.manifest)
        assertLoadFails(fixture, containing: "version 3")
    }

    func testMalformedDescriptorFieldsAreRejected() throws {
        let cases: [(String, ([String: Any]) -> [String: Any], String)] = [
            ("wrong-version", { changing($0, "version", 2) }, "version must be 1"),
            ("wrong-id", { changing($0, "id", "different") }, "match its folder name"),
            ("empty-name", { changing($0, "name", "  ") }, "non-empty string"),
            ("empty-description", { changing($0, "description", "\n") }, "non-empty string"),
            ("negative-order", { changing($0, "order", -1) }, "nonnegative integer"),
            ("fractional-order", { changing($0, "order", 1.5) }, "nonnegative integer"),
            ("nonbool-default", { changing($0, "default", 1) }, "must be a boolean"),
            ("missing-extends", { removing($0, "extends") }, "contain exactly"),
            ("stale-sql-paths", { changing($0, "sqlPaths", ["old.sql"]) }, "contain exactly"),
        ]
        for (folder, mutation, message) in cases {
            let fixture = try makeRepository()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            try writeFolderManifest(fixture)
            try writeScenario(
                mutation(descriptor(id: folder, order: 10, isDefault: true)),
                fixture,
                folder: folder
            )
            assertLoadFails(fixture, containing: message)
        }
    }

    func testScenarioFolderNameMustBeLowercaseKebabCase() throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try writeFolderManifest(fixture)
        try writeScenario(
            descriptor(id: "standard", order: 10, isDefault: true),
            fixture,
            folder: "Standard Scenario"
        )
        assertLoadFails(fixture, containing: "folder name must be lowercase kebab-case")
    }

    func testDescriptorRequiresScenarioJSONAndFixedSeedSQL() throws {
        for missing in ["scenario.json", "seed.sql"] {
            let fixture = try makeRepository()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            try writeFolderManifest(fixture)
            let folder = scenarioDirectory(fixture, "standard")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if missing == "scenario.json" {
                try writeSQL("-- seed", folder.appendingPathComponent("seed.sql"))
            } else {
                try writeJSON(
                    descriptor(id: "standard", order: 10, isDefault: true),
                    folder.appendingPathComponent("scenario.json")
                )
            }
            assertLoadFails(fixture, containing: missing)
        }
    }

    func testMalformedSettingsAndVariablesAreRejected() throws {
        let cases: [(String, Any, String)] = [
            ("settings-array", [], "settings must be an object"),
            ("variables-array", ["variables": []], "variables must be an object"),
            ("invalid-name", ["variables": ["Bad-Name": "value"]], "variable name"),
            ("static-null", ["variables": ["value": NSNull()]], "finite number"),
            ("dynamic-array", ["dynamicVariables": []], "dynamicVariables must be an object"),
            ("wrong-type", ["dynamicVariables": ["date": [
                "type": "absolute-date", "days": 1, "timeZone": "America/New_York",
            ]]], "relative-date"),
            ("fractional-days", ["dynamicVariables": ["date": relativeDate(days: 1.5)]], "integer days"),
            ("bad-zone", ["dynamicVariables": ["date": relativeDate(days: 1, zone: "Mars/Olympus")]], "valid IANA"),
            ("extra-dynamic-key", ["dynamicVariables": ["date": [
                "type": "relative-date", "days": 1,
                "timeZone": "America/New_York", "format": "iso",
            ]]], "relative-date"),
            ("collision", [
                "variables": ["date": "fixed"],
                "dynamicVariables": ["date": relativeDate(days: 1)],
            ], "appears in both"),
        ]
        for (id, settings, message) in cases {
            let fixture = try makeRepository()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            try writeFolderManifest(fixture)
            try writeScenario(
                descriptor(id: id, order: 10, isDefault: true, settings: settings),
                fixture
            )
            assertLoadFails(fixture, containing: message)
        }
    }

    func testScenarioDirectoryMustBeNormalizedAndSafe() throws {
        for path in [
            "../scenarios", "./supabase/seeds/scenarios", "supabase//seeds/scenarios",
            #"supabase\seeds\scenarios"#, "/tmp/scenarios", "supabase/seeds/*",
        ] {
            let fixture = try makeRepository()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            try writeFolderManifest(fixture, directory: path)
            XCTAssertThrowsError(try DbManifestLoader.loadSeedScenarios(from: fixture.manifest.path))
        }
    }

    func testScenarioDirectoryAndFoldersMustNotBeSymlinks() throws {
        let directoryFixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directoryFixture.container) }
        let outside = directoryFixture.container.appendingPathComponent("outside")
        try writeScenario(
            descriptor(id: "standard", order: 10, isDefault: true),
            in: outside,
            folder: "standard"
        )
        let scenarios = scenariosDirectory(directoryFixture)
        try FileManager.default.createDirectory(
            at: scenarios.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: scenarios, withDestinationURL: outside)
        try writeFolderManifest(directoryFixture)
        assertLoadFails(directoryFixture, containing: "symbolic links")

        let folderFixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: folderFixture.container) }
        try writeFolderManifest(folderFixture)
        let targetParent = folderFixture.root.appendingPathComponent("fixtures")
        try writeScenario(
            descriptor(id: "standard", order: 10, isDefault: true),
            in: targetParent,
            folder: "standard"
        )
        let link = scenarioDirectory(folderFixture, "standard")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: targetParent.appendingPathComponent("standard")
        )
        assertLoadFails(folderFixture, containing: "folders must not be symbolic links")
    }

    func testScenarioDescriptorAndSeedMustNotBeSymlinks() throws {
        for fileName in ["scenario.json", "seed.sql"] {
            let fixture = try makeRepository()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            try writeFolderManifest(fixture)
            let folder = scenarioDirectory(fixture, "standard")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = fixture.root.appendingPathComponent("fixtures/\(fileName)")
            if fileName == "scenario.json" {
                try writeJSON(descriptor(id: "standard", order: 10, isDefault: true), target)
                try writeSQL("-- seed", folder.appendingPathComponent("seed.sql"))
            } else {
                try writeSQL("-- seed", target)
                try writeJSON(
                    descriptor(id: "standard", order: 10, isDefault: true),
                    folder.appendingPathComponent("scenario.json")
                )
            }
            try FileManager.default.createSymbolicLink(
                at: folder.appendingPathComponent(fileName),
                withDestinationURL: target
            )
            assertLoadFails(fixture, containing: "must not be a symbolic link")
        }
    }

    func testCatalogRequiresUniqueOrdersAndExactlyOneDefault() throws {
        for defaults in [[false, false], [true, true]] {
            let fixture = try makeRepository()
            defer { try? FileManager.default.removeItem(at: fixture.container) }
            try writeFolderManifest(fixture)
            try writeScenario(descriptor(id: "first", order: 10, isDefault: defaults[0]), fixture)
            try writeScenario(descriptor(id: "second", order: 20, isDefault: defaults[1]), fixture)
            assertLoadFails(fixture, containing: "exactly one default")
        }
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try writeFolderManifest(fixture)
        try writeScenario(descriptor(id: "first", order: 10, isDefault: true), fixture)
        try writeScenario(descriptor(id: "second", order: 10), fixture)
        assertLoadFails(fixture, containing: "order 10 is duplicated")
    }

    func testInheritanceRejectsUnknownBasesAndCycles() throws {
        let unknown = try makeRepository()
        defer { try? FileManager.default.removeItem(at: unknown.container) }
        try writeFolderManifest(unknown)
        try writeScenario(
            descriptor(id: "standard", order: 10, isDefault: true, baseID: "missing"),
            unknown
        )
        assertLoadFails(unknown, containing: "extends unknown scenario ‘missing’")

        let cycle = try makeRepository()
        defer { try? FileManager.default.removeItem(at: cycle.container) }
        try writeFolderManifest(cycle)
        try writeScenario(descriptor(id: "first", order: 10, isDefault: true, baseID: "second"), cycle)
        try writeScenario(descriptor(id: "second", order: 20, baseID: "first"), cycle)
        assertLoadFails(cycle, containing: "inheritance contains a cycle")
    }

    func testSelectionResolutionUsesDefaultRestoresValidAndRejectsStale() throws {
        let catalog = DbSeedScenarioCatalog(
            defaultID: "standard",
            items: [standardScenario, soldOutScenario]
        )
        XCTAssertEqual(try DbSeedScenarioSelection.resolve(catalog: catalog, savedID: nil), "standard")
        XCTAssertEqual(try DbSeedScenarioSelection.resolve(catalog: catalog, savedID: "sold-out"), "sold-out")
        XCTAssertThrowsError(try DbSeedScenarioSelection.resolve(catalog: catalog, savedID: "deleted")) {
            XCTAssertTrue($0.localizedDescription.contains("Choose a seed scenario"))
        }
    }

    @MainActor
    func testValidSelectionPersistsAndRunningSelectionIsGuarded() throws {
        let suiteName = "DbSeedScenarioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        supervisor.dbSeedScenarios = [standardScenario, soldOutScenario]
        supervisor.selectDbSeedScenario("sold-out")
        XCTAssertEqual(defaults.string(forKey: "dbSeedScenarioID"), "sold-out")
        XCTAssertEqual(EnvironmentSupervisor(userDefaults: defaults).selectedDbSeedScenarioID, "sold-out")
        supervisor.dbResetRunning = true
        supervisor.selectDbSeedScenario("standard")
        XCTAssertEqual(supervisor.selectedDbSeedScenarioID, "sold-out")
        XCTAssertEqual(defaults.string(forKey: "dbSeedScenarioID"), "sold-out")
    }

    @MainActor
    func testPipelineSnapshotsProfileAndScenarioAndStatusReportsBoth() throws {
        let suiteName = "DbSeedScenarioTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let pipeline = DbSetupPipeline(profile: "full", seedScenario: standardScenario)
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        supervisor.dbSetupPipeline = pipeline
        supervisor.dbSeedScenarios = [soldOutScenario]
        supervisor.selectedDbSeedScenarioID = "sold-out"
        XCTAssertEqual(pipeline.profile, "full")
        XCTAssertEqual(pipeline.seedScenario.id, "standard")
        let data = try XCTUnwrap(supervisor.dbSetupStatusJSON().data(using: .utf8))
        let status = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(status["profile"] as? String, "full")
        XCTAssertEqual((status["selectedSeedScenario"] as? [String: Any])?["id"] as? String, "sold-out")
        let active = try XCTUnwrap(status["activeSeedScenario"] as? [String: Any])
        XCTAssertEqual(active["id"] as? String, "standard")
        XCTAssertEqual(active["fileSummary"] as? String, "seed.sql")
        supervisor.dbSetupPipeline = nil
        let idleData = try XCTUnwrap(supervisor.dbSetupStatusJSON().data(using: .utf8))
        let idle = try XCTUnwrap(JSONSerialization.jsonObject(with: idleData) as? [String: Any])
        XCTAssertTrue(idle["profile"] is NSNull)
        XCTAssertTrue(idle["activeSeedScenario"] is NSNull)
        XCTAssertEqual((idle["selectedSeedScenario"] as? [String: Any])?["id"] as? String, "sold-out")
    }

    func testSeedEnvironmentOverridesParentAndPreservesOtherValues() {
        let environment = DbSetupRunner.environment(
            parent: ["PATH": "/test/bin", "TRAVEL_SEED_SCENARIO": "old"],
            seedScenarioID: "sold-out"
        )
        XCTAssertEqual(environment["PATH"], "/test/bin")
        XCTAssertEqual(environment["TRAVEL_SEED_SCENARIO"], "sold-out")
    }

    @MainActor
    func testRunnerProvidesScenarioToCommandAndHealthCheck() async throws {
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("DbSetupRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cwd) }
        let step = DbSetupStep(
            id: "environment", name: "Environment",
            command: "test \"$TRAVEL_SEED_SCENARIO\" = sold-out",
            healthCheckCommand: "test \"$TRAVEL_SEED_SCENARIO\" = sold-out",
            timeoutSeconds: 5, isOptional: false, stepNumber: 1
        )
        let runner = DbSetupRunner(
            portalCwd: cwd.path, logStore: LogStore(), seedScenarioID: "sold-out"
        )
        let success = await runner.executeStepPublic(step)
        XCTAssertTrue(success)
        XCTAssertEqual(step.status, .passed)
    }

    private struct Fixture {
        let container: URL
        let root: URL
        let manifest: URL
    }

    private var standardScenario: DbSeedScenario {
        .init(
            id: "standard", name: "Standard",
            description: "Standard development fixtures.",
            fileSummary: "seed.sql", variables: []
        )
    }

    private var soldOutScenario: DbSeedScenario {
        .init(
            id: "sold-out", name: "Sold out",
            description: "All contracted inventory is exhausted.",
            fileSummary: "seed.sql + 1 overlay", variables: []
        )
    }

    private func makeRepository() throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("DbSeedScenarioTests-\(UUID().uuidString)")
        let root = container.appendingPathComponent("repository")
        let manifest = root.appendingPathComponent("scripts/db/manifest.json")
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return .init(container: container, root: root, manifest: manifest)
    }

    private func writeFolderManifest(
        _ fixture: Fixture,
        directory: String = "supabase/seeds/scenarios"
    ) throws {
        try writeJSON([
            "version": 3,
            "seedScenarios": ["directory": directory],
        ], fixture.manifest)
    }

    private func descriptor(
        id: String,
        order: Int,
        isDefault: Bool = false,
        baseID: String? = nil,
        settings: Any = [String: Any]()
    ) -> [String: Any] {
        [
            "version": 1, "id": id,
            "name": id.replacingOccurrences(of: "-", with: " ").capitalized,
            "description": "Fixture for \(id).", "order": order,
            "default": isDefault, "extends": baseID ?? NSNull(), "settings": settings,
        ]
    }

    private func relativeDate(days: Any, zone: String = "America/New_York") -> [String: Any] {
        ["type": "relative-date", "days": days, "timeZone": zone]
    }

    private func writeScenario(
        _ descriptor: [String: Any],
        _ fixture: Fixture,
        folder: String? = nil
    ) throws {
        try writeScenario(descriptor, in: scenariosDirectory(fixture), folder: folder)
    }

    private func writeScenario(
        _ descriptor: [String: Any],
        in directory: URL,
        folder: String? = nil
    ) throws {
        let id = try XCTUnwrap(folder ?? descriptor["id"] as? String)
        let scenario = directory.appendingPathComponent(id)
        try writeJSON(descriptor, scenario.appendingPathComponent("scenario.json"))
        try writeSQL("-- \(id)", scenario.appendingPathComponent("seed.sql"))
    }

    private func scenariosDirectory(_ fixture: Fixture) -> URL {
        fixture.root.appendingPathComponent("supabase/seeds/scenarios")
    }

    private func scenarioDirectory(_ fixture: Fixture, _ id: String) -> URL {
        scenariosDirectory(fixture).appendingPathComponent(id)
    }

    private func writeJSON(_ object: [String: Any], _ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: url)
    }

    private func writeSQL(_ contents: String, _ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func assertLoadFails(
        _ fixture: Fixture,
        containing message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try DbManifestLoader.loadSeedScenarios(from: fixture.manifest.path),
            file: file,
            line: line
        ) {
            XCTAssertTrue(
                $0.localizedDescription.contains(message),
                $0.localizedDescription,
                file: file,
                line: line
            )
        }
    }
}

private func changing(_ object: [String: Any], _ key: String, _ value: Any) -> [String: Any] {
    var copy = object
    copy[key] = value
    return copy
}

private func removing(_ object: [String: Any], _ key: String) -> [String: Any] {
    var copy = object
    copy.removeValue(forKey: key)
    return copy
}
