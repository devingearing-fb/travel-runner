import Foundation
import XCTest
@testable import TravelRunner

/// Exit 126/127 (and a pnpm run that ends with 1) says what is missing: the tool,
/// the packages, the script or the execute bit. Each case has its words and its button.
final class CommandDiagnosisTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CommandDiagnosisTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writePackage(scripts: [String: String], in folder: URL? = nil) throws {
        let folder = folder ?? dir!
        let data = try JSONSerialization.data(withJSONObject: ["name": "app", "scripts": scripts])
        try data.write(to: folder.appendingPathComponent("package.json"))
    }

    private func makeModules(in folder: URL? = nil) throws {
        try FileManager.default.createDirectory(
            at: (folder ?? dir!).appendingPathComponent("node_modules"), withIntermediateDirectories: true
        )
    }

    private func diagnose(
        _ code: Int32, _ command: [String], log: [String] = [], tool: ToolEnvironment.MissingTool? = nil
    ) -> CommandDiagnosis.Finding {
        CommandDiagnosis.diagnose(code: code, command: command, cwd: dir.path, logTail: log, tool: tool)
    }

    // MARK: - Tool missing

    func testAToolThatIsNotOnThePathNamesThePathAndOffersHealth() {
        let finding = diagnose(127, ["pnpm", "dev"], tool: .notFound(searchedPath: "/usr/bin:/bin"))
        XCTAssertEqual(finding, .toolMissing(tool: "pnpm", searchedPath: "/usr/bin:/bin"))
        XCTAssertEqual(
            CommandDiagnosis.message(finding, name: "Booking Portal", appName: "Travel Runner"),
            "Booking Portal cannot start: `pnpm` is not on Travel Runner's PATH. It looked in: /usr/bin:/bin. "
                + "Open Health to see where each tool was found."
        )
        XCTAssertEqual(CommandDiagnosis.actions(finding), [.openHealth, .openLog])
    }

    func testAToolThatANewReadFoundSaysRestart() {
        let finding = diagnose(127, ["pnpm", "dev"], tool: .foundNow(path: "/new/bin/pnpm"))
        XCTAssertEqual(finding, .toolFoundNow(tool: "pnpm", path: "/new/bin/pnpm"))
        XCTAssertEqual(
            CommandDiagnosis.message(finding, name: "Booking Portal", appName: "Travel Runner"),
            ToolEnvironment.foundNowText(name: "Booking Portal", tool: "pnpm", path: "/new/bin/pnpm", appName: "Travel Runner")
        )
        XCTAssertEqual(CommandDiagnosis.actions(finding), [.restart])
    }

    // MARK: - Dependencies missing

    func testExit127WithoutNodeModulesSaysThePackagesAreNotInstalled() throws {
        try writePackage(scripts: ["dev": "next dev"])
        let finding = diagnose(127, ["npm", "run", "dev"], log: ["sh: next: command not found"])
        XCTAssertEqual(finding, .dependenciesMissing(repo: dir.path))
        XCTAssertEqual(
            CommandDiagnosis.message(finding, name: "Stream Services"),
            "Stream Services cannot start: its packages are not installed in \(dir.path)."
        )
        XCTAssertEqual(CommandDiagnosis.actions(finding), [.installDependencies, .openLog])
        XCTAssertEqual(RecoveryAction.installDependencies.title(), "Install dependencies")
    }

    /// Negative control: with `node_modules` in place and no "command not found",
    /// the packages are not blamed.
    func testInstalledPackagesAreNotBlamed() throws {
        try writePackage(scripts: ["dev": "next dev"])
        try makeModules()
        XCTAssertEqual(diagnose(127, ["npm", "run", "dev"]), .unknown(command: "npm", code: 127))
        // A tool of the packages that is gone from an old install is still the packages.
        XCTAssertEqual(
            diagnose(127, ["npm", "run", "dev"], log: ["sh: next: command not found"]),
            .dependenciesMissing(repo: dir.path)
        )
    }

    /// Inside a pnpm workspace the install runs at its root, so the text names the root.
    func testAPackageOfAWorkspaceNamesTheRootOfTheWorkspace() throws {
        try "packages:\n  - apps/*\n".write(
            to: dir.appendingPathComponent("pnpm-workspace.yaml"), atomically: true, encoding: .utf8
        )
        let app = dir.appendingPathComponent("apps/web")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try writePackage(scripts: ["dev": "next dev"], in: app)
        let finding = CommandDiagnosis.diagnose(
            code: 127, command: ["pnpm", "dev"], cwd: app.path, logTail: [], tool: nil
        )
        XCTAssertEqual(finding, .dependenciesMissing(repo: dir.path))
    }

    func testAMissingFileUnderNodeModulesIsAMissingInstall() throws {
        try writePackage(scripts: [:])
        let finding = diagnose(
            127, ["./node_modules/.bin/qstash", "dev"], log: ["zsh:1: no such file or directory: ./node_modules/.bin/qstash"]
        )
        XCTAssertEqual(finding, .dependenciesMissing(repo: dir.path))
    }

    /// pnpm ends with 1, not 127, when `node_modules` is missing. Its log says so.
    func testAPnpmRunThatEndsWith1WithoutPackagesIsAMissingInstall() throws {
        try writePackage(scripts: ["dev": "next dev"])
        let log = [
            "> next dev", "sh: next: command not found", " ELIFECYCLE  Command failed.",
            " WARN   Local package.json exists, but node_modules missing, did you mean to install?",
        ]
        XCTAssertEqual(
            CommandDiagnosis.diagnoseFailedRun(command: ["pnpm", "dev"], cwd: dir.path, logTail: log),
            .dependenciesMissing(repo: dir.path)
        )
        // Negative control: an ordinary crash of an installed app is not a missing install.
        try makeModules()
        XCTAssertNil(CommandDiagnosis.diagnoseFailedRun(
            command: ["pnpm", "dev"], cwd: dir.path, logTail: ["TypeError: x is not a function"]
        ))
        // Negative control: a command that is not a package manager.
        XCTAssertNil(CommandDiagnosis.diagnoseFailedRun(
            command: ["supabase", "start"], cwd: dir.path, logTail: ["command not found"]
        ))
    }

    // MARK: - Script missing

    func testAScriptThatTheBranchDoesNotHaveNamesThePackageJSON() throws {
        try writePackage(scripts: ["build": "next build"])
        try makeModules()
        let packageJSON = dir.appendingPathComponent("package.json").path
        let finding = diagnose(127, ["pnpm", "dev"])
        XCTAssertEqual(finding, .scriptMissing(script: "dev", packageJSON: packageJSON))
        XCTAssertEqual(
            CommandDiagnosis.message(finding, name: "Booking Portal"),
            "Booking Portal cannot start: this branch has no script `dev` in \(packageJSON). "
                + "Switch branch or pull, then restart Booking Portal."
        )
        XCTAssertEqual(CommandDiagnosis.actions(finding), [.restart, .openLog])
    }

    /// pnpm ends with 1 or 254 when the script is missing.
    func testAPnpmRunThatEndsWith254WithoutTheScriptIsAMissingScript() throws {
        try writePackage(scripts: ["dev": "next dev"])
        try makeModules()
        let log = [" ERR_PNPM_RECURSIVE_EXEC_FIRST_FAIL  Command \"db:start\" not found"]
        XCTAssertEqual(
            CommandDiagnosis.diagnoseFailedRun(command: ["pnpm", "db:start"], cwd: dir.path, logTail: log),
            .scriptMissing(script: "db:start", packageJSON: dir.appendingPathComponent("package.json").path)
        )
        // Negative control: the script is there, so the log line is about something else.
        XCTAssertNil(CommandDiagnosis.diagnoseFailedRun(command: ["pnpm", "dev"], cwd: dir.path, logTail: log))
    }

    func testTheScriptOfACommand() {
        XCTAssertEqual(CommandDiagnosis.scriptName(of: ["pnpm", "dev"]), "dev")
        XCTAssertEqual(CommandDiagnosis.scriptName(of: ["pnpm", "dev", "--port", "3004"]), "dev")
        XCTAssertEqual(CommandDiagnosis.scriptName(of: ["pnpm", "run", "db:start"]), "db:start")
        XCTAssertEqual(CommandDiagnosis.scriptName(of: ["npm", "run", "dev", "--", "-p", "3003"]), "dev")
        XCTAssertEqual(CommandDiagnosis.scriptName(of: ["yarn", "dev"]), "dev")
        XCTAssertNil(CommandDiagnosis.scriptName(of: ["pnpm", "exec", "eve", "dev"]))
        XCTAssertNil(CommandDiagnosis.scriptName(of: ["pnpm", "--filter", "web", "dev"]))
        XCTAssertNil(CommandDiagnosis.scriptName(of: ["npm", "install"]))
        XCTAssertNil(CommandDiagnosis.scriptName(of: ["node", "server.js"]))
    }

    // MARK: - Files

    func testAScriptFileThatTheBranchDoesNotHaveIsNamed() {
        let finding = diagnose(127, ["./scripts/run-sequin.sh"])
        XCTAssertEqual(finding, .fileMissing(file: "./scripts/run-sequin.sh", folder: dir.path))
        XCTAssertEqual(
            CommandDiagnosis.message(finding, name: "Sequin"),
            "Sequin cannot start: this branch has no file `./scripts/run-sequin.sh` in \(dir.path). "
                + "Switch branch or pull, then restart Sequin."
        )
    }

    func testExit126NamesTheFileThatIsNotExecutable() {
        let zsh = diagnose(126, ["./scripts/run.sh"], log: ["zsh:1: permission denied: ./scripts/run.sh"])
        XCTAssertEqual(zsh, .notExecutable(file: "./scripts/run.sh"))
        XCTAssertEqual(
            CommandDiagnosis.message(zsh, name: "Sequin"), "Sequin cannot start: ./scripts/run.sh is not executable (exit 126)."
        )
        XCTAssertEqual(CommandDiagnosis.actions(zsh), [.openLog, .restart])

        // A tool of the packages that lost its execute bit; sh says it differently.
        let sh = diagnose(126, ["pnpm", "dev"], log: ["sh: /repo/node_modules/.bin/next: Permission denied"])
        XCTAssertEqual(sh, .notExecutable(file: "/repo/node_modules/.bin/next"))
        // With no log line the command is named.
        XCTAssertEqual(diagnose(126, ["./run.sh"]), .notExecutable(file: "./run.sh"))
    }

    // MARK: - No cause

    func testNoCauseKeepsTheOldQuestion() {
        let finding = diagnose(127, ["supabase", "start"])
        XCTAssertEqual(finding, .unknown(command: "supabase", code: 127))
        XCTAssertEqual(
            CommandDiagnosis.message(finding, name: "Supabase"),
            "Supabase cannot start: the shell could not run supabase (exit 127). Does the current branch have it? "
                + "Restart Supabase after the fix."
        )
        XCTAssertEqual(CommandDiagnosis.actions(finding), [.openLog, .restart])
    }

    // MARK: - Failure advisor

    /// A pnpm run that ended with 1 gets the same words and button through the advisor.
    func testTheAdvisorUsesTheDiagnosisForAFailedPnpmRun() throws {
        try writePackage(scripts: ["dev": "next dev"])
        let context = FailureAdvisor.Context(
            name: "Booking Portal", logTail: ["sh: next: command not found"], command: ["pnpm", "dev"], cwd: dir.path
        )
        let condition = FailureAdvisor.advise(.exited(code: 1), context, now: Date())
        XCTAssertEqual(condition.headline, "Booking Portal cannot start: its packages are not installed in \(dir.path).")
        XCTAssertEqual(condition.actions, [.installDependencies, .openLog])

        let cannotRun = FailureAdvisor.advise(.cannotRun(.notExecutable(file: "./run.sh")), context, now: Date())
        XCTAssertEqual(cannotRun.headline, "Booking Portal cannot start: ./run.sh is not executable (exit 126).")
        XCTAssertEqual(cannotRun.actions, [.openLog, .restart])
    }
}
