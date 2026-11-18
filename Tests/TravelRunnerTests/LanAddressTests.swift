import XCTest
@testable import TravelRunner

final class LanAddressTests: XCTestCase {
    private typealias Address = LanAddress.InterfaceAddress

    func testTheInterfaceComesFromTheDefaultRoute() {
        let output = """
           route to: default
        destination: default
               mask: default
            gateway: 10.0.1.1
          interface: en7
              flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
        """
        XCTAssertEqual(LanAddress.defaultInterface(fromRouteOutput: output), "en7")
        XCTAssertNil(LanAddress.defaultInterface(fromRouteOutput: "route: writing to routing socket: not in table"))
        XCTAssertNil(LanAddress.defaultInterface(fromRouteOutput: ""))
    }

    /// Finding env-hardcoded-author-layout: `en0` was hard-coded. A USB or
    /// Thunderbolt adapter is another interface.
    func testTheDefaultRouteInterfaceWinsOverEn0() {
        let addresses = [Address(interface: "en0", ip: "192.168.1.20"), Address(interface: "en7", ip: "10.0.1.23")]
        let picked = LanAddress.pick(defaultInterface: "en7", from: addresses)
        XCTAssertEqual(picked, LanAddress(interface: "en7", ip: "10.0.1.23"))
        XCTAssertEqual(picked?.label, "en7 · 10.0.1.23")
    }

    /// A VPN tunnel carries the default route, but a phone cannot reach its address.
    func testAVpnDefaultRouteFallsBackToTheLanInterface() {
        let addresses = [Address(interface: "utun4", ip: "100.64.0.2"), Address(interface: "en0", ip: "192.168.1.20")]
        XCTAssertEqual(
            LanAddress.pick(defaultInterface: "utun4", from: addresses),
            LanAddress(interface: "en0", ip: "192.168.1.20")
        )
    }

    func testNoDefaultRouteUsesTheFirstEthernetOrWifiAddress() {
        let addresses = [Address(interface: "bridge100", ip: "192.168.64.1"), Address(interface: "en1", ip: "10.0.0.5")]
        XCTAssertEqual(LanAddress.pick(defaultInterface: nil, from: addresses), LanAddress(interface: "en1", ip: "10.0.0.5"))
    }

    /// Finding ux-lan-mode-ip: no address must stay no address, never 127.0.0.1.
    func testLoopbackAndSelfAssignedAddressesAreNoLanAddress() {
        let addresses = [Address(interface: "en0", ip: "169.254.10.4"), Address(interface: "lo0", ip: "127.0.0.1")]
        XCTAssertNil(LanAddress.pick(defaultInterface: "en0", from: addresses))
        XCTAssertNil(LanAddress.pick(defaultInterface: nil, from: []))
    }

    /// A move between networks sends several path updates. The supervisor hears
    /// one, after the path was quiet for the debounce time.
    @MainActor
    func testTheObserverReportsABurstOfChangesOnce() async throws {
        let time = FakeClock()
        // A wait that a failed check leaves behind must not keep the run going.
        addTeardownBlock { time.advance(by: .seconds(3600)) }
        var changes = 0
        let observer = NetworkObserver(debounce: .seconds(5), clock: time.manual) { changes += 1 }

        observer.pathChanged()
        await until { time.heldWaits == 1 }
        time.advance(by: .seconds(4))
        observer.pathChanged()
        observer.pathChanged()
        await until { time.heldWaits == 1 && time.sleeps.count >= 2 }
        time.advance(by: .seconds(4))
        await drain()
        XCTAssertEqual(changes, 0, "each change starts the debounce again")
        time.advance(by: .seconds(1))
        await until { changes == 1 }
        XCTAssertEqual(changes, 1)

        observer.pathChanged()
        await until { time.heldWaits == 1 }
        observer.stopObserving()
        await until { time.heldWaits == 0 }
        time.advance(by: .seconds(10))
        await drain()
        XCTAssertEqual(changes, 1, "a stop drops the change that waits")
    }

    /// NWPathMonitor sends the current path when it starts. That is no change.
    @MainActor
    func testTheFirstPathUpdateIsNoChange() async throws {
        let time = FakeClock()
        // A wait that a failed check leaves behind must not keep the run going.
        addTeardownBlock { time.advance(by: .seconds(3600)) }
        var changes = 0
        let observer = NetworkObserver(debounce: .seconds(5), clock: time.manual) { changes += 1 }

        observer.pathUpdated()
        await drain()
        XCTAssertEqual(time.heldWaits, 0)
        time.advance(by: .seconds(10))
        await drain()
        XCTAssertEqual(changes, 0)

        observer.pathUpdated()
        await until { time.heldWaits == 1 }
        time.advance(by: .seconds(5))
        await until { changes == 1 }
        XCTAssertEqual(changes, 1, "the second update is a change")

        // A new start sends the current path again.
        observer.stopObserving()
        observer.pathUpdated()
        await drain()
        XCTAssertEqual(time.heldWaits, 0)
    }

    /// Lets the tasks that can run, run, so a check that nothing happened means it.
    @MainActor
    private func drain() async {
        for _ in 0..<20 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// Waits for tasks to reach a state. It asserts nothing about time.
    @MainActor
    private func until(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
