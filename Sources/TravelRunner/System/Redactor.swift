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
            for (name, value) in environment {
                values += Self.knownValues(name: name, value: value)
            }
        }
        self.init(knownValues: values)
    }

    static func marker(_ kind: String) -> String { "‹redacted:\(kind)›" }

    // MARK: - Redaction

    /// The rules run in this order:
    /// 1. exact values from the env files, 2. keys with a known prefix (Stripe,
    /// Supabase, GitHub), 3. JWTs, 4. `Bearer <token>`, 5. URL passwords,
    /// 6. private key blocks, 7. the value after a secret-like name (`NAME=value`,
    /// `"name": "value"`, `name: <token>`).
    ///
    /// Each rule takes time in proportion to the length of the text. A log line
    /// has no length limit, and the copy actions run on the main actor.
    func redact(_ text: String) -> String {
        var out = text
        for value in knownValues where out.contains(value) {
            out = out.replacingOccurrences(of: value, with: Self.marker("env-value"))
        }
        for rule in Self.rules {
            let range = NSRange(out.startIndex..., in: out)
            out = rule.regex.stringByReplacingMatches(in: out, range: range, withTemplate: rule.template)
        }
        return Self.redactNamedValues(in: out)
    }

    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let template: String

        init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) {
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }
    }

    private static let rules: [Rule] = [
        Rule(#"\b(?:sk|rk|pk)_(?:test|live)_[A-Za-z0-9]+"#, marker("stripe-key")),
        Rule(#"\bwhsec_[A-Za-z0-9]+"#, marker("stripe-key")),
        Rule(#"\bsb_(?:secret|publishable)_[A-Za-z0-9_-]+"#, marker("supabase-key")),
        Rule(#"\b(?:gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,})"#, marker("github-token")),
        Rule(#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#, marker("jwt")),
        Rule(#"\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 " + marker("bearer"), options: [.caseInsensitive]),
        // `Authorization: Token <token>`. The word "token" alone is too common in prose.
        Rule(
            #"\b(Authorization\\?["']?[ \t]*[:=][ \t]*\\?["']?Token)[ \t]+[A-Za-z0-9._~+/=-]{8,}"#,
            "$1 " + marker("bearer"),
            options: [.caseInsensitive]
        ),
        // The password ends at the last `@` before the host, so a raw `@` in it does
        // not leak the rest. A `/`, `?` or `#` ends the search: `host:3000?x=a@b` has
        // no password. The lengths have a limit so that a long line stays cheap.
        Rule(
            #"\b([a-z][a-z0-9+.-]{0,20}://[^\s/:@?#]{1,128}):[^\s/?#]{1,256}@"#,
            "$1:" + marker("url-password") + "@",
            options: [.caseInsensitive]
        ),
        Rule(
            #"-----BEGIN [A-Z ]{0,40}PRIVATE KEY-----.*?-----END [A-Z ]{0,40}PRIVATE KEY-----"#,
            marker("private-key"),
            options: [.dotMatchesLineSeparators]
        ),
    ]

    // MARK: - The value after a name

    /// A name and a `=` or `:`. Group 1 is the name, 2 the separator. The quote
    /// after the name can be escaped (`\"`), as in JSON inside a log message.
    ///
    /// The name is one whole run of name characters, 80 at most, and it is not
    /// tried again from inside the run. A 100 KB line with no spaces costs one pass.
    private static let namePattern = try! NSRegularExpression(pattern:
        #"(?<![A-Za-z0-9_.-])([A-Za-z0-9_.-]{1,80}+)(?![A-Za-z0-9_.-])\\?["']?[ \t]*([=:])[ \t]*"#
    )

    /// The value after the separator: quoted, quoted with escaped quotes, or bare.
    /// It is read only after a secret-like name, so each character is read once.
    /// A value that an earlier rule replaced is left as it is.
    private static let valuePattern = try! NSRegularExpression(pattern:
        #"(?!\\?["']?‹redacted:)(?:\\"[^"\\]*+\\"|"(?:[^"\\]++|\\.)*+"|'[^']*+'|[^\s&,;"']++)"#
    )

    /// The characters of a token. A bare value after a colon is redacted only when
    /// it starts with a run of these that is this long and holds a digit, so prose
    /// such as "Invalid API key: check the dashboard" stays.
    private static let tokenCharacters = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_+/=.-"
    )
    static let minimumTokenLength = 12

    private static func redactNamedValues(in text: String) -> String {
        let source = text as NSString
        let names = namePattern.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !names.isEmpty else { return text }
        var replaced: [NSRange] = []
        var valueEnd = 0
        for match in names {
            let nameRange = match.range(at: 1)
            // A name inside the value of the name before it.
            guard nameRange.location >= valueEnd else { continue }
            let name = source.substring(with: nameRange)
            guard isSecretName(name) else { continue }
            if name.lowercased() == "key", !keyOwners.contains(wordBefore(nameRange.location, in: source)) {
                continue
            }
            let rest = NSRange(location: NSMaxRange(match.range), length: source.length - NSMaxRange(match.range))
            guard var valueRange = valuePattern.firstMatch(in: text, options: [.anchored], range: rest)?.range else {
                continue
            }
            valueEnd = NSMaxRange(valueRange)
            let value = source.substring(with: valueRange)
            let quoted = value.hasPrefix("\"") || value.hasPrefix("'") || value.hasPrefix("\\\"")
            if source.substring(with: match.range(at: 2)) == ":", !quoted {
                let token = value.unicodeScalars.prefix { tokenCharacters.contains($0) }
                guard token.count >= minimumTokenLength,
                      token.contains(where: { CharacterSet.decimalDigits.contains($0) }) else { continue }
                // The token characters are ASCII: one UTF-16 unit each.
                valueRange.length = token.count
            }
            replaced.append(valueRange)
        }
        guard !replaced.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for range in replaced.reversed() {
            out.replaceCharacters(in: range, with: marker("value"))
        }
        return out as String
    }

    /// The word before a position, when one space stands between them:
    /// "secret" for the `key` in "Secret key: …". Lowercase; empty when there is none.
    private static func wordBefore(_ location: Int, in source: NSString) -> String {
        let start = max(0, location - 24)
        let before = source.substring(with: NSRange(location: start, length: location - start))
        guard before.hasSuffix(" ") else { return "" }
        let letters = before.dropLast().reversed().prefix { $0.isASCII && $0.isLetter }
        return String(letters.reversed()).lowercased()
    }

    /// The words that make a bare `key` a credential: "Secret key: …", "API key: …".
    /// Without one, `key=capacity:event:4821` is a cache key and stays.
    private static let keyOwners: Set<String> = ["secret", "api", "access", "private", "signing", "encryption"]

    // MARK: - Secret-like names

    /// A part with one of these in it makes a name secret-like.
    private static let secretWords = ["secret", "password", "passwd", "credential"]
    /// `key` and `token` count only as a whole part: `API_KEY`, `apiKey`, `x-api-key`.
    /// `monkey`, `keyboard` and `prompt_tokens` are not credentials.
    private static let secretParts: Set<String> = [
        "key", "token", "apikey", "authtoken", "accesskey", "accesstoken", "privatekey",
    ]
    /// A `key` after one of these is the key of a store, not a credential: `cache_key`.
    private static let storeWords: Set<String> = [
        "cache", "redis", "hold", "lock", "primary", "foreign", "sort", "partition",
    ]

    /// True for a name that can hold a credential, such as `STRIPE_SECRET_KEY`.
    static func isSecretName(_ name: String) -> Bool {
        let parts = nameParts(name)
        return parts.indices.contains { isSecretPart(parts, at: $0) }
    }

    /// True when the last part of the name is the secret-like one: `HOTEL_API_KEY`,
    /// not `KEY_ALGORITHM`.
    static func endsInSecretPart(_ name: String) -> Bool {
        let parts = nameParts(name)
        return !parts.isEmpty && isSecretPart(parts, at: parts.count - 1)
    }

    private static func isSecretPart(_ parts: [String], at index: Int) -> Bool {
        let part = parts[index]
        if secretWords.contains(where: part.contains) { return true }
        guard secretParts.contains(part) else { return false }
        return !(part == "key" && index > 0 && storeWords.contains(parts[index - 1]))
    }

    /// The lowercase parts of a name: `STRIPE_SECRET_KEY`, `x-api-key` and
    /// `vercelOidcToken` have three parts each.
    static func nameParts(_ name: String) -> [String] {
        var parts: [String] = []
        var current = ""
        let characters = Array(name)
        for (index, character) in characters.enumerated() {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { parts.append(current); current = "" }
                continue
            }
            if character.isUppercase, let previous = current.last {
                let beforeLowercase = index + 1 < characters.count && characters[index + 1].isLowercase
                if previous.isLowercase || previous.isNumber || (previous.isUppercase && beforeLowercase) {
                    parts.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { parts.append(current) }
        return parts.map { $0.lowercased() }
    }

    // MARK: - Env files

    /// The env files a service can read in its folder.
    static let envFileNames = [
        ".env", ".env.local", ".env.development", ".env.development.local", ".env.dev", ".env.remote",
    ]

    /// A shorter value is too likely to match ordinary text.
    static let minimumKnownLength = 12

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
            values += knownValues(name: key, value: raw)
        }
        return values
    }

    /// The strings to redact for one variable; none when the name is not secret-like.
    /// `SECRET_NAME=travel-booking-portal` and `KEY_ALGORITHM=RSASSA_PKCS1_SHA256`
    /// name a thing. Their values are in paths and log lines, so they stay.
    static func knownValues(name: String, value: String) -> [String] {
        guard isSecretName(name) else { return [] }
        let values = usableValues(value)
        return endsInSecretPart(name) ? values : values.filter { !looksLikeAName($0) }
    }

    /// True for plain words of one case joined by `-`, `_` or `.`.
    private static func looksLikeAName(_ value: String) -> Bool {
        guard value == value.lowercased() || value == value.uppercased() else { return false }
        let words = value.split(omittingEmptySubsequences: false) { $0 == "-" || $0 == "_" || $0 == "." }
        return words.allSatisfy { word in
            // A word with a digit is short (`sha256`, `v2`); a long one is a token.
            let limit = word.contains(where: \.isNumber) ? 12 : 24
            return (1...limit).contains(word.count) && word.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    /// The value, the strings inside it when it is JSON (a signing key, say), and
    /// its lines when it has more than one.
    /// A path or a URL is not a secret; rule 5 covers a password in a URL.
    private static func usableValues(_ value: String) -> [String] {
        guard value.count >= minimumKnownLength else { return [] }
        if value.hasPrefix("/") || value.hasPrefix("~") || value.contains("://") { return [] }
        var values = [value]
        // A quoted multi-line value (a PEM key) has `\n` in the file and real
        // newlines in a log. Each of its lines is a value. The BEGIN and END
        // lines are not secret.
        if value.contains("\\n") {
            values += value.components(separatedBy: "\\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count >= minimumKnownLength && !$0.hasPrefix("-----") }
        }
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
