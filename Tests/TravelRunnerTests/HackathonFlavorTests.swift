import Foundation
import XCTest
@testable import TravelRunner

/// The second app from the same source: Travel Runner Hackathon, for the fork
/// with the agent app.
final class HackathonFlavorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("travel-runner-flavor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Flavor

    func testFlavorComesFromInfoPlistThenEnvironment() {
        XCTAssertEqual(Flavor.resolve(info: nil, environment: [:]), .standard)
        XCTAssertEqual(Flavor.resolve(info: [Flavor.infoKey: "hackathon"], environment: [:]), .hackathon)
        XCTAssertEqual(Flavor.resolve(info: [:], environment: [Flavor.environmentKey: "hackathon"]), .hackathon)
        // The bundle decides, not the environment of the person who opens it.
        XCTAssertEqual(
            Flavor.resolve(info: [Flavor.infoKey: "standard"], environment: [Flavor.environmentKey: "hackathon"]),
            .standard
        )
        XCTAssertEqual(Flavor.resolve(info: [Flavor.infoKey: "other"], environment: [:]), .standard)
    }

    func testTheTestsRunAsTheStandardApp() {
        XCTAssertEqual(Flavor.current, .standard)
    }

    func testTheTwoAppsShareNoState() {
        XCTAssertEqual(Flavor.standard.controlPort, 19900)
        XCTAssertEqual(Flavor.standard.storageName, "travel-runner")
        XCTAssertEqual(Flavor.standard.bundleID, "ai.fastbreak.travel-runner")
        XCTAssertEqual(Flavor.standard.debugTrackingFolder, "debug-tracking")
        for keyPath: KeyPath<Flavor, String> in [\.displayName, \.storageName, \.bundleID, \.debugTrackingFolder, \.controlURL] {
            XCTAssertNotEqual(Flavor.standard[keyPath: keyPath], Flavor.hackathon[keyPath: keyPath])
        }
        XCTAssertNotEqual(Flavor.standard.controlPort, Flavor.hackathon.controlPort)
        XCTAssertEqual(Flavor.standard.hotkeyCharacter, "t")
        XCTAssertNotEqual(Flavor.standard.hotkeyCharacter, Flavor.hackathon.hotkeyCharacter)
        XCTAssertEqual(Flavor.standard.sibling, .hackathon)
        XCTAssertEqual(Flavor.hackathon.sibling, .standard)
    }

    func testOnlyTheStandardAppHasTheRoomsTab() {
        XCTAssertTrue(WorkshopSection.visible(in: .standard).contains(.rooms))
        XCTAssertFalse(WorkshopSection.visible(in: .hackathon).contains(.rooms))
        XCTAssertEqual(WorkshopSection.visible(in: .hackathon).count, WorkshopSection.allCases.count - 1)
    }

    // MARK: - Services

    private let paths = RepoPaths(
        monorepo: "/work/fb-travel-monolith-hackathon",
        universalLogin: "/work/fb-amateur-universal-login",
        streamServices: nil,
        loadTest: nil
    )

    func testOnlyTheHackathonAppHasTheAgentService() throws {
        let standard = ServiceCatalog.services(paths: paths, flavor: .standard)
        XCTAssertNil(standard.first { $0.id == ServiceCatalog.agentID })
        XCTAssertFalse(ServiceCatalog.canonicalIDs(for: .standard).contains(ServiceCatalog.agentID))

        let hackathon = ServiceCatalog.services(paths: paths, flavor: .hackathon)
        XCTAssertEqual(Set(hackathon.map(\.id)), ServiceCatalog.canonicalIDs(for: .hackathon))
        XCTAssertEqual(hackathon.count, standard.count + ServiceCatalog.forkAppIDs.count)

        let agent = try XCTUnwrap(hackathon.first { $0.id == ServiceCatalog.agentID })
        XCTAssertEqual(agent.resolvedCwd, "/work/fb-travel-monolith-hackathon/apps/amateur-agent")
        XCTAssertEqual(agent.cmd, ["pnpm", "exec", "eve", "dev", "--no-ui"])
        // No --port: an `eve dev` in a terminal then connects to this server.
        XCTAssertFalse(agent.cmd.contains("--port"))
        XCTAssertEqual(agent.probe?.port, 2000)
        XCTAssertEqual(agent.resolvedRestart, .onFailure)
        XCTAssertEqual(agent.dependsOn, ["supabase"])
    }

    func testTheAgentIsInEachProfileOfTheHackathonAppOnly() {
        let hackathon = ServiceCatalog.services(paths: paths, flavor: .hackathon)
        for profile in RunProfile.allCases {
            XCTAssertTrue(profile.members(of: hackathon).contains(ServiceCatalog.agentID), "\(profile)")
        }
        let standard = ServiceCatalog.services(paths: paths, flavor: .standard)
        for profile in RunProfile.allCases {
            XCTAssertFalse(profile.members(of: standard).contains(ServiceCatalog.agentID), "\(profile)")
        }
        // The portals do not wait for the agent.
        XCTAssertNoThrow(try ServiceGraph(services: hackathon))
        for id in ["travel-portal", "partner-portal", "universal-login"] {
            XCTAssertFalse(hackathon.first { $0.id == id }?.dependsOn.contains(ServiceCatalog.agentID) ?? true, id)
        }
    }

    func testTheEventDirectoryServiceOfTheHackathonApp() throws {
        let standard = ServiceCatalog.services(paths: paths, flavor: .standard)
        XCTAssertNil(standard.first { $0.id == ServiceCatalog.eventDirectoryID })

        let hackathon = ServiceCatalog.services(paths: paths, flavor: .hackathon)
        let events = try XCTUnwrap(hackathon.first { $0.id == ServiceCatalog.eventDirectoryID })
        XCTAssertEqual(events.resolvedCwd, "/work/fb-travel-monolith-hackathon/apps/event-directory")
        // Not 3000: that is the port of the login.
        XCTAssertEqual(events.cmd, ["pnpm", "dev", "--port", "3001"])
        XCTAssertEqual(events.probe?.port, 3001)
        XCTAssertNotEqual(events.probe?.port, hackathon.first { $0.id == "universal-login" }?.probe?.port)
        // It reads hosted services only.
        XCTAssertEqual(events.dependsOn, [])
        XCTAssertEqual(events.resolvedRestart, .onFailure)

        for profile in RunProfile.allCases {
            XCTAssertTrue(profile.members(of: hackathon).contains(ServiceCatalog.eventDirectoryID), "\(profile)")
            XCTAssertFalse(profile.members(of: standard).contains(ServiceCatalog.eventDirectoryID), "\(profile)")
        }
        // No two services of the hackathon app use the same port.
        let ports = hackathon.compactMap { $0.probe?.port }
        XCTAssertEqual(ports.count, Set(ports).count)
    }

    func testAnOldCheckoutWithoutAForkAppStillPassesPreflight() {
        // The folder of a fork app is not a preflight condition: the app is skipped at its start.
        let hackathon = ServiceCatalog.services(paths: paths, flavor: .hackathon)
        let checks = PreflightRunner().allChecks(for: hackathon).map(\.id)
        XCTAssertFalse(checks.contains("dir-event-directory"))
        XCTAssertFalse(checks.contains("dir-amateur-agent"))
        // The folders of the other services stay conditions, and the ports too.
        XCTAssertTrue(checks.contains("dir-booking-portal"))
        XCTAssertTrue(checks.contains("port-3001"))
        XCTAssertTrue(checks.contains("port-2000"))
    }

    // MARK: - Repo detection

    private func makeMonorepo(_ name: String, agent: Bool) throws -> String {
        let repo = root.appendingPathComponent(name)
        var files = ["pnpm-workspace.yaml", "apps/booking-portal/package.json", "supabase/config.toml"]
        if agent { files.append("apps/amateur-agent/package.json") }
        for file in files {
            let url = repo.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: url)
        }
        return repo.path
    }

    func testTheHackathonAppTakesOnlyTheFork() throws {
        let monolith = try makeMonorepo("fb-travel-monolith", agent: false)
        let fork = try makeMonorepo("fb-travel-monolith-hackathon", agent: true)

        XCTAssertTrue(RepoDetector.isMonorepo(monolith, flavor: .standard))
        XCTAssertFalse(RepoDetector.isMonorepo(monolith, flavor: .hackathon))
        XCTAssertTrue(RepoDetector.isMonorepo(fork, flavor: .hackathon))
        XCTAssertFalse(RepoDetector.validate(path: monolith, role: .monorepo, flavor: .hackathon))

        // A folder with the two checkouts: the hackathon app finds the fork.
        XCTAssertEqual(RepoDetector.scan(directory: root.path, flavor: .hackathon).monorepo, fork)
        XCTAssertEqual(RepoDetector.findMonorepo(near: monolith, flavor: .hackathon), fork)
    }

    // MARK: - Node for the agent

    func testNodeVersionFromFolderNames() {
        XCTAssertEqual(NodeLocator.version(fromName: "v24.3.0"), [24, 3, 0])
        XCTAssertEqual(NodeLocator.version(fromName: "24.11.1"), [24, 11, 1])
        XCTAssertEqual(NodeLocator.version(fromName: "node@24"), [24])
        XCTAssertNil(NodeLocator.version(fromName: "node"))
        XCTAssertNil(NodeLocator.version(fromName: "lts-iron"))
        XCTAssertNil(NodeLocator.version(fromName: "openssl@3.5.1.2"))
        XCTAssertEqual(NodeLocator.major(ofVersionOutput: "v25.6.1\n"), 25)
        XCTAssertNil(NodeLocator.major(ofVersionOutput: ""))
    }

    func testPickTakesTheNewestOfTheLowestMajorThatIsNewEnough() {
        let installs = [
            NodeLocator.Install(version: [22, 14, 0], binDirectory: "/n/22"),
            NodeLocator.Install(version: [24, 2, 0], binDirectory: "/n/24.2"),
            NodeLocator.Install(version: [24, 11, 1], binDirectory: "/n/24.11"),
            NodeLocator.Install(version: [25, 6, 1], binDirectory: "/n/25"),
        ]
        XCTAssertEqual(NodeLocator.pick(installs, minimumMajor: 24)?.binDirectory, "/n/24.11")
        XCTAssertEqual(NodeLocator.pick([installs[0], installs[3]], minimumMajor: 24)?.binDirectory, "/n/25")
        XCTAssertNil(NodeLocator.pick([installs[0]], minimumMajor: 24))
        XCTAssertNil(NodeLocator.pick([], minimumMajor: 24))
    }

    func testInstallsFindsOnlyFoldersWithANodeProgram() throws {
        let home = root.appendingPathComponent("home")
        func makeNode(_ relative: String, executable: Bool = true) throws {
            let bin = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let node = bin.appendingPathComponent("node")
            try Data("#!/bin/sh\n".utf8).write(to: node)
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: node.path)
        }
        try makeNode(".nvm/versions/node/v22.14.0/bin")
        try makeNode(".nvm/versions/node/v24.3.0/bin")
        try makeNode(".local/share/fnm/node-versions/v24.5.0/installation/bin")
        try makeNode(".volta/tools/image/node/24.1.0/bin", executable: false)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".nvm/versions/node/v26.0.0"), withIntermediateDirectories: true
        )

        let installs = NodeLocator.installs(home: home.path).filter { $0.binDirectory.hasPrefix(home.path) }
        XCTAssertEqual(Set(installs.map(\.version)), [[22, 14, 0], [24, 3, 0], [24, 5, 0]])
        XCTAssertEqual(
            NodeLocator.pick(installs, minimumMajor: 24)?.binDirectory,
            home.appendingPathComponent(".local/share/fnm/node-versions/v24.5.0/installation/bin").path
        )
    }

    func testTheNodeCommandPutsTheFolderFirstInPath() throws {
        let fake = root.appendingPathComponent("node bin")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        let command = NodeLocator.command(["/bin/sh", "-c", "echo \"$PATH\"; echo \"$0|$1\"", "zero", "one two"], nodeBin: fake.path)

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", ShellQuote.join(command)]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let lines = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!
            .split(separator: "\n").map(String.init)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(lines[0].hasPrefix("\(fake.path):"), lines[0])
        // The command's own arguments are intact, with their spaces.
        XCTAssertEqual(lines[1], "zero|one two")
    }

    // MARK: - Env of the agent

    private let jwk = #"{"kty":"EC","crv":"P-256","d":"secret","kid":"k1"}"#

    func testTheSharedFileIsReadAsDopplerWritesIt() {
        let content = """
        # shared
        AMATEUR_SUPABASE_URL="https://ref.supabase.co"
        AMATEUR_SUPABASE_ANON_KEY=sb_publishable_x # comment
        AMATEUR_SUPABASE_SIGNING_KEY="{\\"kty\\":\\"EC\\",\\"crv\\":\\"P-256\\",\\"d\\":\\"secret\\",\\"kid\\":\\"k1\\"}"
        export SINGLE='a "b" c'
        EMPTY=
        """
        let shared = AgentEnv.parse(content, dialect: .shared)
        XCTAssertEqual(shared["AMATEUR_SUPABASE_URL"], "https://ref.supabase.co")
        XCTAssertEqual(shared["AMATEUR_SUPABASE_ANON_KEY"], "sb_publishable_x")
        XCTAssertEqual(shared["AMATEUR_SUPABASE_SIGNING_KEY"], jwk)
        XCTAssertEqual(shared["SINGLE"], #"a "b" c"#)
        XCTAssertEqual(shared["EMPTY"], "")

        // eve (Node) stops at the first escaped quote: the same line is not a key there.
        let asEve = AgentEnv.parse(content, dialect: .node)
        XCTAssertEqual(asEve["AMATEUR_SUPABASE_SIGNING_KEY"], #"{\"#)
        XCTAssertEqual(asEve["AMATEUR_SUPABASE_URL"], "https://ref.supabase.co")
    }

    func testAUsableValue() {
        XCTAssertFalse(AgentEnv.isUsable(nil, key: "X"))
        XCTAssertFalse(AgentEnv.isUsable("  ", key: "X"))
        XCTAssertTrue(AgentEnv.isUsable("value", key: "X"))
        XCTAssertTrue(AgentEnv.isUsable(jwk, key: AgentEnv.signingKey))
        XCTAssertTrue(AgentEnv.isUsable("an-hs256-secret", key: AgentEnv.signingKey))
        XCTAssertFalse(AgentEnv.isUsable(#"{\"#, key: AgentEnv.signingKey))
        // Only the signing key must be JSON when it starts as JSON.
        XCTAssertTrue(AgentEnv.isUsable("{x", key: "OTHER"))
    }

    func testThePlanFillsOnlyWhatTheAgentDoesNotSet() {
        let shared = [
            "AMATEUR_SUPABASE_URL": "https://shared", "AMATEUR_SUPABASE_ANON_KEY": "shared-anon",
            "AMATEUR_SUPABASE_SIGNING_KEY": jwk, "STRIPE_SECRET_KEY": "sk_never_for_the_agent",
        ]

        // Nothing of its own: the three Supabase values come from the shared file, and no other key.
        let empty = AgentEnv.plan(own: [:], shared: shared)
        XCTAssertEqual(Set(empty.passthrough.keys), Set(AgentEnv.supabaseKeys))
        XCTAssertEqual(empty.missing, [])
        XCTAssertFalse(empty.hasModelCredential)

        // The copy of .env.example: the keys are there, with no value.
        let blank = AgentEnv.plan(
            own: ["AMATEUR_SUPABASE_URL": "", "AMATEUR_SUPABASE_ANON_KEY": "", "AMATEUR_SUPABASE_SIGNING_KEY": "", "AI_GATEWAY_API_KEY": ""],
            shared: shared
        )
        XCTAssertEqual(blank.passthrough, empty.passthrough)

        // The agent's own values stay.
        let own = AgentEnv.plan(
            own: ["AMATEUR_SUPABASE_URL": "https://own", "AMATEUR_SUPABASE_ANON_KEY": "own-anon",
                  "AMATEUR_SUPABASE_SIGNING_KEY": "own-secret", "AI_GATEWAY_API_KEY": "vck_x"],
            shared: shared
        )
        XCTAssertEqual(own.passthrough, [:])
        XCTAssertTrue(own.hasModelCredential)
        XCTAssertFalse(own.ownSigningKeyUnreadable)

        // The Doppler line pasted into .env.local: eve cannot read it, so the shared value is used.
        let pasted = AgentEnv.plan(
            own: ["AMATEUR_SUPABASE_URL": "https://own", "AMATEUR_SUPABASE_ANON_KEY": "own-anon", "AMATEUR_SUPABASE_SIGNING_KEY": #"{\"#],
            shared: shared
        )
        XCTAssertEqual(pasted.passthrough, ["AMATEUR_SUPABASE_SIGNING_KEY": jwk])
        XCTAssertTrue(pasted.ownSigningKeyUnreadable)

        // No file has the values.
        let none = AgentEnv.plan(own: ["AMATEUR_SUPABASE_URL": "https://own"], shared: [:])
        XCTAssertEqual(none.missing, ["AMATEUR_SUPABASE_ANON_KEY", "AMATEUR_SUPABASE_SIGNING_KEY"])
        XCTAssertEqual(none.passthrough, [:])
    }

    func testAModelCredential() {
        XCTAssertTrue(AgentEnv.plan(own: ["VERCEL_OIDC_TOKEN": "t"], shared: [:]).hasModelCredential)
        let fromShared = AgentEnv.plan(own: [:], shared: ["AI_GATEWAY_API_KEY": "vck_shared"])
        XCTAssertTrue(fromShared.hasModelCredential)
        XCTAssertEqual(fromShared.passthrough["AI_GATEWAY_API_KEY"], "vck_shared")
        // The agent's own key stays.
        let own = AgentEnv.plan(own: ["AI_GATEWAY_API_KEY": "vck_own"], shared: ["AI_GATEWAY_API_KEY": "vck_shared"])
        XCTAssertNil(own.passthrough["AI_GATEWAY_API_KEY"])
    }

    func testTheAgentsOwnFilesInTheOrderOfEve() throws {
        let agent = root.appendingPathComponent("agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try "A=env\nB=env\nC=env\n".write(to: agent.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "B=local\nC=local\n".write(to: agent.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        try "C=dev-local\n".write(to: agent.appendingPathComponent(".env.development.local"), atomically: true, encoding: .utf8)

        XCTAssertEqual(AgentEnv.ownValues(directory: agent.path), ["A": "env", "B": "local", "C": "dev-local"])
        XCTAssertEqual(AgentEnv.ownValues(directory: root.appendingPathComponent("none").path), [:])
    }

    // MARK: - Start of the agent

    func testTheAgentIsSkippedWithoutItsPackagesOrANewNode() {
        let plan = AgentEnv.Plan(passthrough: ["AMATEUR_SUPABASE_URL": "https://shared"], hasModelCredential: true)
        let node24 = NodeLocator.Install(version: [24, 3, 0], binDirectory: "/n/24/bin")

        guard case .skip(let noPackages) = AgentLauncher.decide(
            hasPackages: false, defaultNodeMajor: 25, installs: [node24], env: plan
        ) else { return XCTFail("expected a skip") }
        XCTAssertTrue(noPackages.contains("pnpm install"))

        guard case .skip(let noNode) = AgentLauncher.decide(
            hasPackages: true, defaultNodeMajor: 22, installs: [], env: plan
        ) else { return XCTFail("expected a skip") }
        XCTAssertTrue(noNode.contains("Node 24"))
        XCTAssertTrue(noNode.contains("the default is Node 22"))
    }

    func testTheAgentRunsOnTheDefaultNodeOrOnAFoundOne() throws {
        let plan = AgentEnv.Plan(passthrough: ["AMATEUR_SUPABASE_URL": "https://shared"], hasModelCredential: true)
        let node24 = NodeLocator.Install(version: [24, 3, 0], binDirectory: "/n/24/bin")
        let agent = try XCTUnwrap(ServiceCatalog.services(paths: paths, flavor: .hackathon).first { $0.id == ServiceCatalog.agentID })

        // The default Node is new enough: the command does not change.
        guard case .run(let direct) = AgentLauncher.decide(
            hasPackages: true, defaultNodeMajor: 25, installs: [node24], env: plan
        ) else { return XCTFail("expected a run") }
        XCTAssertNil(direct.nodeBin)
        XCTAssertEqual(AgentLauncher.definition(agent, launch: direct).cmd, agent.cmd)
        XCTAssertEqual(AgentLauncher.definition(agent, launch: direct).env, ["AMATEUR_SUPABASE_URL": "https://shared"])

        // The default Node is 22: the found Node 24 is first in PATH, for the agent only.
        guard case .run(let wrapped) = AgentLauncher.decide(
            hasPackages: true, defaultNodeMajor: 22, installs: [node24], env: plan
        ) else { return XCTFail("expected a run") }
        XCTAssertEqual(wrapped.nodeBin, "/n/24/bin")
        let definition = AgentLauncher.definition(agent, launch: wrapped)
        XCTAssertEqual(Array(definition.cmd.suffix(agent.cmd.count)), agent.cmd)
        XCTAssertTrue(definition.cmd.contains("/n/24/bin"))
        XCTAssertEqual(definition.probe?.port, agent.probe?.port)
        XCTAssertEqual(definition.resolvedCwd, agent.resolvedCwd)
    }

    // MARK: - Env of the event directory

    /// A token in the form of a Vercel OIDC token. The signature is not real.
    private func oidcToken(_ payload: [String: Any]) throws -> String {
        func part(_ object: Any) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(try part(["alg": "RS256"])).\(try part(payload)).c2lnbmF0dXJl"
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheClaimsOfTheTokenNameTheProject() throws {
        let token = try oidcToken([
            "project_id": "prj_abc", "owner_id": "team_xyz", "project": "events.example.ai",
            "exp": 1_800_003_600, "sub": "owner:x:project:y:environment:development",
        ])
        let claims = try XCTUnwrap(EventDirectoryEnv.claims(ofToken: token))
        XCTAssertEqual(claims.projectID, "prj_abc")
        XCTAssertEqual(claims.teamID, "team_xyz")
        XCTAssertEqual(claims.projectName, "events.example.ai")
        XCTAssertEqual(claims.expiresAt, Date(timeIntervalSince1970: 1_800_003_600))
        XCTAssertTrue(claims.isValid(at: now))
        XCTAssertFalse(claims.isValid(at: now.addingTimeInterval(3601)))

        XCTAssertNil(EventDirectoryEnv.claims(ofToken: nil))
        XCTAssertNil(EventDirectoryEnv.claims(ofToken: ""))
        XCTAssertNil(EventDirectoryEnv.claims(ofToken: "not.a.token"))
        XCTAssertNil(EventDirectoryEnv.claims(ofToken: "only-one-part"))
        // A token of another kind, with no project.
        XCTAssertNil(EventDirectoryEnv.claims(ofToken: try oidcToken(["sub": "user", "exp": 1_800_003_600])))
        // No expiry: the project is known, the token is not good.
        let noExpiry = try XCTUnwrap(EventDirectoryEnv.claims(ofToken: try oidcToken(["project_id": "p", "owner_id": "t"])))
        XCTAssertFalse(noExpiry.isValid(at: now))
    }

    func testTheProjectLinkIsWrittenOnceFromTheClaims() throws {
        let app = root.appendingPathComponent("event-directory")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let claims = EventDirectoryEnv.TokenClaims(projectID: "prj_abc", teamID: "team_xyz", projectName: "events.example.ai", expiresAt: nil)

        XCTAssertFalse(EventDirectoryEnv.isLinked(directory: app.path))
        XCTAssertTrue(EventDirectoryEnv.ensureLink(directory: app.path, claims: claims))
        XCTAssertTrue(EventDirectoryEnv.isLinked(directory: app.path))
        let link = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: app.appendingPathComponent(".vercel/project.json"))) as? [String: String]
        )
        // The names that `vercel link` and the app's token library use.
        XCTAssertEqual(link, ["projectId": "prj_abc", "orgId": "team_xyz", "projectName": "events.example.ai"])

        // A link that is there stays, also when it is for another project.
        let other = EventDirectoryEnv.TokenClaims(projectID: "prj_other", teamID: "team_other", projectName: nil, expiresAt: nil)
        XCTAssertFalse(EventDirectoryEnv.ensureLink(directory: app.path, claims: other))
        let kept = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: app.appendingPathComponent(".vercel/project.json"))) as? [String: String]
        )
        XCTAssertEqual(kept["projectId"], "prj_abc")
    }

    func testHowTheAppGetsItsToken() {
        let good = EventDirectoryEnv.TokenClaims(projectID: "p", teamID: "t", projectName: nil, expiresAt: now.addingTimeInterval(3600))
        let expired = EventDirectoryEnv.TokenClaims(projectID: "p", teamID: "t", projectName: nil, expiresAt: now.addingTimeInterval(-3600))

        // A good token works alone. The login and the link decide what happens after it stops.
        XCTAssertEqual(
            EventDirectoryEnv.access(claims: good, linked: true, hasLogin: true, now: now),
            .valid(until: good.expiresAt!, renewable: true)
        )
        XCTAssertEqual(
            EventDirectoryEnv.access(claims: good, linked: true, hasLogin: false, now: now),
            .valid(until: good.expiresAt!, renewable: false)
        )
        XCTAssertEqual(
            EventDirectoryEnv.access(claims: good, linked: false, hasLogin: true, now: now),
            .valid(until: good.expiresAt!, renewable: false)
        )

        // The token stopped: the link and the login together get a new one.
        XCTAssertEqual(EventDirectoryEnv.access(claims: expired, linked: true, hasLogin: true, now: now), .renewable)
        XCTAssertEqual(
            EventDirectoryEnv.access(claims: expired, linked: true, hasLogin: false, now: now),
            .needsLogin(expired: expired.expiresAt)
        )
        // No token in the file: a link that a person made is enough, with the login.
        XCTAssertEqual(EventDirectoryEnv.access(claims: nil, linked: true, hasLogin: true, now: now), .renewable)
        XCTAssertEqual(EventDirectoryEnv.access(claims: nil, linked: true, hasLogin: false, now: now), .needsLogin(expired: nil))
        // Nothing names the project.
        XCTAssertEqual(EventDirectoryEnv.access(claims: nil, linked: false, hasLogin: true, now: now), .needsEnv)

        XCTAssertTrue(EventDirectoryEnv.isUsable(.renewable))
        XCTAssertTrue(EventDirectoryEnv.isUsable(.valid(until: now, renewable: false)))
        XCTAssertFalse(EventDirectoryEnv.isUsable(.needsLogin(expired: nil)))
        XCTAssertFalse(EventDirectoryEnv.isUsable(.needsEnv))
        XCTAssertTrue(EventDirectoryEnv.summary(.needsLogin(expired: nil)).contains("npx vercel login"))
        XCTAssertTrue(EventDirectoryEnv.summary(.valid(until: now, renewable: false)).contains("npx vercel login"))
        XCTAssertFalse(EventDirectoryEnv.summary(.renewable).contains("npx vercel login"))
    }

    func testTheEnvFilesOfTheEventDirectory() throws {
        let app = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertEqual(EventDirectoryEnv.missingKeys(EventDirectoryEnv.values(directory: app.path)), ["SITE_URL", "PXI_API_URL"])

        // As `vercel env pull` writes it.
        try """
        # Created by Vercel CLI
        VERCEL_OIDC_TOKEN="a.b.c"
        PXI_API_URL="https://api.example.ai"
        SITE_URL=""
        """.write(to: app.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        let values = EventDirectoryEnv.values(directory: app.path)
        XCTAssertEqual(values["PXI_API_URL"], "https://api.example.ai")
        XCTAssertEqual(values["VERCEL_OIDC_TOKEN"], "a.b.c")
        // An empty value is a missing value.
        XCTAssertEqual(EventDirectoryEnv.missingKeys(values), ["SITE_URL"])

        try "SITE_URL=https://events.example.ai\nPXI_API_URL=https://weaker\n"
            .write(to: app.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        // .env.local is stronger than .env, also with an empty value, as in Next.js.
        XCTAssertEqual(EventDirectoryEnv.values(directory: app.path)["PXI_API_URL"], "https://api.example.ai")
        XCTAssertEqual(EventDirectoryEnv.missingKeys(EventDirectoryEnv.values(directory: app.path)), ["SITE_URL"])
    }

    func testAVercelLoginIsATokenOrARefreshToken() throws {
        let home = root.appendingPathComponent("home")
        let directory = home.appendingPathComponent("Library/Application Support/com.vercel.cli")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let auth = directory.appendingPathComponent("auth.json")

        XCTAssertFalse(EventDirectoryEnv.hasVercelLogin(home: home.path))
        // The file after a logout, or after a refresh that failed.
        try "{}".write(to: auth, atomically: true, encoding: .utf8)
        XCTAssertFalse(EventDirectoryEnv.hasVercelLogin(home: home.path))
        try #"{"token":"","refreshToken":"r"}"#.write(to: auth, atomically: true, encoding: .utf8)
        XCTAssertTrue(EventDirectoryEnv.hasVercelLogin(home: home.path))
        try #"{"token":"t"}"#.write(to: auth, atomically: true, encoding: .utf8)
        XCTAssertTrue(EventDirectoryEnv.hasVercelLogin(home: home.path))
    }

    func testTheEventDirectoryIsSkippedWithoutItsPackagesOrItsEnv() {
        guard case .skip(let noPackages) = EventDirectoryLauncher.decide(
            hasPackages: false, missingKeys: [], access: .renewable, wroteLink: false
        ) else { return XCTFail("expected a skip") }
        XCTAssertTrue(noPackages.contains("pnpm install"))

        guard case .skip(let noEnv) = EventDirectoryLauncher.decide(
            hasPackages: true, missingKeys: ["SITE_URL", "PXI_API_URL"], access: .needsEnv, wroteLink: false
        ) else { return XCTFail("expected a skip") }
        XCTAssertTrue(noEnv.contains("SITE_URL, PXI_API_URL"))
        XCTAssertTrue(noEnv.contains("Import"))

        // A token that stopped does not stop the start: the static pages work, and the log says what to do.
        guard case .run(let notes, _) = EventDirectoryLauncher.decide(
            hasPackages: true, missingKeys: [], access: .needsLogin(expired: nil), wroteLink: true
        ) else { return XCTFail("expected a run") }
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes[0].contains(".vercel/project.json"))
        XCTAssertTrue(notes[1].contains("npx vercel login"))

        guard case .run(let quiet, let noEnv2) = EventDirectoryLauncher.decide(
            hasPackages: true, missingKeys: [], access: .renewable, wroteLink: false
        ) else { return XCTFail("expected a run") }
        XCTAssertEqual(quiet.count, 1)
        XCTAssertEqual(noEnv2, [:])
    }

    func testTheEventDirectoryGetsTheAddressOfTheRunnersAgent() throws {
        // The app shows the chat and sends /eve/v1/* to this address. The agent listens on 127.0.0.1.
        XCTAssertEqual(EventDirectoryEnv.processEnv([:]), ["AMATEUR_AGENT_URL": "http://127.0.0.1:2000"])
        XCTAssertEqual(EventDirectoryEnv.processEnv(["AMATEUR_AGENT_URL": " "]), ["AMATEUR_AGENT_URL": "http://127.0.0.1:2000"])
        // An address in the app's own files stays: a value of the process would replace it.
        XCTAssertEqual(EventDirectoryEnv.processEnv(["AMATEUR_AGENT_URL": "https://agent.example.ai"]), [:])

        let events = try XCTUnwrap(
            ServiceCatalog.services(paths: paths, flavor: .hackathon).first { $0.id == ServiceCatalog.eventDirectoryID }
        )
        guard case .run(let notes, let env) = EventDirectoryLauncher.decide(
            hasPackages: true, missingKeys: [], access: .renewable, wroteLink: false, env: EventDirectoryEnv.processEnv([:])
        ) else { return XCTFail("expected a run") }
        XCTAssertTrue(notes.contains { $0.contains("AMATEUR_AGENT_URL=http://127.0.0.1:2000") })
        let definition = EventDirectoryLauncher.definition(events, env: env)
        XCTAssertEqual(definition.env?["AMATEUR_AGENT_URL"], "http://127.0.0.1:2000")
        XCTAssertEqual(definition.cmd, events.cmd)
        XCTAssertEqual(definition.probe?.port, events.probe?.port)
        // With nothing to give, the service does not change.
        XCTAssertNil(EventDirectoryLauncher.definition(events, env: [:]).env)
    }

    // MARK: - The other runner app

    func testActiveServicesOfTheOtherApp() {
        let status = """
        {"app":"standard","health":"HEALTHY","services":{
          "supabase":{"phase":"RUNNING","pid":"nil"},
          "travel-portal":{"phase":"STARTING","pid":"123"},
          "stripe":{"phase":"SKIPPED","pid":"nil"},
          "partner-portal":{"phase":"FAILED","pid":"nil"},
          "cache-cutover-audit":{"phase":"PENDING","pid":"nil"},
          "universal-login":{"phase":"STOPPING","pid":"9"}
        }}
        """
        XCTAssertEqual(
            SiblingRunner.activeServices(statusJSON: Data(status.utf8)),
            ["supabase", "travel-portal", "universal-login"]
        )

        let stopped = #"{"health":"STOPPED","services":{"supabase":{"phase":"STOPPED","pid":"nil"},"x":{"phase":"PENDING","pid":"nil"}}}"#
        XCTAssertEqual(SiblingRunner.activeServices(statusJSON: Data(stopped.utf8)), [])
        XCTAssertEqual(SiblingRunner.activeServices(statusJSON: Data("not json".utf8)), [])
        XCTAssertEqual(SiblingRunner.activeServices(statusJSON: Data("{}".utf8)), [])
    }

    func testNoAnswerMeansTheOtherAppRunsNothing() async {
        // The hackathon app is not open during the tests: its port refuses the connection.
        let services = await SiblingRunner.activeServices(of: .hackathon, timeout: 1)
        XCTAssertEqual(services, [])
        XCTAssertEqual(SiblingRunner.activeServicesNow(of: .hackathon, timeout: 1), [])
    }

    func testTheStatusOfARunningAppIsReadOverHTTP() async throws {
        // A small server in the place of the other app's control API.
        let site = root.appendingPathComponent("site/api")
        try FileManager.default.createDirectory(at: site, withIntermediateDirectories: true)
        try #"{"services":{"travel-portal":{"phase":"RUNNING","pid":"7"},"stripe":{"phase":"SKIPPED","pid":"nil"}}}"#
            .write(to: site.appendingPathComponent("status"), atomically: true, encoding: .utf8)

        let probe = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(probe, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(probe, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        close(probe)

        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-m", "http.server", "\(port)", "--bind", "127.0.0.1", "--directory", root.appendingPathComponent("site").path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        defer { server.terminate() }

        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/api/status"))
        var services: [String] = []
        for _ in 0..<50 where services.isEmpty {
            services = await SiblingRunner.activeServices(at: url, timeout: 1)
            if services.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertEqual(services, ["travel-portal"])
        // The same from code that cannot wait in a task. Not on the main thread here:
        // the test's own run loop is not the app's.
        let now = await Task.detached { SiblingRunner.activeServicesNow(at: url, timeout: 1) }.value
        XCTAssertEqual(now, ["travel-portal"])
    }

    func testTheRefusalNamesTheOtherAppAndItsServices() {
        let text = SiblingRunner.refusal(activeServices: ["supabase", "travel-portal"], sibling: .standard)
        XCTAssertTrue(text.contains("Travel Runner runs a stack now (supabase, travel-portal)"))
    }
}
