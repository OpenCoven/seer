import XCTest
@testable import Seer

/// `NSApplication.delegate` is a `weak` property. Without a separate strong
/// owner, `AppDelegate` could be deallocated while `NSApplication.run()` is
/// still executing, silently dropping the delegate mid-run.
/// `ApplicationRuntime` exists solely to be that strong owner, kept alive by
/// `withExtendedLifetime` around `run()`. These tests assert the ownership
/// contract directly, without driving an actual `NSApplication` event loop.
@MainActor
final class ApplicationRuntimeTests: XCTestCase {
    func testRuntimeHoldsAppDelegateStrongly() {
        weak var weakDelegate: AppDelegate?
        var runtime: ApplicationRuntime?

        autoreleasepool {
            let delegate = AppDelegate()
            weakDelegate = delegate
            runtime = ApplicationRuntime(delegate: delegate)
        }

        // The delegate must still be alive here: only `runtime` (still in
        // scope) holds a strong reference to it, since the local `delegate`
        // variable that created it has gone out of scope.
        XCTAssertNotNil(weakDelegate, "ApplicationRuntime should keep AppDelegate alive")
        XCTAssertTrue(runtime?.delegate === weakDelegate)
    }

    func testDelegateDeallocatesOnlyAfterRuntimeIsReleased() {
        weak var weakDelegate: AppDelegate?
        var runtime: ApplicationRuntime?

        autoreleasepool {
            let delegate = AppDelegate()
            weakDelegate = delegate
            runtime = ApplicationRuntime(delegate: delegate)
        }

        XCTAssertNotNil(weakDelegate)

        runtime = nil

        XCTAssertNil(weakDelegate, "AppDelegate should deallocate once its sole strong owner (ApplicationRuntime) is released")
    }
}
