import Foundation
import XCTest
@testable import TravelRunner

/// The values here are made up, and built from parts so that no secret scanner
/// takes them for real keys.
final class RedactorTests: XCTestCase {
    private let stripeKey = "sk_" + "test_" + "51AbCdEfGhIjKlMnOpQrStUv"
    private let webhookSecret = "whsec_" + "0123456789abcdefABCDEF"
    private let jwt = "eyJhbGciOiJIUzI1NiJ9" + "." + "eyJyb2xlIjoiYW5vbiJ9" + "." + "c2lnbmF0dXJlLXBhcnQ"

    private let patterns = Redactor.patterns

    // MARK: - The cause stays

    /// 5,017 of 30,885 captured lines were "[REDACTED]": the word KEY removed the whole line.
    func testAStripeErrorKeepsItsCode() {
        let line = #"  "code": "api_key_expired", "message": "Expired API Key provided: "# + stripeKey + #"""#
        XCTAssertEqual(
            patterns.redact(line),
            #"  "code": "api_key_expired", "message": "Expired API Key provided: ‹redacted:stripe-key›""#
        )
    }

    func testLinesWithoutASecretAreNotChanged() {
        for line in [
            "Error: listen EADDRINUSE: address already in use :::3002",
            "  code: 'EADDRINUSE',",
            "using api key from the keychain",
            "Invalid API key: check the dashboard",
            "Missing env var STRIPE_SECRET_KEY",
            " GET /api/health 200 in 81ms",
            "- Local:        http://localhost:3006",
            #"{"level":50,"msg":"token refresh failed","module":"auth"}"#,
            "Error while authenticating with Stripe: Authorization failed, status=401",
        ] {
            XCTAssertEqual(patterns.redact(line), line)
        }
    }

    // MARK: - The rules

    func testStripeKeys() {
        XCTAssertEqual(patterns.redact("key \(stripeKey) rejected"), "key ‹redacted:stripe-key› rejected")
        XCTAssertEqual(
            patterns.redact("Ready! Your webhook signing secret is \(webhookSecret) (^C to quit)"),
            "Ready! Your webhook signing secret is ‹redacted:stripe-key› (^C to quit)"
        )
        XCTAssertEqual(patterns.redact("rk_" + "live_" + "abc123"), "‹redacted:stripe-key›")
        XCTAssertEqual(patterns.redact("pk_" + "test_" + "abc123"), "‹redacted:stripe-key›")
    }

    func testJWTs() {
        XCTAssertEqual(patterns.redact("apikey header was \(jwt)."), "apikey header was ‹redacted:jwt›.")
    }

    func testBearerTokens() {
        XCTAssertEqual(
            patterns.redact("Authorization: Bearer abcDEF123456_-xyz failed"),
            "Authorization: Bearer ‹redacted:bearer› failed"
        )
        // The JWT rule runs first, so the kind says what the token was.
        XCTAssertEqual(patterns.redact("authorization: bearer \(jwt)"), "authorization: bearer ‹redacted:jwt›")
        XCTAssertEqual(patterns.redact("Authorization: Basic dXNlcjpwYXNzd29yZA=="), "Authorization: Basic ‹redacted:bearer›")
    }

    func testURLPasswords() {
        XCTAssertEqual(
            patterns.redact("connect ECONNREFUSED postgresql://postgres:hunter2@127.0.0.1:54322/postgres"),
            "connect ECONNREFUSED postgresql://postgres:‹redacted:url-password›@127.0.0.1:54322/postgres"
        )
        XCTAssertEqual(
            patterns.redact("rediss://default:AbC123xyz@host.upstash.io:6379"),
            "rediss://default:‹redacted:url-password›@host.upstash.io:6379"
        )
        for plain in ["http://localhost:3000/users/a@b.co", "http://host:3000?x=a@b", "http://host:3000#a@b"] {
            XCTAssertEqual(patterns.redact(plain), plain)
        }
    }

    /// The rule stopped at the first `@` and left the rest of the password.
    func testAURLPasswordWithAnAtSignIsRemovedWhole() {
        XCTAssertEqual(
            patterns.redact("postgres://user:p@ss:word@host:5432/db"),
            "postgres://user:‹redacted:url-password›@host:5432/db"
        )
    }

