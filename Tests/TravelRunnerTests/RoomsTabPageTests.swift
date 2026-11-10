import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import TravelRunner

/// The Rooms tab with a real web view and a small stand-in for the viewer.
@MainActor
final class RoomsTabPageTests: XCTestCase {
    private var root: URL!
    private var host: HoldsViewerHost!

    /// Serves one page. The page changes its query, as the real page does when a
    /// person picks a source, a view, an event or a hotel.
    private static let stubServer = """
    import http from "node:http";
    const args = process.argv.slice(2);
    const port = Number(args[args.indexOf("--port") + 1]);
    const page = `<!doctype html><title>stub viewer</title><p id="q"></p><script>
      document.getElementById("q").textContent = location.search;
      history.replaceState(null, "", "?env=dev&view=holds&event=7&embed=1");
    </script>`;
    http.createServer((req, res) => {
      if (req.url.startsWith("/api/envs")) { res.writeHead(200, { "Content-Type": "application/json" }); return res.end("{}"); }
      res.writeHead(200, { "Content-Type": "text/html" });
      res.end(page);
    }).listen(port, "127.0.0.1");
    """

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoomsTabPageTests-\(UUID().uuidString)")
        let viewer = root.appendingPathComponent("repo/\(HoldsViewerLocator.relativePath)")
        try FileManager.default.createDirectory(at: viewer, withIntermediateDirectories: true)
        try Self.stubServer.write(to: viewer.appendingPathComponent("server.mjs"), atomically: true, encoding: .utf8)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RoomsTabPageTests-\(UUID().uuidString)"))
        host = HoldsViewerHost(cacheRoot: root.appendingPathComponent("cache").path, defaults: defaults)
        let repo = root.appendingPathComponent("repo").path
        host.monorepo = { repo }
    }

    override func tearDown() async throws {
        await host.stop()
        try? FileManager.default.removeItem(at: root)
    }

    private func findWebView(in view: NSView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for sub in view.subviews {
            if let found = findWebView(in: sub) { return found }
        }
        return nil
    }

    func testThePageOfTheViewerLoadsInTheTabAndTheTabKeepsItsQuery() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RoomsTabPageTests-supervisor-\(UUID().uuidString)"))
        let supervisor = EnvironmentSupervisor(userDefaults: defaults, holdsViewer: host)
        let hosting = NSHostingView(rootView: WorkshopRoomsView().environment(supervisor))
        // Off the screen: the test must not put a window in front of a person.
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }

        var webView: WKWebView?
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            webView = findWebView(in: hosting)
            if let webView, webView.title == "stub viewer", host.lastQuery == "env=dev&view=holds&event=7&embed=1" { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        guard case .running(let port) = host.state else { return XCTFail("the viewer is \(host.state)") }
        let page = try XCTUnwrap(webView, "no web view in the tab")
        XCTAssertEqual(page.title, "stub viewer")
        XCTAssertEqual(page.url?.port, port)
        // The page loaded with the start query of the tab.
        let shown = try await page.evaluateJavaScript("document.getElementById('q').textContent") as? String
        XCTAssertEqual(shown, "?env=local&view=rooms&embed=1")
        // The tab keeps what the page changed, for the next time it opens.
        XCTAssertEqual(host.lastQuery, "env=dev&view=holds&event=7&embed=1")
        XCTAssertEqual(host.pageURL(port: port).query, "env=dev&view=holds&event=7&embed=1")
    }

    func testOnlyTheViewerLoadsInTheTab() throws {
        let viewer = try XCTUnwrap(URL(string: "http://127.0.0.1:5123/?embed=1"))
        let policy = { (text: String) in RoomsWebView.policy(for: URL(string: text)!, viewer: viewer) }
        XCTAssertEqual(policy("http://127.0.0.1:5123/?env=dev"), .load)
        XCTAssertEqual(policy("http://127.0.0.1:5123/api/rooms?env=local"), .load)
        XCTAssertEqual(policy("about:blank"), .load)
        // Another port on this Mac is another program (a portal, the control API).
        XCTAssertEqual(policy("http://127.0.0.1:3002/hub"), .openInBrowser)
        XCTAssertEqual(policy("http://localhost:5123/"), .openInBrowser)
        XCTAssertEqual(policy("https://example.com/"), .openInBrowser)
        XCTAssertEqual(policy("file:///etc/passwd"), .refuse)
        XCTAssertEqual(policy("javascript:alert(1)"), .refuse)
    }
}
