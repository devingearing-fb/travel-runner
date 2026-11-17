import Foundation
import XCTest
@testable import TravelRunner

/// The wizard's state: completed or not, and the paths typed so far.
final class SetupStateTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var folder: URL!
    private var configPath: String!

    override func setUpWithError() throws {
        suiteName = "SetupStateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("setup-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        configPath = folder.appendingPathComponent("services.json").path
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }

    private var state: SetupState { SetupState(defaults: defaults, configPath: configPath) }

    func testANewUserHasNotCompletedSetup() {
        XCTAssertFalse(state.completed)
        // The answer is kept: a config written later without the wizard does not complete it.
        FileManager.default.createFile(atPath: configPath, contents: Data("{}".utf8))
        XCTAssertFalse(state.completed)
    }

    func testAnExistingUserIsMigratedToCompleted() {
        FileManager.default.createFile(atPath: configPath, contents: Data("{}".utf8))
        XCTAssertTrue(state.completed)
        // The migration is stored, so it holds also when the file goes away.
        try? FileManager.default.removeItem(atPath: configPath)
        XCTAssertTrue(state.completed)
    }

    func testTheDraftComesBackUntilTheWizardCompletes() {
        let paths = RepoPaths(monorepo: "/work/fb-travel-monolith", universalLogin: "/work/login")
        state.draftPaths = paths
        XCTAssertEqual(state.draftPaths, paths)
        XCTAssertFalse(state.completed)

        state.markCompleted()

        XCTAssertTrue(state.completed)
        XCTAssertNil(state.draftPaths)
    }

    func testEachConfigFolderHasItsOwnState() {
        let other = SetupState(defaults: defaults, configPath: "/elsewhere/services.json")
        state.draftPaths = RepoPaths(monorepo: "/work/fb-travel-monolith")
        other.markCompleted()

        XCTAssertFalse(state.completed)
        XCTAssertNotNil(state.draftPaths)
        XCTAssertTrue(other.completed)
        XCTAssertNil(other.draftPaths)
    }

    func testTheWizardOpensWhenThereIsNoConfigOrSetupNeverCompleted() {
        XCTAssertTrue(SetupState.opensWizard(needsSetup: true, completed: true))
        XCTAssertTrue(SetupState.opensWizard(needsSetup: false, completed: false))
        XCTAssertFalse(SetupState.opensWizard(needsSetup: false, completed: true))
    }
}
