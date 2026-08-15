import XCTest
@testable import Seer

@MainActor
final class PanelControllerTests: XCTestCase {
    private func makeController(clock: MutableClock) -> PanelController {
        PanelController(rendererRoot: SeerRendererRoot(url: URL(fileURLWithPath: "/nonexistent/PanelControllerTests-Renderer")), clock: clock)
    }

    // MARK: - Geometry

    func testPanelCentersBelowTrayAndClampsToVisibleFrame() {
        let origin = PanelGeometry.origin(
            tray: CGRect(x: 990, y: 780, width: 22, height: 22),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            panelSize: CGSize(width: 340, height: 440)
        )
        XCTAssertEqual(origin.x, 652)
        XCTAssertGreaterThanOrEqual(origin.y, 8)
    }

    func testPanelCentersHorizontallyWhenThereIsRoom() {
        let origin = PanelGeometry.origin(
            tray: CGRect(x: 480, y: 780, width: 22, height: 22),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            panelSize: CGSize(width: 340, height: 440)
        )
        // Tray midX = 491; centered origin.x = 491 - 170 = 321.
        XCTAssertEqual(origin.x, 321)
    }

    func testPanelClampsToLeftMargin() {
        let origin = PanelGeometry.origin(
            tray: CGRect(x: 4, y: 780, width: 22, height: 22),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            panelSize: CGSize(width: 340, height: 440)
        )
        XCTAssertEqual(origin.x, 8)
    }

    func testPanelFallsBackAboveTrayWhenBelowDoesNotFit() {
        // Tray near the very bottom of the screen: placing the panel below
        // it would push its origin below the visible frame entirely, so
        // the panel should instead be placed above the tray.
        let tray = CGRect(x: 100, y: 4, width: 22, height: 22)
        let origin = PanelGeometry.origin(
            tray: tray,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            panelSize: CGSize(width: 340, height: 440)
        )
        XCTAssertEqual(origin.y, tray.maxY + PanelGeometry.defaultGap)
    }

    func testPanelClampsVerticallyWhenScreenIsShorterThanPanel() {
        // A screen shorter than the panel itself: neither "below" nor
        // "above" placement fits cleanly, so the result must still respect
        // the bottom margin rather than escaping the visible frame below
        // it — the panel legitimately extends past the top in this
        // degenerate case, since it is taller than the screen itself.
        let origin = PanelGeometry.origin(
            tray: CGRect(x: 100, y: 100, width: 22, height: 22),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 300),
            panelSize: CGSize(width: 340, height: 440)
        )
        XCTAssertEqual(origin.y, 8)
    }

    // MARK: - Panel window shape

    func testPanelHasExpectedFixedSize() {
        let controller = makeController(clock: MutableClock(now: 0))
        XCTAssertEqual(controller.panel.frame.size, PanelController.panelSize)
        XCTAssertEqual(PanelController.panelSize, CGSize(width: 340, height: 440))
        XCTAssertEqual(PanelController.minimumHeight, 280)
    }

    func testPanelIsNonResizableFloatingAndTransient() {
        let controller = makeController(clock: MutableClock(now: 0))
        XCTAssertFalse(controller.panel.styleMask.contains(.resizable))
        XCTAssertEqual(controller.panel.level, .floating)
        XCTAssertTrue(controller.panel.collectionBehavior.contains(.transient))
        XCTAssertTrue(controller.panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(controller.panel.isOpaque)
    }

    func testPanelHidesStandardWindowButtons() {
        let controller = makeController(clock: MutableClock(now: 0))
        XCTAssertTrue(controller.panel.standardWindowButton(.closeButton)?.isHidden ?? true)
        XCTAssertTrue(controller.panel.standardWindowButton(.miniaturizeButton)?.isHidden ?? true)
        XCTAssertTrue(controller.panel.standardWindowButton(.zoomButton)?.isHidden ?? true)
    }

    func testPanelHostsAVibrantVisualEffectBackedWebView() {
        let controller = makeController(clock: MutableClock(now: 0))
        let visualEffectView = controller.panel.contentView as? NSVisualEffectView
        XCTAssertNotNil(visualEffectView)
        XCTAssertEqual(visualEffectView?.material, .popover)
        XCTAssertEqual(visualEffectView?.blendingMode, .behindWindow)
        XCTAssertTrue(visualEffectView?.subviews.contains(controller.webView) ?? false)
    }

    // MARK: - Escape hides the panel

    func testEscapeHidesThePanel() {
        let clock = MutableClock(now: 0)
        let controller = makeController(clock: clock)
        controller.show(trayFrame: CGRect(x: 0, y: 780, width: 22, height: 22), screen: nil)
        XCTAssertTrue(controller.isVisible)

        (controller.panel as? SeerPanel)?.cancelOperation(nil)

        XCTAssertFalse(controller.isVisible)
    }

    // MARK: - Blur hides the panel and arms the 300ms guard

    func testWindowResigningKeyHidesThePanel() {
        let clock = MutableClock(now: 1_000)
        let controller = makeController(clock: clock)
        controller.show(trayFrame: CGRect(x: 0, y: 780, width: 22, height: 22), screen: nil)
        XCTAssertTrue(controller.isVisible)

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))

        XCTAssertFalse(controller.isVisible)
    }

    func testTrayClickWithinBlurGuardDoesNotReopenPanel() {
        let clock = MutableClock(now: 1_000)
        let controller = makeController(clock: clock)
        let trayFrame = CGRect(x: 0, y: 780, width: 22, height: 22)

        controller.show(trayFrame: trayFrame, screen: nil)
        XCTAssertTrue(controller.isVisible)

        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertFalse(controller.isVisible)

        // The same click that caused the resignation reaches the tray's
        // own click handler an instant later — well within the 300ms
        // guard — and must not reopen the panel it just closed.
        clock.now += 200
        controller.toggle(trayFrame: trayFrame, screen: nil)
        XCTAssertFalse(controller.isVisible)
    }

    func testTogglingAfterBlurGuardExpiresReopensThePanel() {
        let clock = MutableClock(now: 1_000)
        let controller = makeController(clock: clock)
        let trayFrame = CGRect(x: 0, y: 780, width: 22, height: 22)

        controller.show(trayFrame: trayFrame, screen: nil)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertFalse(controller.isVisible)

        clock.now += 301
        controller.toggle(trayFrame: trayFrame, screen: nil)
        XCTAssertTrue(controller.isVisible)
    }

    func testExplicitHideDoesNotArmTheBlurGuard() {
        // A caller-initiated hide (Escape, `panel.hide` bridge command, app
        // shutdown) must never block an immediately-following legitimate
        // `show`/`toggle` — only a *blur*-triggered hide does that.
        let clock = MutableClock(now: 1_000)
        let controller = makeController(clock: clock)
        let trayFrame = CGRect(x: 0, y: 780, width: 22, height: 22)

        controller.show(trayFrame: trayFrame, screen: nil)
        controller.hide()
        XCTAssertFalse(controller.isVisible)

        controller.show(trayFrame: trayFrame, screen: nil)
        XCTAssertTrue(controller.isVisible)
    }

    func testToggleClosesAnAlreadyVisiblePanel() {
        let controller = makeController(clock: MutableClock(now: 0))
        let trayFrame = CGRect(x: 0, y: 780, width: 22, height: 22)

        controller.toggle(trayFrame: trayFrame, screen: nil)
        XCTAssertTrue(controller.isVisible)

        controller.toggle(trayFrame: trayFrame, screen: nil)
        XCTAssertFalse(controller.isVisible)
    }
}
