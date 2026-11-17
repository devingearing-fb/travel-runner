import AppKit

/// One copy of the app runs at a time, and a release copy belongs in /Applications.
///
/// Two copies of one app (an old download and the installed one, or a source build
/// and a release) use the same control port, the same config and the same service
/// ports. The second copy says so and quits. The other app (`Flavor.sibling`) is not
/// a second copy: it has its own bundle ID, and `SiblingRunner` handles it.
enum InstanceGuard {
    /// One running copy of this app.
    struct Copy: Equatable, Sendable {
        let pid: pid_t
        /// When the process started. `nil` only when neither the kernel nor the system knows.
        let launchDate: Date?
        /// The path of the app bundle.
        let path: String?
        /// CFBundleShortVersionString of that bundle.
        let version: String?
    }

    // MARK: - The running copy

    /// The copy that ran before this one. `nil` when this copy is the first.
    /// Two copies that start together must not both quit, so only the later one yields:
    /// the later start, or the higher pid when the dates do not decide.
    static func runningCopy(own: Copy, all: [Copy]) -> Copy? {
        all.filter { $0.pid != own.pid && ranFirst($0, before: own) }
            .min { ranFirst($0, before: $1) }
    }

    private static func ranFirst(_ a: Copy, before b: Copy) -> Bool {
        if let aDate = a.launchDate, let bDate = b.launchDate, aDate != bDate { return aDate < bDate }
        return a.pid < b.pid
    }

    /// "Travel Runner is already running from /Applications/TravelRunner.app (v0.13.5)."
    static func title(for copy: Copy, flavor: Flavor = .current, home: String = NSHomeDirectory()) -> String {
        var text = "\(flavor.displayName) is already running"
        if let path = copy.path { text += " from \(displayPath(path, home: home))" }
        if let version = copy.version { text += " (v\(version))" }
        return text + "."
    }

    static let detail = "Two copies fight over the same ports and config."
    static let showButton = "Show the running copy"
    static let quitButton = "Quit"

    // MARK: - A launch that nobody watches

    /// The release smoke test sets this (plan item T1). Nobody is there to answer an alert.
    static let smokeKey = "TRAVEL_RUNNER_SMOKE"
    /// The exit code of a smoke launch that found a running copy (EX_TEMPFAIL: try again later).
    static let smokeExitCode: Int32 = 75

    /// A smoke launch must not wait on an alert: it prints the message and exits.
    static func skipsAlert(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[smokeKey] == "1"
    }

    /// The two lines as one text.
    static func message(for copy: Copy, flavor: Flavor = .current, home: String = NSHomeDirectory()) -> String {
        "\(title(for: copy, flavor: flavor, home: home)) \(detail)"
    }

    // MARK: - A release copy outside /Applications

    /// The banner for a release copy that is not in an Applications folder.
    struct MisplacedNotice: Equatable, Sendable {
        let text: String
        let advice: String
        /// The bundle to show in Finder. `nil` when macOS runs the copy from a temporary folder.
        let revealPath: String?
        /// What the dismissal stores, so each stray place gets the banner once.
        let place: String
    }

    /// The places whose banner the person closed.
    static let dismissedPlacesKey = "misplacedCopyNoticeDismissed_v1"

    /// `/Applications` or `~/Applications`, or a folder in one of them.
    static func isInApplications(_ bundlePath: String, home: String = NSHomeDirectory()) -> Bool {
        let path = (bundlePath as NSString).standardizingPath
        return ["/Applications/", "\(home)/Applications/"].contains { path.hasPrefix($0) }
    }

    /// macOS runs a downloaded app that nobody moved from a random read-only folder.
    static func isTranslocated(_ bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }

