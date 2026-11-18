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

    private func check(_ shell: FakeCommandRunner, http: Int? = 401) async -> SupabaseStackHealth {
        await SupabaseStackHealth.check(root: root.path, dbPort: 54322, shell: shell, httpStatus: { _ in http })
    }

    func testAWholeStackThatAnswersIsHealthy() async {
        let fake = shell()
        let urls = URLRecorder()
        let health = await SupabaseStackHealth.check(
            root: root.path, dbPort: 54322, shell: fake, httpStatus: { url in urls.add(url); return 401 }
        )
        XCTAssertEqual(health, .healthy)
        // Kong answers 401 without a key: up. The URL takes the port of config.toml.
        XCTAssertEqual(urls.all.map(\.absoluteString), ["http://127.0.0.1:55521/auth/v1/health"])
        let status = fake.calls.first { $0.command.contains("local-db.sh status") }
        XCTAssertEqual(status?.cwd, root.path)
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
        let health = await check(shell(), http: 502)
        XCTAssertEqual(health, .partial(missing: ["auth"]))
    }

    func testADatabaseThatDoesNotAnswerIsPartlyUp() async {
        let health = await check(shell(select: FakeCommandRunner.failed(2, stderr: "the database system is starting up")))
        XCTAssertEqual(health, .partial(missing: ["db"]))
    }

    func testAStackWithoutKeysIsPartlyUp() async {
        let health = await check(shell(status: FakeCommandRunner.failed(1)))
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

/// Collects the URLs of the fake HTTP check.
private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func add(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var all: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}
