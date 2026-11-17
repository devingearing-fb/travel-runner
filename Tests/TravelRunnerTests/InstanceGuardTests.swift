import AppKit
import XCTest
@testable import TravelRunner

/// One copy of the app at a time, and the banner for a release copy outside /Applications.
final class InstanceGuardTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let home = "/Users/sam"

    override func setUp() {
        suiteName = "InstanceGuardTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func copy(
        _ pid: pid_t,
        launched seconds: TimeInterval? = nil,
        path: String? = "/Applications/TravelRunner.app",
        version: String? = "0.13.5"
    ) -> InstanceGuard.Copy {
        InstanceGuard.Copy(
            pid: pid,
            launchDate: seconds.map { Date(timeIntervalSince1970: $0) },
            path: path,
            version: version
        )
    }

    private func build(_ kind: String, flavor: Flavor = .standard) -> BuildInfo {
        BuildInfo.resolve(
            info: ["CFBundleShortVersionString": "0.13.5", BuildInfo.kindKey: kind],
            flavor: flavor
        )
    }

    // MARK: - The running copy

    func testTheOnlyCopyRuns() {
        let own = copy(500, launched: 100)

        XCTAssertNil(InstanceGuard.runningCopy(own: own, all: [own]))
        XCTAssertNil(InstanceGuard.runningCopy(own: own, all: []))
    }

    func testTheSecondCopyYieldsToTheFirst() {
        let first = copy(400, launched: 100)
        let own = copy(500, launched: 200, path: "/Users/sam/Downloads/TravelRunner.app")

        XCTAssertEqual(InstanceGuard.runningCopy(own: own, all: [first, own]), first)
    }

    /// Negative control: the copy that ran first must not quit for a later one.
    func testTheFirstCopyDoesNotYieldToALaterOne() {
        let own = copy(400, launched: 100)
        let later = copy(500, launched: 200)

        XCTAssertNil(InstanceGuard.runningCopy(own: own, all: [own, later]))
    }

    /// The launch date decides, not the pid: pids start again from a low number.
    func testTheLaunchDateDecidesBeforeThePid() {
        let first = copy(9000, launched: 100)
        let own = copy(300, launched: 200)

        XCTAssertEqual(InstanceGuard.runningCopy(own: own, all: [own, first]), first)
        XCTAssertNil(InstanceGuard.runningCopy(own: first, all: [own, first]))
    }

    func testTwoCopiesThatStartTogetherDoNotBothQuit() {
        let a = copy(400, launched: 100)
        let b = copy(500, launched: 100)

        XCTAssertNil(InstanceGuard.runningCopy(own: a, all: [a, b]))
        XCTAssertEqual(InstanceGuard.runningCopy(own: b, all: [a, b]), a)
    }

    /// Only when no start time is known. `processStart` knows it for a copy run from a shell.
    func testWithoutALaunchDateThePidDecides() {
        let a = copy(400)
        let b = copy(500, launched: 100)

        XCTAssertNil(InstanceGuard.runningCopy(own: a, all: [a, b]))
        XCTAssertEqual(InstanceGuard.runningCopy(own: b, all: [a, b]), a)
    }

    /// The kernel knows the start of every process, also of one that no app launcher started.
    func testTheKernelKnowsWhenAProcessStarted() throws {
        let start = try XCTUnwrap(InstanceGuard.processStart(of: getpid()))

        XCTAssertLessThanOrEqual(start, Date())
        XCTAssertGreaterThan(start, Date().addingTimeInterval(-24 * 60 * 60))
        XCTAssertEqual(InstanceGuard.processStart(of: getpid()), start)
    }

    /// Negative control: no process, no start time.
    func testAPidWithoutAProcessHasNoStartTime() {
        XCTAssertNil(InstanceGuard.processStart(of: -1))
    }

    func testTheThirdCopyNamesTheOneThatRanFirst() {
        let first = copy(400, launched: 100)
        let second = copy(500, launched: 200)
        let own = copy(600, launched: 300)

        XCTAssertEqual(InstanceGuard.runningCopy(own: own, all: [second, own, first]), first)
    }

    // MARK: - Show the running copy

    /// The request goes to one process, not to a bundle path.
    func testTheReopenRequestIsForOneProcess() {
        let event = InstanceGuard.reopenEvent(pid: 4321)

        XCTAssertEqual(event.eventClass, AEEventClass(kCoreEventClass))
        XCTAssertEqual(event.eventID, AEEventID(kAEReopenApplication))
        let target = event.attributeDescriptor(forKeyword: keyAddressAttr)
        XCTAssertEqual(target?.descriptorType, typeKernelProcessID)
        XCTAssertEqual(target?.data.withUnsafeBytes { $0.loadUnaligned(as: pid_t.self) }, 4321)
    }

    // MARK: - A launch that nobody watches

    func testASmokeLaunchSkipsTheAlert() {
        XCTAssertTrue(InstanceGuard.skipsAlert(environment: ["TRAVEL_RUNNER_SMOKE": "1"]))
        XCTAssertFalse(InstanceGuard.skipsAlert(environment: [:]))
        XCTAssertFalse(InstanceGuard.skipsAlert(environment: ["TRAVEL_RUNNER_SMOKE": "0"]))
        XCTAssertNotEqual(InstanceGuard.smokeExitCode, 0)
    }

    // MARK: - A copy on its way out

    /// Quit stops the stack before the process ends. A launch in that time found
    /// the old process and said "already running".
    func testTheMarkerNamesTheCopyThatQuits() {
        let quitting = copy(700, launched: 1_000)
        let marker = InstanceGuard.quittingMarker(pid: 700, start: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(marker, "700 1000.0")
        XCTAssertTrue(InstanceGuard.isQuitting(quitting, marker: marker))
        // A start time that one side does not know: the pid decides.
        XCTAssertTrue(InstanceGuard.isQuitting(copy(700), marker: marker))
        XCTAssertTrue(InstanceGuard.isQuitting(quitting, marker: InstanceGuard.quittingMarker(pid: 700, start: nil)))

        // Controls: no marker, another pid, a later process with the same pid, and text that is no marker.
        XCTAssertFalse(InstanceGuard.isQuitting(quitting, marker: nil))
        XCTAssertFalse(InstanceGuard.isQuitting(copy(701, launched: 1_000), marker: marker))
        XCTAssertFalse(InstanceGuard.isQuitting(copy(700, launched: 5_000), marker: marker))
        for bad in ["", "700", "x 1000", "700 1000 extra"] {
            XCTAssertFalse(InstanceGuard.isQuitting(quitting, marker: bad), bad)
        }
    }

    func testTheMarkerIsWrittenReadAndCleared() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("InstanceGuard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("quitting").path
        XCTAssertNil(InstanceGuard.readQuittingMarker(path: path))

        InstanceGuard.markQuitting(pid: getpid(), path: path)

        let own = InstanceGuard.Copy(
            pid: getpid(), launchDate: InstanceGuard.processStart(of: getpid()), path: nil, version: nil
        )
        XCTAssertTrue(InstanceGuard.isQuitting(own, marker: InstanceGuard.readQuittingMarker(path: path)))
        InstanceGuard.clearQuittingMarker(path: path)
        XCTAssertNil(InstanceGuard.readQuittingMarker(path: path))
    }

    func testTheLaunchWaitsUntilTheCopyIsGoneButNotForEver() {
        // The process ends after three looks.
        var looks = 0
        var slept: [TimeInterval] = []
        let gone = InstanceGuard.waitForExit(
            pid: 700, timeout: 5, isAlive: { _ in looks += 1; return looks <= 3 }, sleep: { slept.append($0) }
        )
        XCTAssertTrue(gone)
        XCTAssertEqual(slept.count, 3)

        // A copy that does not end: the wait stops at the limit, and the alert comes as before.
        var waited: TimeInterval = 0
        let stuck = InstanceGuard.waitForExit(pid: 700, timeout: 1, isAlive: { _ in true }, sleep: { waited += $0 })
        XCTAssertFalse(stuck)
        XCTAssertEqual(waited, 1, accuracy: 0.11)

        // A process that is already gone needs no wait.
        XCTAssertTrue(InstanceGuard.waitForExit(pid: 700, isAlive: { _ in false }, sleep: { _ in XCTFail("no wait") }))
    }

    // MARK: - The message

    func testTheMessageNamesThePathAndTheVersion() {
        XCTAssertEqual(
            InstanceGuard.message(for: copy(400), flavor: .standard, home: home),
            "Travel Runner is already running from /Applications/TravelRunner.app (v0.13.5). "
                + "Two copies fight over the same ports and config."
        )
        XCTAssertEqual(InstanceGuard.showButton, "Show the running copy")
        XCTAssertEqual(InstanceGuard.quitButton, "Quit")
    }

    func testTheMessageShowsTheHomeFolderShort() {
        let stray = copy(400, path: "/Users/sam/Downloads/TravelRunner.app", version: "0.13.2")

        XCTAssertEqual(
            InstanceGuard.title(for: stray, flavor: .standard, home: home),
            "Travel Runner is already running from ~/Downloads/TravelRunner.app (v0.13.2)."
        )
    }

    func testTheMessageLeavesOutWhatIsNotKnown() {
        XCTAssertEqual(
            InstanceGuard.title(for: copy(400, path: nil, version: nil), flavor: .hackathon, home: home),
            "Travel Runner Hackathon is already running."
        )
        XCTAssertEqual(
            InstanceGuard.title(for: copy(400, version: nil), flavor: .standard, home: home),
            "Travel Runner is already running from /Applications/TravelRunner.app."
        )
    }

    func testOnlyAPathInTheHomeFolderIsShortened() {
        XCTAssertEqual(InstanceGuard.displayPath("/Users/sam/Apps/X.app", home: home), "~/Apps/X.app")
        XCTAssertEqual(InstanceGuard.displayPath("/Users/samuel/X.app", home: home), "/Users/samuel/X.app")
        XCTAssertEqual(InstanceGuard.displayPath("/Applications/X.app", home: home), "/Applications/X.app")
    }

    // MARK: - A release copy outside /Applications

    func testApplicationsFolders() {
        XCTAssertTrue(InstanceGuard.isInApplications("/Applications/TravelRunner.app", home: home))
        XCTAssertTrue(InstanceGuard.isInApplications("/Applications/Work/TravelRunner.app", home: home))
        XCTAssertTrue(InstanceGuard.isInApplications("/Users/sam/Applications/TravelRunner.app", home: home))
        XCTAssertFalse(InstanceGuard.isInApplications("/Users/sam/Downloads/TravelRunner.app", home: home))
        XCTAssertFalse(InstanceGuard.isInApplications("/ApplicationsOld/TravelRunner.app", home: home))
        XCTAssertFalse(InstanceGuard.isInApplications("/Users/kim/Applications/TravelRunner.app", home: home))
    }

    func testAReleaseCopyInApplicationsHasNoBanner() {
        XCTAssertNil(InstanceGuard.misplacedNotice(
            bundlePath: "/Applications/TravelRunner.app", build: build("release"), home: home, defaults: defaults
        ))
    }

    func testAReleaseCopyInDownloadsHasTheBanner() throws {
        let notice = try XCTUnwrap(InstanceGuard.misplacedNotice(
            bundlePath: "/Users/sam/Downloads/TravelRunner.app", build: build("release"), home: home, defaults: defaults
        ))

        XCTAssertEqual(
            notice.text,
            "This copy of Travel Runner runs from ~/Downloads/TravelRunner.app, not from /Applications. "
                + "Copies in other folders get old and start by mistake."
        )
        XCTAssertEqual(notice.advice, "Quit Travel Runner, move it to Applications in Finder, then open it there.")
        XCTAssertEqual(notice.revealPath, "/Users/sam/Downloads/TravelRunner.app")
    }

    /// A dev build runs from its build folder. That is its place.
    func testADevBuildHasNoBanner() {
        XCTAssertNil(InstanceGuard.misplacedNotice(
            bundlePath: "/Users/sam/code/travel-runner/TravelRunner.app", build: build("dev"), home: home, defaults: defaults
        ))
    }

    func testTheBannerComesOnceForEachPlace() throws {
        let downloads = "/Users/sam/Downloads/TravelRunner.app"
        let desktop = "/Users/sam/Desktop/TravelRunner.app"
        let notice = try XCTUnwrap(InstanceGuard.misplacedNotice(
            bundlePath: downloads, build: build("release"), home: home, defaults: defaults
        ))

        // Until the person closes it, the banner stays.
        XCTAssertNotNil(InstanceGuard.misplacedNotice(
            bundlePath: downloads, build: build("release"), home: home, defaults: defaults
        ))

        InstanceGuard.dismiss(notice, defaults: defaults)
        InstanceGuard.dismiss(notice, defaults: defaults)

        XCTAssertNil(InstanceGuard.misplacedNotice(
            bundlePath: downloads, build: build("release"), home: home, defaults: defaults
        ))
        XCTAssertEqual(defaults.stringArray(forKey: InstanceGuard.dismissedPlacesKey), [downloads])
        // Another stray copy is a new case.
        XCTAssertNotNil(InstanceGuard.misplacedNotice(
            bundlePath: desktop, build: build("release"), home: home, defaults: defaults
        ))
    }

    /// macOS gives a new random folder on every launch, so the place is not the path.
    func testATranslocatedCopyHasOneBannerForAllItsFolders() throws {
        let first = "/private/var/folders/ab/T/AppTranslocation/1111/d/TravelRunner.app"
        let second = "/private/var/folders/ab/T/AppTranslocation/2222/d/TravelRunner.app"
        let notice = try XCTUnwrap(InstanceGuard.misplacedNotice(
            bundlePath: first, build: build("release", flavor: .hackathon), home: home, defaults: defaults
        ))

        XCTAssertEqual(
            notice.text,
            "macOS runs this copy of Travel Runner Hackathon from a temporary folder, so it cannot update itself."
        )
        XCTAssertNil(notice.revealPath)

        InstanceGuard.dismiss(notice, defaults: defaults)

        XCTAssertNil(InstanceGuard.misplacedNotice(
            bundlePath: second, build: build("release", flavor: .hackathon), home: home, defaults: defaults
        ))
    }

    @MainActor
    func testTheSupervisorDropsTheBannerAndRemembers() throws {
        let supervisor = EnvironmentSupervisor(userDefaults: defaults)
        let path = "/Users/sam/Downloads/TravelRunner.app"
        supervisor.misplacedCopyNotice = InstanceGuard.misplacedNotice(
            bundlePath: path, build: build("release"), home: home, defaults: defaults
        )
        XCTAssertNotNil(supervisor.misplacedCopyNotice)

        supervisor.dismissMisplacedCopyNotice()

        XCTAssertNil(supervisor.misplacedCopyNotice)
        XCTAssertNil(InstanceGuard.misplacedNotice(
            bundlePath: path, build: build("release"), home: home, defaults: defaults
        ))
    }
}