    /// The banner for this copy, or `nil`: a dev build, a copy in Applications, or a
    /// banner that the person closed before. A dev build runs from its build folder.
    static func misplacedNotice(
        bundlePath: String,
        build: BuildInfo,
        home: String = NSHomeDirectory(),
        defaults: UserDefaults
    ) -> MisplacedNotice? {
        guard !build.isDev, !isInApplications(bundlePath, home: home) else { return nil }
        let name = build.flavor.displayName
        let advice = "Quit \(name), move it to Applications in Finder, then open it there."
        let notice: MisplacedNotice
        if isTranslocated(bundlePath) {
            notice = MisplacedNotice(
                text: "macOS runs this copy of \(name) from a temporary folder, so it cannot update itself.",
                advice: advice,
                revealPath: nil,
                place: "translocated"
            )
        } else {
            let path = (bundlePath as NSString).standardizingPath
            notice = MisplacedNotice(
                text: "This copy of \(name) runs from \(displayPath(path, home: home)), not from /Applications. "
                    + "Copies in other folders get old and start by mistake.",
                advice: advice,
                revealPath: path,
                place: path
            )
        }
        let dismissed = defaults.stringArray(forKey: dismissedPlacesKey) ?? []
        return dismissed.contains(notice.place) ? nil : notice
    }

    /// The person closed the banner. It does not come back for this place.
    static func dismiss(_ notice: MisplacedNotice, defaults: UserDefaults) {
        var dismissed = defaults.stringArray(forKey: dismissedPlacesKey) ?? []
        guard !dismissed.contains(notice.place) else { return }
        dismissed.append(notice.place)
        defaults.set(dismissed, forKey: dismissedPlacesKey)
    }

    /// The home folder as `~`.
    static func displayPath(_ path: String, home: String) -> String {
        guard !home.isEmpty, path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - This Mac

    /// The copy of this app that ran first, from the list of running apps.
    /// `nil` without a bundle ID (`swift run`): the system cannot find such copies.
    @MainActor
    static func runningCopyNow() -> (copy: Copy, app: NSRunningApplication)? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let own = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        let copies = others.map(copy(of:))
        guard let first = runningCopy(own: copy(of: own), all: copies),
              let app = others.first(where: { $0.processIdentifier == first.pid }) else { return nil }
        return (first, app)
    }

    /// When the kernel started the process. `NSRunningApplication.launchDate` is `nil`
    /// for a copy that someone ran from a shell, and then the pid would decide. Pids
    /// start again from a low number, so both copies could stay.
    static func processStart(of pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
        )
    }

    private static func copy(of app: NSRunningApplication) -> Copy {
        // Read the file: `Bundle` keeps the first Info.plist it saw for a path.
        let info = app.bundleURL
            .map { $0.appendingPathComponent("Contents/Info.plist") }
            .flatMap { NSDictionary(contentsOf: $0) as? [String: Any] }
        return Copy(
            pid: app.processIdentifier,
            launchDate: processStart(of: app.processIdentifier) ?? app.launchDate,
            path: app.bundleURL?.path,
            version: BuildInfo.resolve(info: info, flavor: .current).version
        )
    }

    /// The request to show the window, for one process. It is the event that a second
    /// launch from Finder sends (`applicationShouldHandleReopen`).
    static func reopenEvent(pid: pid_t) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    /// Ask that process to show its window. `false` when it did not take the request.
    @MainActor
    private static func show(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated else { return false }
        do {
            let reply = try reopenEvent(pid: app.processIdentifier).sendEvent(options: [.waitForReply], timeout: 2)
            if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 { return false }
        } catch {
            return false
        }
        app.activate(options: [.activateAllWindows])
        return true
    }

    /// Tell the person, then return. The caller quits. Returns after the running copy
    /// got the request to show its window, when the person asked for that.
    @MainActor
    static func refuse(_ running: (copy: Copy, app: NSRunningApplication), then quit: @escaping @MainActor @Sendable () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title(for: running.copy)
        alert.informativeText = detail
        alert.addButton(withTitle: showButton)
        alert.addButton(withTitle: quitButton)
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else {
            quit()
            return
        }
        // The app has no Dock icon, so only a reopen shows its window. The request goes
        // to the process, not to the bundle path: two copies can run from one path, and
        // the system could then give the request to this copy.
        if show(running.app) {
            quit()
            return
        }
        // The process did not take the request. Opening a running app sends a reopen too.
        guard let url = running.app.bundleURL else {
            quit()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            Task { @MainActor in quit() }
        }
    }
}
