import Foundation

/// What the fix button of a setup check does.
enum FixAction: Equatable, Sendable {
    /// Runs a command. The fix sheet shows its output while it runs.
    case command(String, timeout: Duration)
    /// Opens Terminal with a command that asks questions (`stripe login`), then runs
    /// the check again until it passes or `waitFor` is over.
    case terminal(command: String, waitFor: Duration)
    /// Asks for a file that a teammate sent and copies it into place.
    case importFile
    /// The app does the work itself; the sheet lists what it changed.
    case inApp
    /// Opens another app, then runs the check again until it passes or `waitFor` is over.
    case navigate(app: String, waitFor: Duration)
    /// Says what to do. The runner runs nothing. `linkTitle` names the link to `url`;
    /// without one the link shows the URL.
    case guidance(text: String, copyCommand: String?, url: URL?, linkTitle: String? = nil)
    /// Asks for the GitHub Packages token in a secure field, tests it, and saves it.
    case enterToken

    /// What "Copy command" copies, or nil.
    var copyCommand: String? {
        switch self {
        case .command(let command, _): command
        case .terminal(let command, _): command
        case .navigate(let app, _): "open -a \(ShellQuote.quote(app))"
        case .guidance(_, let command, _, _): command
        case .importFile, .inApp, .enterToken: nil
        }
    }

    /// An import shows its own file panel and the token its own sheet; every other fix shows the fix sheet.
    var showsSheet: Bool { self != .importFile && self != .enterToken }
}

/// One run of a fix: the lines that the fix sheet shows, and how it ended.
@Observable
@MainActor
final class FixRun: Identifiable {
    enum State: Equatable, Sendable {
        case running
        case succeeded
        /// The text that the row of the check shows too.
        case failed(String)
        case cancelled
        /// A guidance fix: there is nothing to run.
        case guidance
    }

    nonisolated let id = UUID()
    nonisolated let checkID: String
    nonisolated let checkName: String
    nonisolated let action: FixAction
    nonisolated let startedAt: Date
    private(set) var endedAt: Date?
    private(set) var state: State
    private(set) var lines: [String] = []
    /// The work of the fix. Cancel stops it, and the command with its child processes.
    var task: Task<State, Never>?

    /// The sheet keeps this many lines.
    nonisolated static let maxLines = 5000
    /// On failure the sheet shows this many of the last lines.
    nonisolated static let failureTailCount = 30

    init(checkID: String, checkName: String, action: FixAction, startedAt: Date, state: State = .running) {
        self.checkID = checkID
        self.checkName = checkName
        self.action = action
        self.startedAt = startedAt
        self.state = state
        if state == .guidance, case .guidance(let text, _, _, _) = action { lines = [text] }
    }

    var isRunning: Bool { state == .running }

    /// The last lines, for the failure view.
    var failureTail: [String] { Array(lines.suffix(Self.failureTailCount)) }

    func append(_ line: String) {
        lines.append(TerminalLineBuffer.stripAnsiEscapes(line))
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    func finish(_ state: State, at date: Date) {
        guard isRunning else { return }
        self.state = state
        endedAt = date
    }

    func cancel() {
        task?.cancel()
    }

    /// "0:42", or "12:05" for twelve minutes.
    nonisolated static func elapsedText(seconds: Int) -> String {
        let seconds = max(0, seconds)
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

/// Why the token sheet did not save a token. The sheet shows the text.
struct RegistryTokenError: Error, Equatable, Sendable {
    let text: String
    init(_ text: String) { self.text = text }
}
