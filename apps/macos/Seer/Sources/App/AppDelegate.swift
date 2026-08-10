import Cocoa

/// Root application delegate. No services are wired up yet — this is the
/// lifecycle skeleton that later tasks attach agent monitoring, history, and
/// update-checking services to.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Seer is a menu-bar-only accessory app with no primary window, so it
    /// must never be terminated just because its (nonexistent) last window
    /// closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
