import Foundation
import XCTest
@testable import TravelRunner

final class ServiceCatalogTests: XCTestCase {
    private let paths = RepoPaths(
        monorepo: "/work/TRAVEL BOOKING/fb-travel-monolith",
        universalLogin: "/work/fb-amateur-universal-login",
        streamServices: "/work/stream-services",
        loadTest: "/work/TRAVEL BOOKING/travel-load-test"
    )
    private var services: [ServiceDefinition] { ServiceCatalog.services(paths: paths) }
    private var byID: [String: ServiceDefinition] {
        Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
    }

    func testCatalogMatchesCanonicalIDsAndHasNoYalc() {
        XCTAssertEqual(Set(services.map(\.id)), ServiceCatalog.canonicalIDs)
        XCTAssertNil(byID["yalc-link"])
        XCTAssertEqual(byID["universal-login"]?.dependsOn, ["supabase"])
    }

    func testMonorepoServicesRunWithPnpmFromTheRightDirectories() throws {
        let supabase = try XCTUnwrap(byID["supabase"])
        let booking = try XCTUnwrap(byID["travel-portal"])
        let partner = try XCTUnwrap(byID["partner-portal"])

        XCTAssertEqual(supabase.cmd, ["pnpm", "db:start"])
        XCTAssertEqual(supabase.resolvedCwd, paths.monorepo)
        XCTAssertTrue(supabase.shouldReuseIfRunning)
        XCTAssertEqual(booking.cmd, ["pnpm", "dev"])
        XCTAssertEqual(booking.resolvedCwd, paths.bookingPortal)
        XCTAssertEqual(booking.probe?.url, "http://127.0.0.1:3002/api/health")
        XCTAssertEqual(booking.dependsOn, ["universal-login"])
        XCTAssertEqual(partner.cmd, ["pnpm", "dev"])
        XCTAssertEqual(partner.resolvedCwd, paths.partnerPortal)
        XCTAssertEqual(partner.probe?.url, "http://127.0.0.1:3006/api/health")
        XCTAssertEqual(partner.probe?.port, 3006)
    }

    func testPathsWithSpacesAreAbsoluteAndOneArgument() throws {
        let contention = try XCTUnwrap(byID["capacity-contention"])
        let envFile = "--env-file=/work/TRAVEL BOOKING/fb-travel-monolith/apps/booking-portal/.env.local"
        XCTAssertEqual(contention.cmd[1], envFile)
        XCTAssertTrue(ShellQuote.join(contention.cmd).contains("'\(envFile)'"))
        XCTAssertEqual(byID["stream-db-setup"]?.env?["STREAM_SERVICES_DIR"], "/work/stream-services")
        for id in ["stream-qstash", "stream-db-setup", "stream-qstash-wire", "stream-sequin"] {
            XCTAssertEqual(byID[id]?.resolvedCwd, paths.bookingPortal, id)
        }
        for id in ["cache-apply-transport", "cache-cdc-rehearsal", "cache-cutover-audit", "capacity-overflow"] {
            XCTAssertEqual(byID[id]?.resolvedCwd, paths.loadTest, id)
        }
    }

    /// Ticket "Local Sequin Cache CDC exited with code 9": the SIGKILL after two
    /// seconds cut the `compose down` of Sequin and left its containers running.
    func testSequinStopsWithItsStopVerbAndALongGrace() throws {
        let sequin = try XCTUnwrap(byID["stream-sequin"])
        XCTAssertEqual(sequin.resolvedStopCmd, ["./scripts/local-cdc/run-sequin.sh", "stop"])
        XCTAssertEqual(sequin.resolvedStopGrace, .seconds(20))
        XCTAssertEqual(sequin.stoppingText, "Stopping Sequin (compose down)…")
        // Every other service has no stop verb and the default grace.
        for service in services where service.id != "stream-sequin" {
            XCTAssertNil(service.resolvedStopCmd, service.id)
            XCTAssertNil(service.stoppingText, service.id)
            XCTAssertEqual(service.resolvedStopGrace, ServiceDefinition.defaultStopGrace, service.id)
        }
        XCTAssertEqual(ServiceDefinition.defaultStopGrace, .seconds(5))
    }

