import SwiftUI

@main
struct TravelRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scenes — the app is entirely driven by the
        // NSStatusItem + NSPanel created in AppDelegate.
        Settings { EmptyView() }
    }
}