    func testKeysWithAKnownPrefix() {
        XCTAssertEqual(patterns.redact("> apikey: sb_" + "secret_AbCdEf123456_xyz"), "> apikey: ‹redacted:supabase-key›")
        XCTAssertEqual(
            patterns.redact("Publishable key: sb_" + "publishable_AbCdEf123456-xyz"),
            "Publishable key: ‹redacted:supabase-key›"
        )
        XCTAssertEqual(
            patterns.redact("remote: bad credentials for gh" + "p_0123456789abcdefABCDEF0123456789abcd"),
            "remote: bad credentials for ‹redacted:github-token›"
        )
    }

    func testAnAuthorizationTokenHeader() {
        XCTAssertEqual(
            patterns.redact("> Authorization: Token 0123456789abcdef0123"),
            "> Authorization: Token ‹redacted:bearer›"
        )
        // The word alone, in prose, is not a header.
        let prose = "token authentication failed"
        XCTAssertEqual(patterns.redact(prose), prose)
    }

    func testAPrivateKeyBlock() {
        let body = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC"
        XCTAssertEqual(
            patterns.redact("-----BEGIN PRIVATE KEY-----\n\(body)\n-----END PRIVATE KEY-----\ndone"),
            "‹redacted:private-key›\ndone"
        )
        XCTAssertEqual(
            patterns.redact(#"key is -----BEGIN RSA PRIVATE KEY-----\n"# + body + #"\n-----END RSA PRIVATE KEY----- ok"#),
            "key is ‹redacted:private-key› ok"
        )
    }

    // MARK: - A bare value after a colon

    /// The whole-line rule removed these. The first version of this redactor let them through.
    func testABareTokenAfterAColonIsRedacted() {
        let hex = "9f8a7b6c5d4e3f2a" + "1b0c9d8e7f6a5b4c"
        XCTAssertEqual(patterns.redact("> x-api-key: \(hex)"), "> x-api-key: ‹redacted:value›")
        XCTAssertEqual(patterns.redact("S3 Secret Key: \(hex)\(hex)"), "S3 Secret Key: ‹redacted:value›")
        XCTAssertEqual(patterns.redact("S3 Access Key: \(hex)"), "S3 Access Key: ‹redacted:value›")
        XCTAssertEqual(
            patterns.redact("JWT secret: super-secret-jwt-token-with-at-least-32-characters-long"),
            "JWT secret: ‹redacted:value›"
        )
        XCTAssertEqual(patterns.redact("password: hunter2hunter2"), "password: ‹redacted:value›")
        // Only the token goes; what follows it stays.
        XCTAssertEqual(patterns.redact("apiKey: \(hex)) was rejected"), "apiKey: ‹redacted:value›) was rejected")
    }

    /// The negative control: after the same names, prose and short words stay.
    func testProseAfterAColonStays() {
        for line in [
            "Invalid API key: check the dashboard",
            "Secret key: missing",
            "password: incorrect",
            "token: undefined",
            "refresh token: expired-or-revoked-by-the-user",
            "apiKey: process.env.HOTEL_API_KEY",
        ] {
            XCTAssertEqual(patterns.redact(line), line)
        }
    }

    func testJSONWithEscapedQuotes() {
        XCTAssertEqual(
            patterns.redact(#"msg="request {\"apiKey\":\"abc123secretvalue99\",\"port\":3002}""#),
            #"msg="request {\"apiKey\":‹redacted:value›,\"port\":3002}""#
        )
        // A quote inside the value does not end it early.
        XCTAssertEqual(patterns.redact(#"{"password":"ab\"cd","port":1}"#), #"{"password":‹redacted:value›,"port":1}"#)
    }

    // MARK: - Names that are not credentials

    /// KEY and TOKEN matched inside any word. Cache and hold keys are what we debug.
    func testCacheKeysAndTokenCountsStay() {
        for line in [
            "cache miss key=capacity:event:4821:crn:12",
            "{ key: 'hold:evt:4821:user:9' }",
            "prompt_tokens=120 completion_tokens=33",
            "monkey=banana keyboard=us",
            "cache_key=capacity:event:4821 holdKey=hold:evt:4821",
            #"{"max_tokens":4096,"redisKey":"capacity:event:4821:crn:12"}"#,
        ] {
            XCTAssertEqual(patterns.redact(line), line)
        }
        // The positive control: the same forms with a credential name.
        XCTAssertEqual(patterns.redact("api key=abc123"), "api key=‹redacted:value›")
        XCTAssertEqual(patterns.redact("{ apiKey: 'abc123' }"), "{ apiKey: ‹redacted:value› }")
        XCTAssertEqual(patterns.redact("refresh_token=abc123"), "refresh_token=‹redacted:value›")
    }

    // MARK: - Long lines

    /// A long run with no spaces took quadratic time: 3 s for 32 KB of base64url.
    /// The copy actions call the redactor on the main actor.
    func testALongLineWithNoSpacesIsFast() {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var seed: UInt64 = 42
        var blob = ""
        for _ in 0..<100_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            blob.append(alphabet[Int(seed >> 58)])
        }
        let dotted = String(repeating: "ab.", count: 33_334)
        let keys = String(repeating: "key-", count: 25_000)
        let urls = String(repeating: "a://b:c", count: 14_000)

        let start = Date()
        XCTAssertEqual(patterns.redact(blob), blob)
        XCTAssertEqual(patterns.redact(dotted), dotted)
        XCTAssertEqual(patterns.redact(keys), keys)
        XCTAssertEqual(patterns.redact(urls), urls)
        XCTAssertEqual(patterns.redact("API_KEY=" + blob + " rejected"), "API_KEY=‹redacted:value› rejected")
        let pairs = String(repeating: "a=", count: 50_000)
        XCTAssertEqual(patterns.redact(pairs), pairs)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "600 KB in all")
    }

    func testAssignmentsToSecretLikeNames() {
        XCTAssertEqual(patterns.redact("DB_PASSWORD=hunter2 rejected"), "DB_PASSWORD=‹redacted:value› rejected")
        XCTAssertEqual(patterns.redact(#"export API_TOKEN="a b c" # note"#), "export API_TOKEN=‹redacted:value› # note")
        XCTAssertEqual(patterns.redact("GET /cb?access_token=abc123&state=5"), "GET /cb?access_token=‹redacted:value›&state=5")
        XCTAssertEqual(patterns.redact(#"{"apiKey":"abc123","port":3002}"#), #"{"apiKey":‹redacted:value›,"port":3002}"#)
        XCTAssertEqual(patterns.redact("  clientSecret: 'abc123',"), "  clientSecret: ‹redacted:value›,")
        // A name that is not secret-like keeps its value.
        XCTAssertEqual(patterns.redact("PORT=3002 NODE_ENV=development"), "PORT=3002 NODE_ENV=development")
    }

    func testAValueIsRedactedOnceWithTheMostExactKind() {
        XCTAssertEqual(
            patterns.redact("STRIPE_WEBHOOK_SECRET=\(webhookSecret)"),
            "STRIPE_WEBHOOK_SECRET=‹redacted:stripe-key›"
        )
        XCTAssertEqual(
            patterns.redact("SUPABASE_SERVICE_ROLE_KEY=\"\(jwt)\""),
            "SUPABASE_SERVICE_ROLE_KEY=\"‹redacted:jwt›\""
        )
    }

    // MARK: - Known values from env files

    func testKnownValuesAreRedactedWhereverTheyAppear() {
        let redactor = Redactor(knownValues: ["opaque-value-0001", "opaque-value-0001-longer"])
        XCTAssertEqual(
            redactor.redact("upstream said: bad credential opaque-value-0001-longer (and opaque-value-0001)"),
            "upstream said: bad credential ‹redacted:env-value› (and ‹redacted:env-value›)"
        )
    }

    func testShortKnownValuesAreIgnored() {
        let redactor = Redactor(knownValues: ["development"])
        XCTAssertEqual(redactor.redact("NODE_ENV is development"), "NODE_ENV is development")
    }

    func testSecretValuesInADotenvFile() {
        let text = """
        # comment
        PORT=3002
        NEXT_PUBLIC_SITE_NAME=a-long-public-name
        HOTEL_API_KEY=hotel-opaque-0001
        export SESSION_SECRET="quoted opaque 0002"
        CRON_TOKEN='single-opaque-0003'
        INLINE_PASSWORD=inline-opaque-0004 # the note
        SHORT_KEY=abc
        TOKEN_URL=https://example.test/oauth/token
        CREDENTIALS_FILE=/Users/someone/creds.json
        SIGNING_KEY='{"kty":"EC","d":"json-opaque-0005","use":"sig"}'
        """
        let values = Set(Redactor.secretValues(inEnv: text))
        XCTAssertEqual(values, [
            "hotel-opaque-0001", "quoted opaque 0002", "single-opaque-0003", "inline-opaque-0004",
            #"{"kty":"EC","d":"json-opaque-0005","use":"sig"}"#, "json-opaque-0005",
        ])
    }

    /// A secret-like word at the start of a name does not make the value a secret.
    /// `travel-booking-portal` went from every path and log line.
    func testAVariableThatNamesAThingKeepsItsValue() {
        let text = """
        SECRET_NAME=travel-booking-portal
        KEY_ALGORITHM=RSASSA_PKCS1_SHA256
        TOKEN_AUDIENCE=authenticated-users
        MONKEY_MODE=a-long-mode-name
        API_KEY_V2=Zx9Qp4Lm7Rt2Vb6N
        HOTEL_API_KEY=plain-words-only
        """
        XCTAssertEqual(Set(Redactor.secretValues(inEnv: text)), ["Zx9Qp4Lm7Rt2Vb6N", "plain-words-only"])
    }

    /// The file holds `\n`; the log holds real lines.
    func testEachLineOfAMultiLineValueIsKnown() {
        let first = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC"
        let second = "BKcwggSjAgEAAoIBAQC7VJTUt9Us8cKj"
        let text = #"SIGNING_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n"# + first + #"\n"# + second
            + #"\nshort\n-----END PRIVATE KEY-----\n""#
        let values = Redactor.secretValues(inEnv: text)
        XCTAssertTrue(values.contains(first) && values.contains(second), "\(values)")
        XCTAssertFalse(values.contains { $0.hasPrefix("-----") && !$0.contains("\\n") }, "\(values)")

        let redactor = Redactor(knownValues: values)
        XCTAssertEqual(redactor.redact("-----BEGIN PRIVATE KEY-----"), "-----BEGIN PRIVATE KEY-----")
        XCTAssertEqual(redactor.redact(first), "‹redacted:env-value›")
        XCTAssertEqual(redactor.redact("  \(second)"), "  ‹redacted:env-value›")
    }

    func testTheRedactorReadsTheEnvFilesOfADirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RedactorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "HOTEL_API_KEY=hotel-opaque-0001\n".write(to: dir.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "CRON_TOKEN=local-opaque-0002\n".write(to: dir.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)

        let redactor = Redactor(
            envDirectories: [dir.path, dir.appendingPathComponent("missing").path],
            environments: [["GATEWAY_TOKEN": "process-opaque-0003", "PORT": "300200000000"]]
        )
        XCTAssertEqual(
            redactor.redact("401 for hotel-opaque-0001, local-opaque-0002, process-opaque-0003 on 300200000000"),
            "401 for ‹redacted:env-value›, ‹redacted:env-value›, ‹redacted:env-value› on 300200000000"
        )
    }

    func testSecretLikeNames() {
        XCTAssertTrue(Redactor.isSecretName("STRIPE_SECRET_KEY"))
        XCTAssertTrue(Redactor.isSecretName("vercelOidcToken"))
        XCTAssertTrue(Redactor.isSecretName("DB_PASSWORD"))
        XCTAssertFalse(Redactor.isSecretName("NEXT_PUBLIC_SITE_URL"))
        XCTAssertFalse(Redactor.isSecretName("PORT"))
        for name in ["x-api-key", "APIKEY", "apikey", "PGPASSWORD", "clientSecret", "S3Key", "KEY"] {
            XCTAssertTrue(Redactor.isSecretName(name), name)
        }
        for name in ["monkey", "keyboard", "prompt_tokens", "KEYCLOAK_URL", "cache_key", "redisKey", "tokenizer"] {
            XCTAssertFalse(Redactor.isSecretName(name), name)
        }
    }
}
