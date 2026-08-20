import Cocoa

/// Application entry point. Builds an `ApplicationRuntime` owning the
/// `AppDelegate` and runs it for the lifetime of the process. `runtime` is
/// kept alive via `withExtendedLifetime` around the (never-returning) call
/// to `run()`, guaranteeing `AppDelegate` — which `NSApplication.delegate`
/// only references weakly — is retained for as long as the app is running.
@MainActor
private func runApp() -> Never {
    let runtime = ApplicationRuntime(delegate: AppDelegate())
    withExtendedLifetime(runtime) {
        runtime.run()
    }
}

runApp()
