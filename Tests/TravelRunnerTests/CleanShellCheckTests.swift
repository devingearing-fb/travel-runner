import Foundation
import XCTest

/// `scripts/clean-shell-check.sh`, which release.sh runs before a build. The tests give
/// it stub tools and a fake monolith whose check-prerequisites step is a bash script
/// (the stub `node` runs it) and whose Python scripts the stub `python3` reads, so no
/// real node, docker or python runs.
final class CleanShellCheckTests: XCTestCase {
    private var work: URL!
    private var stubs: URL!
    private var monolith: URL!

    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/clean-shell-check.sh").path

    override func setUpWithError() throws {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("clean-shell-\(UUID().uuidString)")
        stubs = work.appendingPathComponent("stubs")
        monolith = work.appendingPathComponent("mono with space")
        for dir in [stubs!, monolith.appendingPathComponent("scripts/db"), monolith.appendingPathComponent("scripts/setup"),
                    monolith.appendingPathComponent("node_modules"),
                    work.appendingPathComponent("home")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try write(".nvmrc", "22\n")
        try write("package.json", #"{ "packageManager": "pnpm@10.34.5" }"#)
        try stub("node", #"if [ "$1" = --version ]; then echo v22.23.4; exit 0; fi; exec /bin/bash "$@""#)
        try stub("pnpm", "echo 10.34.5")
        try stub("docker", #"if [ "$1" = context ]; then echo unix:///tmp/fake-docker.sock; else echo "Docker version 29.0.0"; fi"#)
        // A Python with an extra package: the import check finds jwt unless site-packages
        // are off (-S). It records its arguments, and reports each file that imports jwt.
        let pythonRecord = work.appendingPathComponent("python.txt").path
        try stub("python3", #"""
            for arg in "$@"; do [ "$arg" = -S ] && no_site=1; done
            if [ "${@: -1}" = --version ]; then echo "Python 3.12.0"; exit 0; fi
            printf '%s\n' "$@" > '\#(pythonRecord)'
            files=(); after_code=; skip=
            for arg in "$@"; do
                if [ -n "$skip" ]; then skip=; after_code=1; continue; fi
                if [ "$arg" = -c ]; then skip=1; continue; fi
                [ -n "$after_code" ] && files+=("$arg")
            done
            missing=0
            for file in "${files[@]}"; do
                line="$(grep -nE '^[[:space:]]*(import|from) jwt' "$file" | head -1 | cut -d: -f1)"
                [ -n "$line" ] && [ -n "${no_site:-}" ] && { echo "$file:$line: import jwt"; missing=1; }
            done
            exit $missing
            """#)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: work)
    }

    func testTheStepRunsWithOnlyTheReadmeToolsAndAnEmptyHome() throws {
        let record = work.appendingPathComponent("record.txt").path
        try write("scripts/db/check-prerequisites.mjs", """
            printf 'home=%s\\npath=%s\\ndocker=%s\\nargs=%s\\npwd=%s\\n' "$HOME" "$PATH" "$DOCKER_HOST" "$*" "$PWD" > '\(record)'
            ls "${PATH%%:*}" >> '\(record)'
            """)

        let result = try runCheck()
        XCTAssertEqual(result.code, 0, result.output)
        XCTAssertTrue(result.output.contains("clean-shell check passed"), result.output)

        let lines = try String(contentsOfFile: record, encoding: .utf8).split(separator: "\n").map(String.init)
        let home = try XCTUnwrap(lines.first { $0.hasPrefix("home=") }).dropFirst(5)
        XCTAssertFalse(home.isEmpty)
        XCTAssertNotEqual(String(home), work.appendingPathComponent("home").path, "the caller's home must not count")
        let path = try XCTUnwrap(lines.first { $0.hasPrefix("path=") }).dropFirst(5).split(separator: ":").map(String.init)
        XCTAssertEqual(Array(path.dropFirst()), ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        XCTAssertFalse(path.contains(stubs.path), "the caller's PATH must not count")
        XCTAssertTrue(lines.contains("docker=unix:///tmp/fake-docker.sock"), "the current docker context gives DOCKER_HOST")
        XCTAssertTrue(lines.contains("args=--verify"), "the step must send no request")
        let pwd = try XCTUnwrap(lines.first { $0.hasPrefix("pwd=") }).dropFirst(4)
        XCTAssertEqual(URL(fileURLWithPath: String(pwd)).resolvingSymlinksInPath(), monolith.resolvingSymlinksInPath())
        // Only the README tools are on the clean PATH.
        XCTAssertEqual(Set(lines.filter { !$0.contains("=") }), ["node", "pnpm", "docker", "python3"])
    }

    /// The PyJWT case: a Python script of the hotel step imports a package that no README
    /// names. check-prerequisites --verify runs no Python, so only the import check sees it.
    func testAPythonPackageOutsideTheStandardLibraryFailsTheCheck() throws {
        try write("scripts/db/check-prerequisites.mjs", "exit 0")
        try write("scripts/setup/remote_supabase.py", "import json\nimport jwt\n")
        try write("scripts/setup/dump-travel-organizations.py", "from remote_supabase import find_remote_config\n")
        try write("scripts/setup/test_dump_travel_organizations.py", "import jwt\n")

        let result = try runCheck()
        XCTAssertNotEqual(result.code, 0)
        XCTAssertTrue(result.output.contains("scripts/setup/remote_supabase.py:2: import jwt"), result.output)
        XCTAssertTrue(result.output.contains("A teammate who followed the README hits this too"), result.output)

        // The check reads the scripts with a stdlib-only python3 and writes no bytecode.
        // A test file is not run by a step, so it does not count.
        let args = try String(contentsOfFile: work.appendingPathComponent("python.txt").path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(args.prefix(3)), ["-s", "-S", "-B"])
        XCTAssertEqual(Set(args.filter { $0.hasSuffix(".py") }.map { URL(fileURLWithPath: $0).lastPathComponent }),
                       ["remote_supabase.py", "dump-travel-organizations.py"])

        // Control: the same Python, called as the caller's shell does, has the package.
        let file = monolith.appendingPathComponent("scripts/setup/remote_supabase.py").path
        let direct = try shell(stubs.appendingPathComponent("python3").path, ["-c", "check", file])
        XCTAssertEqual(direct, 0)
    }

    func testStandardLibraryScriptsPass() throws {
        try write("scripts/db/check-prerequisites.mjs", "exit 0")
        try write("scripts/setup/remote_supabase.py", "import json\n")

        let result = try runCheck()
        XCTAssertEqual(result.code, 0, result.output)
        XCTAssertTrue(result.output.contains("1 Python script imports only the standard library"), result.output)
    }

    /// With no Python script the line does not count files that it did not read.
    func testNoPythonScriptsSaysSo() throws {
        try write("scripts/db/check-prerequisites.mjs", "exit 0")

        let result = try runCheck()
        XCTAssertEqual(result.code, 0, result.output)
        XCTAssertTrue(result.output.contains("✓ no Python scripts to check"), result.output)
        XCTAssertFalse(result.output.contains("0 Python scripts"), result.output)
    }

    func testANodeOlderThanTheNvmrcFails() throws {
        try write("scripts/db/check-prerequisites.mjs", "exit 0")
        try stub("node", #"if [ "$1" = --version ]; then echo v20.11.0; exit 0; fi; exec /bin/bash "$@""#)

        let result = try runCheck()
        XCTAssertNotEqual(result.code, 0)
        XCTAssertTrue(result.output.contains("node is v20.11.0, the monolith's .nvmrc asks for Node 22 or newer"), result.output)
    }

    func testANewerNodePasses() throws {
        try write("scripts/db/check-prerequisites.mjs", "exit 0")
        try stub("node", #"if [ "$1" = --version ]; then echo v25.6.1; exit 0; fi; exec /bin/bash "$@""#)

        let result = try runCheck()
        XCTAssertEqual(result.code, 0, result.output)
    }

    func testAMissingToolAndAMissingInstallSayWhatToDo() throws {
        try write("scripts/db/check-prerequisites.mjs", "exit 0")
        try FileManager.default.removeItem(at: stubs.appendingPathComponent("docker"))
        var result = try runCheck()
        XCTAssertNotEqual(result.code, 0)
        XCTAssertTrue(result.output.contains("docker is not on your PATH"), result.output)

        try stub("docker", "echo 'Docker version 29.0.0'")
        try FileManager.default.removeItem(at: monolith.appendingPathComponent("node_modules"))
        result = try runCheck()
        XCTAssertNotEqual(result.code, 0)
        XCTAssertTrue(result.output.contains("has no node_modules. Run pnpm install there first."), result.output)
    }

    // MARK: - Helpers

    private func write(_ relative: String, _ text: String) throws {
        try text.write(to: monolith.appendingPathComponent(relative), atomically: true, encoding: .utf8)
    }

    private func stub(_ name: String, _ body: String) throws {
        let url = stubs.appendingPathComponent(name)
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runCheck() throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script, monolith.path]
        process.environment = [
            "PATH": "\(stubs.path):/usr/bin:/bin",
            "HOME": work.appendingPathComponent("home").path,
            "TMPDIR": work.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func shell(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
