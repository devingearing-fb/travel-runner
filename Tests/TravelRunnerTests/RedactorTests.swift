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
        let plain = "http://localhost:3000/users/a@b.co"
        XCTAssertEqual(patterns.redact(plain), plain)
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
    }
}
