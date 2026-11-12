import SwiftUI
import WebKit

/// The Rooms tab: which rooms are booked, held or free, for the local stack or
/// for dev. The page is the monolith's holds viewer (`scripts/holds-viewer`).
/// It is read-only: it cannot change Redis or a database.
struct WorkshopRoomsView: View {
    @Environment(EnvironmentSupervisor.self) var supervisor

    var body: some View {
        let host = supervisor.holdsViewer
        VStack(spacing: 0) {
            header(host)
            Divider()
            content(host)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { host.tabAppeared() }
        .onDisappear { host.tabDisappeared() }
    }

    private func header(_ host: HoldsViewerHost) -> some View {
        HStack(spacing: 10) {
            Text("Rooms and holds")
                .font(.headline)
            Text("read-only")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15), in: Capsule())
            if let copy = host.copy {
                Text("Viewer from \(copy.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(copy.directory)
            }
            Spacer()
            if case .running(let port) = host.state {
                Button("Open in Browser") {
                    NSWorkspace.shared.open(host.browserURL(port: port))
                }
                .controlSize(.small)
            }
            Button {
                Task { await host.restart() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help("Start the viewer again")
            .disabled(host.state == .starting)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func content(_ host: HoldsViewerHost) -> some View {
        switch host.state {
        case .running(let port):
            RoomsWebView(url: host.pageURL(port: port)) { query in
                host.lastQuery = query
            }
        case .starting, .stopped:
            VStack(spacing: 10) {
                ProgressView()
                Text("Starting the holds viewer…")
                    .foregroundStyle(.secondary)
            }
        case .unavailable(.noMonorepo):
            message(
                "The monolith is not set up",
                "\(Flavor.current.displayName) does not know where \(Flavor.current.monorepoName) is. Open Settings, then Reconfigure Repos."
            )
        case .unavailable(.noViewer):
            message(
                "The holds viewer is not available yet",
                """
                The viewer is in the monolith at scripts/holds-viewer. Your checkout does not have it, and origin/dev does not have it.

                The tab starts to work when the viewer is on dev and this Mac has fetched it. To use a copy from another folder now:
                defaults write \(Flavor.current.bundleID) \(HoldsViewerHost.overrideDefaultsKey) /path/to/scripts/holds-viewer
                """
            )
        case .unavailable(.nodeNotFound):
            message(
                "Node was not found",
                "The holds viewer needs Node 22 or later in your login shell (zsh -l). The portals need it too."
            )
        case .failed(let reason):
            message("The holds viewer stopped", reason)
        }
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "bed.double")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 520)
            Button("Try Again") {
                Task { await supervisor.holdsViewer.restart() }
            }
            .controlSize(.small)
        }
        .padding(24)
    }
}

/// The viewer's page. Only the viewer's own address loads in the tab; any other
/// link opens in the browser.
struct RoomsWebView: NSViewRepresentable {
    let url: URL
    /// The query of the page after each change (source, view, event, hotel).
    let onQueryChange: (String) -> Void

    enum LinkPolicy: Equatable {
        /// The viewer's own address: load it in the tab.
        case load
        /// Another web address: open it in the browser, not in the tab.
        case openInBrowser
        case refuse
    }

    /// What the tab does with a link. Only the viewer (same host and port) loads in the tab.
    static func policy(for url: URL, viewer: URL) -> LinkPolicy {
        if url.scheme == "about" { return .load }
        if url.scheme == viewer.scheme, url.host == viewer.host, url.port == viewer.port { return .load }
        if url.scheme == "http" || url.scheme == "https" { return .openInBrowser }
        return .refuse
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(origin: url, onQueryChange: onQueryChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing of the page stays on disk.
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .windowBackgroundColor
        context.coordinator.observe(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // A new port means a new viewer process.
        guard webView.url?.port != url.port else { return }
        context.coordinator.origin = url
        webView.load(URLRequest(url: url))
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
        webView.stopLoading()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var origin: URL
        private let onQueryChange: (String) -> Void
        private var observation: NSKeyValueObservation?

        init(origin: URL, onQueryChange: @escaping (String) -> Void) {
            self.origin = origin
            self.onQueryChange = onQueryChange
        }

        /// The page keeps its state in the query (`history.replaceState`), so the
        /// tab can come back to the same source, event and hotel.
        func observe(_ webView: WKWebView) {
            observation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                guard let self, let url = webView.url, RoomsWebView.policy(for: url, viewer: self.origin) == .load,
                      let query = url.query, !query.isEmpty else { return }
                DispatchQueue.main.async { self.onQueryChange(query) }
            }
        }

        func stopObserving() {
            observation = nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
            switch RoomsWebView.policy(for: url, viewer: origin) {
            case .load:
                decisionHandler(.allow)
            case .openInBrowser:
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            case .refuse:
                decisionHandler(.cancel)
            }
        }
    }
}
