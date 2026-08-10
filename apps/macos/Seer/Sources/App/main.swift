import Cocoa

/// Application entry point. Constructs the shared `NSApplication`, installs
/// `AppDelegate`, forces an accessory (menu-bar-only, no Dock icon) activation
/// policy — matching the Glaze host's `appConfig.macOS.activationPolicy`
/// setting in `package.json` — and runs the main event loop.
@MainActor
private func runApp() -> Never {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
    // `NSApplication.run()` blocks until the app terminates but is not
    // itself typed as `Never`; this is unreachable in practice.
    fatalError("NSApplication.run() returned unexpectedly")
}

runApp()
