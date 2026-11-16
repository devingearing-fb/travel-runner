import Foundation

/// Removes credentials from text that leaves the app: issue folders, `/api/logs`,
/// copied logs and the diagnostic bundle.
///
/// It replaces the secret value only. The rest of the line stays, so the cause
/// of a failure is still readable: `"code": "api_key_expired"` is kept.
/// Each match becomes `‹redacted:kind›`.
struct Redactor: Sendable {
    /// Exact secret values, the longest first.
    private let knownValues: [String]

    /// The pattern rules alone, with no values from env files.
    static let patterns = Redactor(knownValues: [])

    init(knownValues: [String]) {
        self.knownValues = Array(Set(knownValues.filter { $0.count >= Self.minimumKnownLength }))
            .sorted { ($0.count, $0) > ($1.count, $1) }
    }

    /// Reads the secret values from the env files in each directory.
    /// A file that is missing or unreadable adds nothing.
    init(envDirectories: [String], environments: [[String: String]] = []) {
        var values: [String] = []
        for directory in Set(envDirectories) {
            for name in Self.envFileNames {
                let path = (directory as NSString).appendingPathComponent(name)
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                values += Self.secretValues(inEnv: text)
            }
        }
        for environment in environments {
            for (name, value) in environment where Self.isSecretName(name) {
                values += Self.usableValues(value)
            }
        }
        self.init(knownValues: values)
    }

    static func marker(_ kind: String) -> String { "‹redacted:\(kind)›" }

    // MARK: - Redaction

    /// The rules run in this order:
    /// 1. exact values from the env files, 2. Stripe keys, 3. JWTs,
    /// 4. `Bearer <token>`, 5. URL passwords, 6. `NAME=value` for secret-like names.
    func redact(_ text: String) -> String {
        var out = text
        for value in knownValues where out.contains(value) {
            out = out.replacingOccurrences(of: value, with: Self.marker("env-value"))
        }
        for rule in Self.rules {
            let range = NSRange(out.startIndex..., in: out)
            out = rule.regex.stringByReplacingMatches(in: out, range: range, withTemplate: rule.template)
        }
        return out
    }

    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) {
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }
    }

    private static let nameTokens = ["SECRET", "KEY", "TOKEN", "PASSWORD", "PASSWD", "CREDENTIAL"]

    private static let rules: [Rule] = {
        let tokens = nameTokens.joined(separator: "|")
        let name = "[A-Za-z0-9_.-]*(?:\(tokens))[A-Za-z0-9_-]*"
        // A value that an earlier rule replaced is left as it is.
        let notRedacted = "(?![\"']?‹redacted:)"
        return [
            Rule(#"\b(?:sk|rk|pk)_(?:test|live)_[A-Za-z0-9]+"#, marker("stripe-key")),
            Rule(#"\bwhsec_[A-Za-z0-9]+"#, marker("stripe-key")),
            Rule(#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, marker("jwt")),
            Rule(#"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 " + marker("bearer"), options: [.caseInsensitive]),
            Rule(#"\b([a-z][a-z0-9+.-]*://[^\s/:@]+):[^\s/@]+@"#, "$1:" + marker("url-password") + "@", options: [.caseInsensitive]),
            // NAME=value, quoted or bare.
            Rule(
                "(?<![A-Za-z0-9_])(\(name)[\"']?\\s*=\\s*)\(notRedacted)(?:\"[^\"]*\"|'[^']*'|[^\\s&,;\"']+)",
                "$1" + marker("value"),
                options: [.caseInsensitive]
            ),
            // "name": "value" as JSON and Node print it. Only a quoted value, so prose
            // such as "Invalid API key: check the dashboard" stays.
            Rule(
                "(?<![A-Za-z0-9_])(\(name)[\"']?\\s*:\\s*)\(notRedacted)(?:\"[^\"]*\"|'[^']*')",
                "$1" + marker("value"),
                options: [.caseInsensitive]
            ),
        ]
    }()

    // MARK: - Env files

    /// The env files a service can read in its folder.
    static let envFileNames = [
        ".env", ".env.local", ".env.development", ".env.development.local", ".env.dev", ".env.remote",
    ]

    /// A shorter value is too likely to match ordinary text.
    static let minimumKnownLength = 12

    /// True for a name that can hold a credential, such as `STRIPE_SECRET_KEY`.
    static func isSecretName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return nameTokens.contains { upper.contains($0) }
    }

    /// The values of the secret-like names in the text of one dotenv file.
    static func secretValues(inEnv text: String) -> [String] {
        var values: [String] = []
        for line in text.components(separatedBy: .newlines) {
            guard let key = RunnerEnv.assignedKey(line), isSecretName(key),
                  let eq = line.firstIndex(of: "=") else { continue }
            var raw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let quote = raw.first, quote == "\"" || quote == "'" {
                raw.removeFirst()
                if let end = raw.lastIndex(of: quote) { raw = String(raw[..<end]) }
            } else if let comment = raw.range(of: " #") {
                raw = raw[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            values += usableValues(raw)
        }
        return values
    }

    /// The value, and the strings inside it when it is JSON (a signing key, say).
    /// A path or a URL is not a secret; rule 5 covers a password in a URL.
    private static func usableValues(_ value: String) -> [String] {
        guard value.count >= minimumKnownLength else { return [] }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.contains("://") { return [] }
        var values = [value]
        if value.hasPrefix("{"), let data = value.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            values += strings(in: json).filter { $0.count >= minimumKnownLength }
        }
        return values
    }

    private static func strings(in json: Any) -> [String] {
        switch json {
        case let string as String: [string]
        case let array as [Any]: array.flatMap(strings(in:))
        case let object as [String: Any]: object.values.flatMap(strings(in:))
        default: []
        }
    }
}
