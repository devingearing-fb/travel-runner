import Foundation
import XCTest
@testable import TravelRunner

/// Each row of the failure table: the words and the button for one failure.
final class FailureAdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        // A probe of another test can leave its runtime behind.
        ContainerRuntime.forgetProbed()
    }

    private func portal(
        log: [String] = [], likelyCause: String? = nil, canClearCache: Bool = true
    ) -> FailureAdvisor.Context {
        FailureAdvisor.Context(
            name: "Booking Portal", port: 3002, probePath: "/api/health", logTail: log,
            likelyCause: likelyCause, canClearCache: canClearCache, runtime: "OrbStack"
        )
    }

    private func advise(_ kind: FailureAdvisor.Kind, _ context: FailureAdvisor.Context) -> ServiceCondition {
        FailureAdvisor.advise(kind, context, now: now)
    }

    /// A failed install before the start offers the install again, not a restart.
    func testAFailedInstallOffersTheInstall() {
        let text = "Booking Portal cannot start: its packages are not installed and pnpm install --frozen-lockfile failed (exit 1) — see its log"
        let condition = advise(.installFailed(text), portal())
        XCTAssertEqual(condition.headline, text)
        XCTAssertEqual(condition.actions, [.installDependencies, .openLog])
        // Negative control: a plain message gets Restart.
        XCTAssertEqual(advise(.message(text), portal()).actions, [.openLog, .restart])
    }

    /// The install runs with --frozen-lockfile. A lockfile that does not match a
    /// package.json says how to fix it; other failures point to the log.
    func testAnOutdatedLockfileSaysHowToFixIt() {
        let outdated = CommandResult(
            exitCode: 1, stdout: "",
            stderr: " ERR_PNPM_OUTDATED_LOCKFILE  Cannot install with \"frozen-lockfile\" because pnpm-lock.yaml is not up to date with apps/web/package.json"
        )
        XCTAssertEqual(
            EnvironmentSupervisor.installFailure(outdated, folder: "/repo"),
            "failed: the lockfile does not match package.json — run pnpm install in /repo"
        )
        XCTAssertEqual(
            EnvironmentSupervisor.installFailure(CommandResult(exitCode: 1, stdout: "", stderr: "ERR! network"), folder: "/repo"),
            "failed (exit 1) — see its log"
        )
    }

    func testAProbeTimeoutWithTheProcessAliveSaysItMayStillCompile() {
        let condition = advise(.probeTimeout(seconds: 240, processAlive: true, lastProbe: .refused), portal())
        XCTAssertEqual(condition.headline, "Booking Portal did not answer on port 3002 within 240s.")
        XCTAssertEqual(
            condition.detail,
            "The process is still running — it may still be compiling. Last check: connection refused."
        )
        XCTAssertEqual(condition.actions, [.openLog, .clearCacheAndRestart])
        XCTAssertEqual(condition.kind, .failed)
        XCTAssertEqual(condition.since, now)

        // Negative control: a service without a cache gets Restart instead.
        let other = advise(
            .probeTimeout(seconds: 240, processAlive: true, lastProbe: nil), portal(canClearCache: false)
        )
        XCTAssertEqual(other.actions, [.openLog, .restart])
        XCTAssertEqual(other.detail, "The process is still running — it may still be compiling.")
    }

    func testAProbeThatGetsA404AsksWhetherTheBranchHasTheRoute() {
        let condition = advise(.probeTimeout(seconds: 240, processAlive: true, lastProbe: .http(status: 404)), portal())
        XCTAssertEqual(condition.text, "Booking Portal answers with HTTP 404 at /api/health. Does this branch have that route?")
        XCTAssertEqual(condition.actions, [.openLog])

        // A 404 on the route and a 500 on / names both; the 500 is the error to read.
        let broken = advise(
            .probeTimeout(seconds: 240, processAlive: true, lastProbe: .notFoundThenRoot(.http(status: 500))), portal()
        )
        XCTAssertEqual(broken.text, "Booking Portal answers with HTTP 404 at /api/health and HTTP 500 at /. See its log for the error.")
        XCTAssertEqual(broken.actions, [.openLog, .clearCacheAndRestart])

        // Negative controls: another status, or a process that has ended.
        let error500 = advise(.probeTimeout(seconds: 240, processAlive: true, lastProbe: .http(status: 500)), portal())
        XCTAssertEqual(error500.headline, "Booking Portal did not answer on port 3002 within 240s.")
        let ended = advise(.probeTimeout(seconds: 240, processAlive: false, lastProbe: .http(status: 404)), portal())
        XCTAssertFalse(ended.text.contains("HTTP 404"), ended.text)
    }

    func testEaddrinuseSaysThePortIsTaken() {
        let log = ["Error: listen EADDRINUSE: address already in use :::3002", "    at Server.setupListenHandle"]
        let condition = advise(.exited(code: 1), portal(log: log, likelyCause: log[0]))
        XCTAssertEqual(condition.headline, "Port 3002 is already in use by another process.")
        XCTAssertEqual(condition.actions, [.stopForeignAndRetry(port: 3002)])
        XCTAssertEqual(RecoveryAction.stopForeignAndRetry(port: 3002).title(), "Free port and restart")

        // The line names the port that is taken, also when it is not the probe port.
        let hmr = advise(
            .exited(code: 1), portal(log: ["12:00:01 Error: listen EADDRINUSE: address already in use 127.0.0.1:24678"])
        )
        XCTAssertEqual(hmr.headline, "Port 24678 is already in use by another process.")
        // The button frees the port that the line names, not the probe port.
        XCTAssertEqual(hmr.actions, [.stopForeignAndRetry(port: 24678)])
    }

    func testADownContainerRuntimeNamesTheApp() {
        let log = ["Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"]
        let condition = advise(.exited(code: 1), portal(log: log))
        XCTAssertEqual(condition.headline, "OrbStack is not running.")
        XCTAssertEqual(condition.actions, [.openContainerRuntime])
        XCTAssertEqual(RecoveryAction.openContainerRuntime.title(runtime: "OrbStack"), "Open OrbStack")

        let halted = advise(.runtimeDown(waiting: true), portal())
        XCTAssertEqual(halted.headline, "OrbStack is not running — waiting for it.")
        XCTAssertEqual(halted.detail, "Booking Portal starts when it is back.")
        XCTAssertEqual(halted.kind, .halted(reason: "runtime down"))
        XCTAssertEqual(halted.actions, [.openContainerRuntime])

        // After 10 minutes the row stops saying that it waits.
        let gaveUp = advise(.runtimeDown(waiting: false), portal())
        XCTAssertEqual(gaveUp.text, "OrbStack is not running. Open it, then restart Booking Portal.")
        XCTAssertEqual(gaveUp.actions, [.openContainerRuntime])
    }

    /// Kills from outside are not a crash loop: the row says that something else
    /// stops the service, and a SIGKILL adds the memory hint.
    func testRepeatedKillsSaySomethingElseStopsTheService() {
        let killed = advise(.killedRepeatedly(signal: SIGKILL, times: 3), portal())
        XCTAssertEqual(killed.headline, "Something else keeps stopping Booking Portal (SIGKILL 3 times).")
        XCTAssertEqual(killed.detail, ServiceTermination.memoryHint)
        XCTAssertEqual(killed.kind, .halted(reason: "killed repeatedly"))
        XCTAssertEqual(killed.actions, [.restart, .openLog])

        let terminated = advise(.killedRepeatedly(signal: SIGTERM, times: 3), portal())
        XCTAssertEqual(terminated.text, "Something else keeps stopping Booking Portal (SIGTERM 3 times).")
    }

    /// Exit 137 is SIGKILL: often macOS when memory runs low. A SIGTERM has no hint.
    func testASigkillAddsTheMemoryHint() {
        let oom = advise(.killed(signal: SIGKILL), portal())
        XCTAssertEqual(oom.headline, "Booking Portal was stopped from outside Travel Runner (SIGKILL).")
        XCTAssertEqual(oom.detail, ServiceTermination.memoryHint)
        XCTAssertNil(advise(.killed(signal: SIGTERM), portal()).detail)
    }

    func testAMissingModuleOffersAnInstall() {
        for line in ["Error: Cannot find module 'next/dist/bin/next'", "Module not found: Can't resolve 'zod'"] {
            let condition = advise(.exited(code: 1), portal(log: [line]))
            XCTAssertEqual(condition.headline, "A package is missing — dependencies are out of date.", line)
            XCTAssertEqual(condition.actions, [.installDependencies], line)
        }
        XCTAssertEqual(RecoveryAction.installDependencies.title(), "Install dependencies")
    }

    func testTheBreakerSaysItStoppedAndWhy() {
        let condition = advise(.crashLoop, portal(likelyCause: "TypeError: x is not a function"))
        XCTAssertEqual(
            condition.text, "Booking Portal failed 3 times in a minute: TypeError: x is not a function."
        )
        XCTAssertEqual(condition.kind, .halted(reason: "crash loop"))
        XCTAssertEqual(condition.action, .restart)

        // A cause with one fix in the log is the cause of the loop.
        let busy = advise(.crashLoop, portal(log: ["Error: listen EADDRINUSE: address already in use :::3002"]))
        XCTAssertEqual(busy.headline, "Booking Portal failed 3 times in a minute: Port 3002 is already in use by another process.")

        let unknown = advise(.crashLoop, portal())
        XCTAssertEqual(unknown.text, "Booking Portal failed 3 times in a minute: no clear cause in the log.")

        let exhausted = advise(.exhausted(restarts: 5), portal())
        XCTAssertEqual(exhausted.headline, "Booking Portal did not come back after 5 restarts.")
        XCTAssertEqual(exhausted.kind, .halted(reason: "exhausted"))
    }

    func testAnExitWithNoCauseSaysSo() {
        let condition = advise(.exited(code: 1), portal(log: ["compiled successfully"]))
        XCTAssertEqual(condition.text, "Booking Portal exited with code 1. No clear cause in the last 120 lines.")
        XCTAssertEqual(condition.actions, [.openLog])

        // Negative control: a cause line from the log is shown.
        let known = advise(.exited(code: 1), portal(likelyCause: "TypeError: x is not a function"))
        XCTAssertEqual(known.text, "Booking Portal exited with code 1. Cause: TypeError: x is not a function.")
        XCTAssertEqual(known.actions, [.openLog, .restart])
    }

    func testOtherKindsKeepTheirOwnWords() {
        let message = advise(.message("Booking Portal cannot start: the shell could not run pnpm (exit 127)."), portal())
        XCTAssertEqual(message.headline, "Booking Portal cannot start: the shell could not run pnpm (exit 127).")
        XCTAssertNil(message.detail)

        let killed = advise(.killed(signal: SIGTERM), portal())
        XCTAssertEqual(killed.headline, "Booking Portal was stopped from outside Travel Runner (SIGTERM).")

        let clean = advise(.cleanExit, portal())
        XCTAssertEqual(clean.headline, "Booking Portal exited (code 0) — not restarted.")

        let wake = advise(.wakeCheck(lastProbe: .timedOut), portal())
        XCTAssertEqual(wake.text, "Booking Portal did not answer after the Mac woke up. Last check: no answer in time.")
    }

    /// A line of the log from earlier in the launch (a page that did not compile, a
    /// port that was taken once) does not explain a kill or a failed wake check.
    func testAKillOrAWakeFailureKeepsItsOwnHeadlineWhateverTheLogSays() {
        let logs = [
            ["Module not found: Can't resolve './x'"],
            ["Error: listen EADDRINUSE: address already in use :::24678"],
            ["Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?"],
        ]
        for log in logs {
            let context = portal(log: log, likelyCause: log[0])
            let killed = advise(.killed(signal: SIGTERM), context)
            XCTAssertEqual(killed.headline, "Booking Portal was stopped from outside Travel Runner (SIGTERM).", log[0])
            XCTAssertEqual(killed.actions, [.restart, .openLog], log[0])
            let wake = advise(.wakeCheck(lastProbe: .timedOut), context)
            XCTAssertEqual(wake.headline, "Booking Portal did not answer after the Mac woke up.", log[0])
            XCTAssertEqual(wake.actions, [.restart, .openLog], log[0])
            // Negative control: the same log explains an exit.
            XCTAssertNotEqual(advise(.exited(code: 1), context).actions, [.openLog], log[0])
        }
    }

    func testOnlyTheLogOfTheWindowCounts() {
        let old = ["Error: Cannot find module 'x'"] + Array(repeating: "ok", count: FailureAdvisor.logWindow)
        let condition = advise(.exited(code: 1), portal(log: old))
        XCTAssertEqual(condition.text, "Booking Portal exited with code 1. No clear cause in the last 120 lines.")
    }

    /// The Help list comes from the table: each row says what the service row
    /// says, and names a button.
    func testTheHelpListComesFromTheTable() {
        let now = Date(timeIntervalSince1970: 0)
        let entries = FailureAdvisor.helpEntries(runtime: "OrbStack", now: now)
        XCTAssertEqual(Set(entries.map(\.situation)).count, entries.count, "one row per situation")
        for entry in entries {
            XCTAssertFalse(entry.headline.isEmpty, entry.situation)
            XCTAssertFalse(entry.buttons.isEmpty, entry.situation)
        }
        let port = entries.first { $0.situation == "A port is taken" }
        XCTAssertEqual(port?.headline, "Port 3002 is already in use by another process.")
        XCTAssertEqual(port?.buttons, ["Free port and restart"])
        let loop = FailureAdvisor.advise(
            .crashLoop, .init(name: "Booking Portal", port: 3002, probePath: "/api/health", canClearCache: true, runtime: "OrbStack"),
            now: now
        )
        XCTAssertEqual(entries.first { $0.situation == "It crashes again and again" }?.headline, loop.headline)
    }
}
