import Foundation
import XCTest
@testable import TravelRunner

/// The Supabase stack check with a fake shell and a fake HTTP answer. No test runs
/// docker or reaches a port.
final class SupabaseStackHealthTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SupabaseStackHealthTests-\(UUID().uuidString)")
        let supabase = root.appendingPathComponent("supabase")
        try FileManager.default.createDirectory(at: supabase, withIntermediateDirectories: true)
        try """
        project_id = "fb-travel"

        [api]
        enabled = true
        port = 55521

        [db]
        port = 54322
        """.write(to: supabase.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private static let allUp = """
    supabase_db_fb-travel\tUp 2 hours (healthy)
    supabase_kong_fb-travel\tUp 2 hours (healthy)
    supabase_auth_fb-travel\tUp 2 hours (healthy)
    supabase_rest_fb-travel\tUp 2 hours
    supabase_studio_fb-travel\tUp 2 hours (healthy)
    """

    private static let statusEnv = """
    ANON_KEY="anon"
    SERVICE_ROLE_KEY="service"
    JWT_SECRET="secret"
    """

    /// A shell with the answers of a stack. `containers` is the `docker ps` output.
    private func shell(
        containers: String? = allUp, publisher: String = "", select: CommandResult = FakeCommandRunner.ok("1\n"),
        status: CommandResult = FakeCommandRunner.ok(statusEnv)
    ) -> FakeCommandRunner {
        FakeCommandRunner { call in
            if call.command.hasPrefix("docker ps --format") {
                return containers.map { FakeCommandRunner.ok($0) } ?? FakeCommandRunner.failed(1, stderr: "Cannot connect to the Docker daemon")
            }
            if call.command.hasPrefix("docker ps --filter publish=") { return FakeCommandRunner.ok(publisher) }
            if call.command.contains("psql") { return select }
            if call.command.contains("local-db.sh status -o env") { return status }
            return FakeCommandRunner.failed(127)
        }
    }

    private func check(_ shell: FakeCommandRunner, http: Int? = 200) async -> SupabaseStackHealth {
        await SupabaseStackHealth.check(root: root.path, dbPort: 54322, shell: shell, httpStatus: { _ in http })
    }

    func testAWholeStackThatAnswersIsHealthy() async {
        let fake = shell()
        let requests = RequestRecorder()
        let health = await SupabaseStackHealth.check(
            root: root.path, dbPort: 54322, shell: fake, httpStatus: { request in requests.add(request); return 200 }
        )
        XCTAssertEqual(health, .healthy)
        // The requests carry the anon key, so Kong passes them on to auth and rest.
        // The URL takes the port of config.toml.
        XCTAssertEqual(requests.all.map { $0.url?.absoluteString },
                       ["http://127.0.0.1:55521/auth/v1/health", "http://127.0.0.1:55521/rest/v1/"])
        XCTAssertEqual(requests.all.map { $0.value(forHTTPHeaderField: "apikey") }, ["anon", "anon"])
        let status = fake.calls.first { $0.command.contains("local-db.sh status") }
        XCTAssertEqual(status?.cwd, root.path)
    }

    /// A crash-looping auth container is listed by `docker ps`, but it is not up.
    func testARestartingAuthContainerIsPartlyUp() async {
        let containers = Self.allUp.replacingOccurrences(
            of: "supabase_auth_fb-travel\tUp 2 hours (healthy)", with: "supabase_auth_fb-travel\tRestarting (1) 4 seconds ago"
        )
        let health = await check(shell(containers: containers), http: 200)
        XCTAssertEqual(health, .partial(missing: ["auth"]))
    }

    /// A container whose health check still starts is not ready yet.
    func testARestContainerWhoseHealthCheckStartsIsPartlyUp() async {
        let containers = Self.allUp.replacingOccurrences(
            of: "supabase_rest_fb-travel\tUp 2 hours", with: "supabase_rest_fb-travel\tUp 3 seconds (health: starting)"
        )
        let health = await check(shell(containers: containers), http: 200)
        XCTAssertEqual(health, .partial(missing: ["rest"]))
    }

    /// Rest behind Kong that does not answer: Kong gives a 5xx with the key.
    func testRestBehindKongAnswering502IsPartlyUp() async {
        let health = await SupabaseStackHealth.check(
            root: root.path, dbPort: 54322, shell: shell(),
            httpStatus: { request in request.url?.path.hasPrefix("/rest/") == true ? 502 : 200 }
        )
        XCTAssertEqual(health, .partial(missing: ["rest"]))
    }

    /// The finding: an open database port counted as a running stack.
    func testAnOpenDatabaseWithKongAndAuthDownIsPartlyUp() async {
        let containers = """
        supabase_db_fb-travel\tUp 2 hours (healthy)
        supabase_kong_fb-travel\tUp 2 hours (unhealthy)
        supabase_rest_fb-travel\tUp 2 hours
        """
        let fake = shell(containers: containers)
        let health = await check(fake, http: nil)
        XCTAssertEqual(health, .partial(missing: ["kong", "auth"]))
        XCTAssertEqual(SupabaseStackHealth.partialRepairLine(["kong", "auth"]),
                       "[travel-runner] Supabase is only partly up (kong, auth not answering) — running db:stop, then db:start")
        // The slow status read runs only for a stack that passed the rest.
        XCTAssertFalse(fake.commands.contains { $0.contains("local-db.sh status") })
    }

    func testAuthBehindKongAnswering500IsPartlyUp() async {
        let health = await SupabaseStackHealth.check(
            root: root.path, dbPort: 54322, shell: shell(),
            httpStatus: { request in request.url?.path.hasPrefix("/auth/") == true ? 502 : 200 }
        )
        XCTAssertEqual(health, .partial(missing: ["auth"]))
    }

    func testADatabaseThatDoesNotAnswerIsPartlyUp() async {
        let health = await check(shell(select: FakeCommandRunner.failed(2, stderr: "the database system is starting up")))
        XCTAssertEqual(health, .partial(missing: ["db"]))
    }

    func testAStackWithoutKeysIsPartlyUp() async {
        // Without the key only Kong's own 401 can come back.
        let health = await check(shell(status: FakeCommandRunner.failed(1)), http: 401)
        XCTAssertEqual(health, .partial(missing: [SupabaseStackHealth.statusPart]))
    }

    func testNoContainerOfTheProjectIsDown() async {
        let health = await check(shell(containers: "supabase_db_fb-travel-data\tUp 3 days\n"))
        XCTAssertEqual(health, .down)
    }

    func testDockerThatDoesNotAnswerIsDown() async {
        let health = await check(shell(containers: nil))
        XCTAssertEqual(health, .down)
    }

    func testAnotherProjectsDatabaseOnThePortIsForeign() async {
        let fake = shell(containers: "supabase_db_fb-travel-data\tUp 3 days\n", publisher: "supabase_db_fb-travel-data\n")
        let health = await check(fake)
        XCTAssertEqual(health, .foreign(container: "supabase_db_fb-travel-data"))
        XCTAssertTrue(fake.commands.contains("docker ps --filter publish=54322 --format '{{.Names}}'"))
    }

    func testTheApiPortComesFromItsSection() {
        XCTAssertEqual(SupabaseStackHealth.apiPort(inConfig: "[db]\nport = 54322\n[api]\nport = 54400 # api\n"), 54400)
        XCTAssertEqual(SupabaseStackHealth.apiPort(inConfig: "[db]\nport = 54322\n"), 54321)
    }
}

/// Collects the requests of the fake HTTP check.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func add(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    var all: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
