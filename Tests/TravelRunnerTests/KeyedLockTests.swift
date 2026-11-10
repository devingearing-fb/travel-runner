import Foundation
import XCTest
@testable import TravelRunner

@MainActor
final class KeyedLockTests: XCTestCase {
    func testOneHolderPerKeyInTheOrderOfTheRequests() async {
        let lock = KeyedLock()
        var events: [String] = []

        let tasks = (1...4).map { number in
            Task { @MainActor in
                await lock.withLock("web") {
                    events.append("start \(number)")
                    try? await Task.sleep(for: .milliseconds(30))
                    events.append("end \(number)")
                }
            }
        }
        for task in tasks { await task.value }

        XCTAssertEqual(events, [
            "start 1", "end 1", "start 2", "end 2", "start 3", "end 3", "start 4", "end 4",
        ])
        XCTAssertFalse(lock.isLocked("web"))
    }

    func testDifferentKeysDoNotWaitForEachOther() async {
        let lock = KeyedLock()
        var events: [String] = []

        let slow = Task { @MainActor in
            await lock.withLock("web") {
                events.append("web start")
                try? await Task.sleep(for: .milliseconds(150))
                events.append("web end")
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        await lock.withLock("db") { events.append("db") }
        await slow.value

        XCTAssertEqual(events, ["web start", "db", "web end"])
    }

    func testTheLockIsFreeAfterAThrow() async {
        struct Failure: Error {}
        let lock = KeyedLock()

        do {
            try await lock.withLock("web") { throw Failure() }
            XCTFail("the error must pass through")
        } catch {}

        XCTAssertFalse(lock.isLocked("web"))
        let value = await lock.withLock("web") { 7 }
        XCTAssertEqual(value, 7)
    }
}