    /// A custom service of services.json can give its own stop verb and grace.
    func testACustomServiceReadsItsStopVerbAndGrace() throws {
        let json = #"{"id": "custom", "cmd": ["./run.sh"], "depends_on": [], "stop_cmd": ["./run.sh", "stop"], "stop_grace_seconds": 12}"#
        let service = try JSONDecoder().decode(ServiceDefinition.self, from: Data(json.utf8))
        XCTAssertEqual(service.resolvedStopCmd, ["./run.sh", "stop"])
        XCTAssertEqual(service.resolvedStopGrace, .seconds(12))
        XCTAssertEqual(service.stoppingText, "Stopping custom (./run.sh stop)…")

        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(service), encoding: .utf8))
        XCTAssertTrue(encoded.contains(#""stop_grace_seconds":12"#), encoded)

        let plain = try JSONDecoder().decode(
            ServiceDefinition.self, from: Data(#"{"id": "plain", "cmd": ["true"], "depends_on": []}"#.utf8)
        )
        XCTAssertNil(plain.resolvedStopCmd)
        XCTAssertEqual(plain.resolvedStopGrace, .seconds(5))
    }

    func testCacheApplySecretIsSharedAcrossTheChain() {
        let secret = byID["travel-portal"]?.env?["CACHE_APPLY_SECRET_CURRENT"]
        XCTAssertNotNil(secret)
        XCTAssertEqual(byID["stream-services"]?.env?["CACHE_APPLY_SECRET_CURRENT"], secret)
        XCTAssertEqual(byID["cache-apply-transport"]?.env?["CACHE_APPLY_SECRET"], secret)
    }

    func testFullChainStartOrder() throws {
        let graph = try ServiceGraph(services: services)
        let levels = graph.startOrder()
        func level(_ id: String) throws -> Int {
            try XCTUnwrap(levels.firstIndex(where: { $0.contains(id) }), id)
        }
        XCTAssertLessThan(try level("supabase"), try level("universal-login"))
        XCTAssertLessThan(try level("travel-portal"), try level("cache-apply-transport"))
        XCTAssertLessThan(try level("cache-apply-transport"), try level("capacity-contention"))
        XCTAssertLessThan(try level("capacity-contention"), try level("capacity-block-edit-race"))
        XCTAssertLessThan(try level("capacity-block-edit-race"), try level("capacity-overflow"))
        XCTAssertLessThan(try level("capacity-overflow"), try level("stream-db-setup"))
        XCTAssertLessThan(try level("stream-qstash"), try level("stream-services"))
        XCTAssertLessThan(try level("stream-services"), try level("stream-qstash-wire"))
        XCTAssertLessThan(try level("stream-qstash-wire"), try level("stream-sequin"))
        XCTAssertLessThan(try level("stream-sequin"), try level("cache-cdc-rehearsal"))
        XCTAssertLessThan(try level("cache-cdc-rehearsal"), try level("cache-cutover-audit"))
        XCTAssertTrue(Set(["stream-services", "stream-qstash-wire", "stream-sequin", "cache-cdc-rehearsal"])
            .isSubset(of: graph.dependents(of: "stream-qstash")))
    }

    func testProfilesSelectTheirServices() {
        XCTAssertEqual(RunProfile.booking.members(of: services), ["supabase", "universal-login", "stripe", "travel-portal"])
        XCTAssertEqual(RunProfile.partner.members(of: services), ["supabase", "universal-login", "partner-portal"])
        XCTAssertEqual(
            RunProfile.both.members(of: services),
            ["supabase", "universal-login", "stripe", "travel-portal", "partner-portal"]
        )
        XCTAssertEqual(RunProfile.full.members(of: services), ServiceCatalog.canonicalIDs)
    }

    func testEveryProfileIsClosedUnderDependencies() {
        let byID = self.byID
        for profile in RunProfile.allCases {
            let members = profile.members(of: services)
            for id in members {
                for dependency in byID[id]?.dependsOn ?? [] {
                    XCTAssertTrue(members.contains(dependency), "\(profile): \(id) needs \(dependency)")
                }
            }
        }
    }

    func testCustomServicesJoinProfilesWhoseServicesTheyNeed() {
        let custom = [
            ServiceDefinition(id: "db-tool", name: nil, cmd: ["true"], cwd: nil, probe: nil, type: .oneshot,
                              restart: nil, dependsOn: ["supabase"], env: nil, phase: nil, reuseIfRunning: nil),
            ServiceDefinition(id: "portal-tool", name: nil, cmd: ["true"], cwd: nil, probe: nil, type: .oneshot,
                              restart: nil, dependsOn: ["travel-portal"], env: nil, phase: nil, reuseIfRunning: nil),
        ]
        let partner = RunProfile.partner.members(of: services + custom)
        XCTAssertTrue(partner.contains("db-tool"))
        XCTAssertFalse(partner.contains("portal-tool"))
        XCTAssertTrue(RunProfile.booking.members(of: services + custom).contains("portal-tool"))
    }
}
