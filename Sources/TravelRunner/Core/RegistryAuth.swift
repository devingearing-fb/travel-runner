import Foundation

/// The token of GitHub Packages, which serves the @fastbreak-amateur packages.
/// The check reads the token from the user config of pnpm and asks GitHub
/// Packages whether it can read a package with it.
struct RegistryAuth: Sendable {
    /// The user config of pnpm and npm (`--location=user`).
    let npmrcPath: String
    /// The session of the test request. Tests give one with a stub protocol.
    let session: URLSession

    init(npmrcPath: String = (NSHomeDirectory() as NSString).appendingPathComponent(".npmrc"),
         session: URLSession = RegistryAuth.defaultSession) {
        self.npmrcPath = npmrcPath
        self.session = session
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

    /// Prints the token of the user config. pnpm prints "undefined" when there is none.
    nonisolated static let readCommand =
        "COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm config get --location=user '\(tokenKey)'"

    /// Prints the token of the GitHub CLI login.
    nonisolated static let ghTokenCommand = "gh auth token"

    // MARK: - Reading the token

    /// The token in the output of `pnpm config get`, or nil when none is set.
    nonisolated static func token(fromConfigGet output: String) -> String? {
        let value = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? ""
        return ["", "undefined", "null", "(protected)"].contains(value) ? nil : value
    }

    /// The token of an `.npmrc`, or nil when the file sets none.
    nonisolated static func token(fromNpmrc content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            guard let rest = valueOfTokenLine(line) else { continue }
            var value = rest
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
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

    /// Sets the token in the `.npmrc`: it replaces the line of the token, or adds one.
    /// Other lines stay as they are.
    nonisolated static func settingToken(_ token: String, in content: String) -> String {
        var lines = content.isEmpty ? [] : content.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let line = "\(tokenKey)=\(token)"
        if let index = lines.firstIndex(where: { valueOfTokenLine($0) != nil }) {
            lines[index] = line
        } else {
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the token to the user config, after a copy of the file. The token
    /// never goes on a command line: the app writes the file itself.
    /// Returns the name of the copy, or nil when there was no file.
    func save(token: String, now: Date) throws -> String? {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: npmrcPath)
        let content = exists ? try String(contentsOfFile: npmrcPath, encoding: .utf8) : ""
        let backup = exists ? try BackupCopy.make(of: npmrcPath, now: now) : nil
        try Data(Self.settingToken(token, in: content).utf8).write(to: URL(fileURLWithPath: npmrcPath), options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: npmrcPath)
        return backup
    }
}

/// A copy of a file next to it, `<file>.bak-<timestamp>`, before a fix changes the file.
enum BackupCopy {
    /// Copies the file and returns the name of the copy.
    nonisolated static func make(of path: String, now: Date) throws -> String {
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
        try fileManager.copyItem(atPath: path, toPath: target)
        return (target as NSString).lastPathComponent
    }
}
