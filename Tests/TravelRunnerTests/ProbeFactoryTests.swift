import Foundation
import XCTest
@testable import TravelRunner

/// A probe config with a missing or wrong field gives an error, never a crash.
final class ProbeFactoryTests: XCTestCase {
    private func config(
        _ type: ProbeConfig.ProbeType,
        port: Int? = nil,
        host: String? = nil,
        url: String? = nil,
        pattern: String? = nil
    ) -> ProbeConfig {
        ProbeConfig(type: type, port: port, host: host, url: url, pattern: pattern, artifact: nil, timeout: nil)
    }

    private func assertThrows(_ config: ProbeConfig, _ reason: String, line: UInt = #line) {
        XCTAssertEqual(config.problem, reason, line: line)
        XCTAssertThrowsError(try ProbeFactory.makeProbe(for: config), line: line) { error in
            XCTAssertEqual(error as? ProbeConfigError, ProbeConfigError(reason: reason), line: line)
        }
    }

    func testATcpProbeNeedsAPort() {
        assertThrows(config(.tcp), "probe type tcp needs a port (1–65535)")
        assertThrows(config(.tcp, port: 0), "probe type tcp needs a port (1–65535)")
        assertThrows(config(.tcp, port: -5), "probe type tcp needs a port (1–65535)")
        assertThrows(config(.tcp, port: 65536), "probe type tcp needs a port (1–65535)")
    }

    func testAnHttpProbeNeedsAUrlOrAPort() {
        assertThrows(config(.http), "probe type http needs a url or a port (1–65535)")
        assertThrows(config(.http, url: ""), "probe type http needs an http or https url")
        assertThrows(config(.http, url: "ftp://localhost/health"), "probe type http needs an http or https url")
        assertThrows(config(.http, port: 99999), "probe port 99999 is not a port (1–65535)")
        assertThrows(
            config(.http, port: 99999, url: "http://127.0.0.1:3000/health"), "probe port 99999 is not a port (1–65535)"
        )
    }

    func testAStdoutProbeNeedsAPatternThatCompiles() {
        assertThrows(config(.stdoutRegex), "probe type stdout_regex needs a pattern")
        assertThrows(config(.stdoutRegex, pattern: ""), "probe type stdout_regex needs a pattern")
        assertThrows(
            config(.stdoutRegex, pattern: "ready ["),
            "probe type stdout_regex needs a pattern that is a valid regular expression"
        )
        XCTAssertThrowsError(try StdoutProbe(pattern: "ready ["))
        XCTAssertThrowsError(try StdoutProbe(pattern: ""))
    }

    func testGoodConfigsMakeTheirProbe() throws {
        let tcp = try XCTUnwrap(ProbeFactory.makeProbe(for: config(.tcp, port: 4100, host: "0.0.0.0")) as? TcpProbe)
        XCTAssertEqual(tcp.port, 4100)
        XCTAssertEqual(tcp.host, "0.0.0.0")
        let local = try XCTUnwrap(ProbeFactory.makeProbe(for: config(.tcp, port: 4100)) as? TcpProbe)
        XCTAssertEqual(local.host, "127.0.0.1")

        let fromPort = try XCTUnwrap(ProbeFactory.makeProbe(for: config(.http, port: 4100)) as? HttpProbe)
        XCTAssertEqual(fromPort.url, "http://127.0.0.1:4100/health")
        let fromURL = try XCTUnwrap(
            ProbeFactory.makeProbe(for: config(.http, port: 4100, url: "http://127.0.0.1:4100/api/health")) as? HttpProbe
        )
        XCTAssertEqual(fromURL.url, "http://127.0.0.1:4100/api/health")

        let stdout = try XCTUnwrap(
            ProbeFactory.makeProbe(for: config(.stdoutRegex, pattern: "ready in \\d+ms")) as? StdoutProbe
        )
        XCTAssertEqual(stdout.feed(line: "app ready in 120ms"), "ready in 120ms")
    }

    /// The probes of the built-in services must pass the same check as custom ones.
    func testEveryCatalogProbeIsValid() {
        let paths = RepoPaths(monorepo: "/work/fb-travel-monolith", universalLogin: "/work/login",
                              streamServices: "/work/stream", loadTest: "/work/load")
        for service in ServiceCatalog.services(paths: paths) {
            XCTAssertNil(service.probe?.problem, service.id)
        }
    }

    /// A TcpProbe that is built by hand with a number that is not a port fails its
    /// check. It opens no connection.
    func testATcpProbeWithANumberThatIsNotAPortFails() async {
        for port in [-1, 0, 65536, 1 << 40] {
            let passed = await TcpProbe(port: port).check()
            XCTAssertFalse(passed, "\(port)")
        }
    }
}
