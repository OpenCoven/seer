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

/// Owns the strong reference to `AppDelegate` for the entire duration of
/// `NSApplication.run()`. `NSApplication.delegate` is a `weak` property, so
/// assigning `application.delegate = AppDelegate()` with no other strong
/// reference to the delegate would leave it eligible for deallocation at any
/// point during the run loop. Callers must keep the `ApplicationRuntime`
/// itself alive — e.g. via `withExtendedLifetime` — around the call to
/// `run()`.
@MainActor
final class ApplicationRuntime {
    let delegate: AppDelegate

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }

    /// Configures `application` to use `delegate`, forces an accessory
    /// (menu-bar-only, no Dock icon) activation policy — matching the Glaze
    /// host's `appConfig.macOS.activationPolicy` setting in `package.json` —
    /// and runs the main event loop.
    func run(application: NSApplication = .shared) -> Never {
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        // `NSApplication.run()` blocks until the app terminates but is not
        // itself typed as `Never`; this is unreachable in practice.
        fatalError("NSApplication.run() returned unexpectedly")
    }
}
