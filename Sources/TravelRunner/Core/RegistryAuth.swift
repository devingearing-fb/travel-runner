import Foundation

/// The token of GitHub Packages, which serves the @fastbreak-amateur packages.
/// The check reads the token from the user config of npm and pnpm and asks
/// GitHub Packages whether it can read a package with it.
///
/// The file is the source of truth. `pnpm config get` cannot read the token:
/// pnpm 10 hands the call to npm, which refuses a protected auth key.
struct RegistryAuth: Sendable {
    /// The user config when a test gives one. Nil: `$NPM_CONFIG_USERCONFIG`, else `~/.npmrc`.
    let npmrcOverride: String?
    let home: String
    /// The session of the test request. Tests give one with a stub protocol.
    let session: URLSession

    init(npmrcPath: String? = nil, home: String = NSHomeDirectory(),
         session: URLSession = RegistryAuth.defaultSession) {
        self.npmrcOverride = npmrcPath
        self.home = home
        self.session = session
    }

    /// The user config that npm and pnpm read: `$NPM_CONFIG_USERCONFIG` of the
    /// user's shell when it is set, else `~/.npmrc`.
    func npmrcPath(variables: [String: String]) -> String {
        if let npmrcOverride { return npmrcOverride }
        if let value = variables["NPM_CONFIG_USERCONFIG"], !value.isEmpty {
            return (value as NSString).expandingTildeInPath
        }
        return (home as NSString).appendingPathComponent(".npmrc")
    }

    nonisolated static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    /// The key of the token in an `.npmrc`.
    nonisolated static let tokenKey = "//npm.pkg.github.com/:_authToken"
    /// A package of the org. A token that can read it can install the monorepo.
    nonisolated static let testURL = URL(string: "https://npm.pkg.github.com/@fastbreak-amateur%2Ffb-toolkit")!

    /// What the check reads, as a command the user can run: the last token line of the user config.
    nonisolated static let readCommand =
        "grep '^\(tokenKey)=' \"${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}\" | tail -1"

    /// Prints the token of the GitHub CLI login.
    nonisolated static let ghTokenCommand = "gh auth token"

    // MARK: - Reading the token

    /// The token of an `.npmrc`, or nil when the file sets none. When the key is
    /// there twice, the last line wins, as it does for npm and pnpm.
    nonisolated static func token(fromNpmrc content: String) -> String? {
        guard var value = content.components(separatedBy: .newlines).compactMap(valueOfTokenLine).last else {
            return nil
        }
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// The token of the file, or nil when there is no file or no token.
    nonisolated static func token(atPath path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8)).flatMap(token(fromNpmrc:))
    }

    /// The text after `=` when the line sets the token, else nil.
    nonisolated static func valueOfTokenLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(tokenKey) else { return nil }
        let rest = trimmed.dropFirst(tokenKey.count).trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("=") else { return nil }
        return rest.dropFirst().trimmingCharacters(in: .whitespaces)
    }

    /// The name of the environment variable when the config sets the token as `${NAME}`.
    nonisolated static func environmentReference(_ token: String) -> String? {
        guard token.hasPrefix("${"), token.hasSuffix("}"), token.count > 3 else { return nil }
        return String(token.dropFirst(2).dropLast())
    }

    // MARK: - Testing the token

    /// What GitHub Packages said to the token.
    enum Outcome: Equatable, Sendable {
        case noToken
        /// The config takes the token from this environment variable, which the app cannot see.
        case fromEnvironment(String)
        case http(Int)
        /// No answer: offline, DNS or a timeout.
        case unreachable(String)
    }

    nonisolated static let noTokenText = "No token for npm.pkg.github.com in your user config — use Set token"
    nonisolated static let rejectedText = "Token expired or revoked."
    nonisolated static let lacksAccessText = "Token lacks read:packages or org SSO is not authorised."

    /// The row of the check for an outcome. Offline only warns: the token may be fine.
    nonisolated static func status(_ outcome: Outcome) -> CheckStatus {
        switch outcome {
        case .noToken:
            return .failing(noTokenText)
        case .fromEnvironment(let name):
            return .warning("The token comes from $\(name), which Travel Runner cannot read — it was not tested")
        case .http(let code) where (200..<300).contains(code):
            return .passing("Token works")
        case .http(401):
            return .failing(rejectedText)
        case .http(403), .http(404):
            return .failing(lacksAccessText)
        case .http(let code):
            return .warning("GitHub Packages answered HTTP \(code) — the token was not tested")
        case .unreachable(let reason):
            return .warning("GitHub Packages did not answer (\(reason)) — the token was not tested. Check the network, then re-check")
        }
    }

    /// True when GitHub Packages refused the token. The fix does not save such a token.
    nonisolated static func isRejection(_ outcome: Outcome) -> Bool {
        if case .http(let code) = outcome { return [401, 403, 404].contains(code) }
        return false
    }

    /// Asks GitHub Packages for a package of the org with the token.
    func test(token: String) async -> Outcome {
        var request = URLRequest(url: Self.testURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unreachable("no HTTP answer") }
            return .http(http.statusCode)
        } catch let error as URLError {
            return .unreachable(Self.reason(error))
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    nonisolated static func reason(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost: "offline"
        case .timedOut: "timed out"
        case .cannotFindHost, .dnsLookupFailed: "the name did not resolve"
        case .cannotConnectToHost: "connection refused"
        default: "error \(error.code.rawValue)"
        }
    }

    // MARK: - Saving the token

    /// Sets the token in the `.npmrc`: it replaces the last line of the token, or adds one.
    /// It removes the earlier token lines, so that no old token is left. Other lines stay as they are.
    nonisolated static func settingToken(_ token: String, in content: String) -> String {
        var lines = content.isEmpty ? [] : content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let line = "\(tokenKey)=\(token)"
        if let index = lines.lastIndex(where: { valueOfTokenLine($0) != nil }) {
            lines[index] = line
            lines = lines.enumerated()
                .filter { $0.offset == index || valueOfTokenLine($0.element) == nil }
                .map(\.element)
        } else {
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the token to the user config at `path`, after a copy of the file. The
    /// token never goes on a command line: the app writes the file itself. When the
    /// config is a link (a dotfile manager), the app writes the file it points to.
    /// Returns the name of the copy, or nil when there was no file.
    func save(token: String, toPath path: String, now: Date) throws -> String? {
        let fileManager = FileManager.default
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let exists = fileManager.fileExists(atPath: target.path)
        let content = exists ? try String(contentsOf: target, encoding: .utf8) : ""
        let backup = exists ? try BackupCopy.make(of: path, now: now, permissions: 0o600) : nil
        try Data(Self.settingToken(token, in: content).utf8).write(to: target, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return backup
    }
}

/// A copy of a file next to it, `<file>.bak-<timestamp>`, before a fix changes the file.
enum BackupCopy {
    /// Copies the file and returns the name of the copy. When `path` is a link, the
    /// copy holds the content of the file it points to. `permissions` sets the mode of the copy.
    nonisolated static func make(of path: String, now: Date, permissions: Int? = nil) throws -> String {
        let fileManager = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(path).bak-\(formatter.string(from: now))"
        var target = base
        var counter = 2
        while fileManager.fileExists(atPath: target) {
            target = "\(base)-\(counter)"
            counter += 1
        }
        let source = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        try fileManager.copyItem(atPath: source, toPath: target)
        if let permissions {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target)
        }
        return (target as NSString).lastPathComponent
    }
}
