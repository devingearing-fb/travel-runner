import Foundation
import XCTest
@testable import TravelRunner

/// Finding ux-global-lasterror-slot: one global error slot, stale and not
/// dismissible. Notices are kept one per key, and each resolves on its own.
final class NoticeCenterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testTheKeysHaveThePlannedNames() {
        let keys: [NoticeKey] = [
            .service("travel-portal"), .dbSetup, .dbProgress, .preflight, .siblingRunner,
            .secretRegistry, .dbMode, .profile, .config,
        ]
        XCTAssertEqual(keys.map(\.id), [
            "service:travel-portal", "db-setup", "db-progress", "preflight", "sibling-runner",
            "secret-registry", "db-mode", "profile", "config",
        ])
    }

    func testAKeyHoldsOneNoticeAndANewOneHidesNoOther() {
        var center = NoticeCenter()
        center.post(.service("web"), "Web App exited", now: start)
        center.post(.profile, "Could not save profile", now: start.addingTimeInterval(1))
        center.post(.service("web"), "Web App is crash-looping", now: start.addingTimeInterval(2))

        XCTAssertEqual(center.all.map(\.text), ["Web App is crash-looping", "Could not save profile"])
        XCTAssertEqual(center.text(.service("web")), "Web App is crash-looping")
        XCTAssertEqual(center.newestError?.key, .service("web"))
    }

    func testTheSameTextAgainKeepsTheNoticeAndItsTime() {
        var center = NoticeCenter()
        center.post(.preflight, "Preflight failed", now: start)
        center.post(.profile, "Could not save profile", now: start.addingTimeInterval(1))
        center.post(.preflight, "Preflight failed", now: start.addingTimeInterval(5))

        XCTAssertEqual(center.notice(.preflight)?.since, start)
        XCTAssertEqual(center.all.map(\.key), [.profile, .preflight], "the order stays")

        // Negative control: a new text is a new notice.
        center.post(.preflight, "Preflight failed again", now: start.addingTimeInterval(6))
        XCTAssertEqual(center.notice(.preflight)?.since, start.addingTimeInterval(6))
        XCTAssertEqual(center.all.first?.key, .preflight)
    }

    func testProgressIsNoError() {
        var center = NoticeCenter()
        center.post(.dbSetup, "DB setup failed at Seed", now: start)
        center.post(.dbProgress, "Empty database — running the reset now (seed: Default)", severity: .info, now: start)

        XCTAssertEqual(center.all.first?.severity, .info)
        XCTAssertEqual(center.newestError?.text, "DB setup failed at Seed")

        center.resolve(.dbSetup)
        XCTAssertNil(center.newestError, "info alone is no error")
        XCTAssertEqual(center.all.count, 1)
    }

    func testResolveAndDismissRemoveOnlyTheirKey() {
        var center = NoticeCenter()
        center.post(.service("web"), "Web App exited", now: start)
        center.post(.service("api"), "API exited", now: start)
        center.post(.config, "Config load failed", now: start)

        center.resolve(.service("web"))
        XCTAssertEqual(center.all.map(\.key), [.config, .service("api")])
        center.dismiss(.config)
        XCTAssertEqual(center.all.map(\.key), [.service("api")])
        center.resolve(.dbSetup)
        XCTAssertEqual(center.all.map(\.key), [.service("api")], "a key with no notice changes nothing")
    }

    func testResolveIfTextKeepsANewerNotice() {
        var center = NoticeCenter()
        center.post(.service("quitter"), "quitter exited (code 0)", now: start)
        center.post(.service("quitter"), "quitter is crash-looping", now: start)

        center.resolve(.service("quitter"), ifText: "quitter exited (code 0)")
        XCTAssertEqual(center.text(.service("quitter")), "quitter is crash-looping")

        center.resolve(.service("quitter"), ifText: "quitter is crash-looping")
        XCTAssertNil(center.notice(.service("quitter")))
    }

    func testAStartOrStopResolvesTheStackNoticesOnly() {
        var center = NoticeCenter()
        for key: NoticeKey in [.service("web"), .dbSetup, .dbProgress, .preflight, .siblingRunner, .secretRegistry, .dbMode] {
            center.post(key, key.id, now: start)
        }
        center.post(.profile, "Could not save profile", now: start)
        center.post(.config, "Paths not applied", now: start)

        center.resolveAll { $0.endsWithStack }

        XCTAssertEqual(Set(center.all.map(\.key)), [.profile, .config])
    }

    func testTheHeaderShowsThreeAndCountsTheRest() {
        var center = NoticeCenter()
        XCTAssertTrue(center.header.shown.isEmpty)
        XCTAssertEqual(center.header.more, 0)

        for index in 0..<5 {
            center.post(.service("s\(index)"), "s\(index) failed", now: start.addingTimeInterval(Double(index)))
        }

        XCTAssertEqual(center.header.shown.map(\.text), ["s4 failed", "s3 failed", "s2 failed"], "the newest first")
        XCTAssertEqual(center.header.more, 2)
        XCTAssertEqual(NoticeCenter.moreText(2), "+2 more — see Status")

        // Negative control: three fit, nothing more.
        center.resolve(.service("s0"))
        center.resolve(.service("s1"))
        XCTAssertEqual(center.header.shown.count, 3)
        XCTAssertEqual(center.header.more, 0)
    }

    func testTheProgressTextNamesTheSeedScenario() {
        XCTAssertEqual(
            EnvironmentSupervisor.emptyDatabaseProgressText(scenario: "Default"),
            "Empty database — running the reset now (seed: Default)"
        )
        XCTAssertEqual(EnvironmentSupervisor.emptyDatabaseProgressText(scenario: nil), "Empty database — running the reset now")
    }
}
