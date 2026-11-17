import Foundation
import XCTest

/// The fb-travel-monolith files that the contract tests read.
///
/// By default they come from the pinned snapshot in `Tests/Fixtures/monolith-snapshot`,
/// so a test gives the same answer on every Mac and in CI. With `TR_INTEGRATION=1`
/// they come from a real checkout: `TR_MONOLITH_DIR`, or `fb-travel-monolith`
/// beside this repo.
enum MonolithCheckout {
    struct Missing: LocalizedError {
        let path: String
        var errorDescription: String? {
            "TR_INTEGRATION=1 needs an fb-travel-monolith checkout at \(path). Set TR_MONOLITH_DIR to another one."
        }
    }

    static var isIntegration: Bool {
        ProcessInfo.processInfo.environment["TR_INTEGRATION"] == "1"
    }

    /// The root of this repo.
    private static var runnerRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    static var snapshot: URL {
        runnerRoot.appendingPathComponent("Tests/Fixtures/monolith-snapshot")
    }

    /// The snapshot, or the real checkout with `TR_INTEGRATION=1`. A missing
    /// checkout fails the test: an integration run must not pass by reading nothing.
    static func root() throws -> URL {
        guard isIntegration else { return snapshot }
        let environment = ProcessInfo.processInfo.environment
        let checkout = environment["TR_MONOLITH_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? runnerRoot.deletingLastPathComponent().appendingPathComponent("fb-travel-monolith")
        guard FileManager.default.fileExists(atPath: checkout.appendingPathComponent("scripts/db/manifest.json").path) else {
            throw Missing(path: checkout.path)
        }
        return checkout
    }

    /// Skips a test that runs a monolith script, unless `TR_INTEGRATION=1`.
    static func requireIntegration() throws {
        try XCTSkipUnless(isIntegration, "runs a monolith script; set TR_INTEGRATION=1")
    }

    static func file(_ relativePath: String) throws -> URL {
        try root().appendingPathComponent(relativePath)
    }

    static func text(_ relativePath: String) throws -> String {
        try String(contentsOf: file(relativePath), encoding: .utf8)
    }
}
