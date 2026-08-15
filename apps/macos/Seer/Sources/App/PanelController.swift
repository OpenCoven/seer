import Cocoa
import WebKit

// MARK: - Geometry

/// Pure geometry for positioning Seer's transient panel relative to the
/// status item's tray button. Takes plain `CGRect`/`CGSize` values rather
/// than `NSScreen`/`NSStatusItem` themselves, so this is directly
/// unit-testable with no live status bar/screen required.
public enum PanelGeometry {
    /// Vertical gap between the tray button and the panel.
    public static let defaultGap: CGFloat = 6
    /// Minimum distance kept between the panel and every screen edge.
    public static let defaultMargin: CGFloat = 8

    /// Computes the panel's origin (bottom-left, AppKit screen coordinates)
    /// horizontally centered under `tray`, clamped so the panel never
    /// extends past `visibleFrame`'s edges by more than `margin`.
    ///
    /// Prefers placing the panel directly below the tray button
    /// (`tray.minY - gap - panelSize.height`); falls back to placing it
    /// above the tray if there is not enough vertical room below, and
    /// finally clamps into `visibleFrame` outright if neither placement
    /// fits cleanly (a screen shorter than the panel itself).
    public static func origin(
        tray: CGRect,
        visibleFrame: CGRect,
        panelSize: CGSize,
        gap: CGFloat = defaultGap,
        margin: CGFloat = defaultMargin
    ) -> CGPoint {
        let minX = visibleFrame.minX + margin
        let maxX = max(minX, visibleFrame.maxX - margin - panelSize.width)
        let desiredX = tray.midX - panelSize.width / 2
        let x = min(max(desiredX, minX), maxX)

        let minY = visibleFrame.minY + margin
        let maxY = max(minY, visibleFrame.maxY - margin - panelSize.height)
        let belowY = tray.minY - gap - panelSize.height
        let aboveY = tray.maxY + gap

        let y: CGFloat
        if belowY >= minY {
            y = min(belowY, maxY)
        } else if aboveY <= maxY {
            y = max(aboveY, minY)
        } else {
            y = min(max(belowY, minY), maxY)
        }

        return CGPoint(x: x, y: y)
    }
}

// MARK: - Panel window

/// Custom `NSPanel` for Seer's transient popover-style window. Overrides
/// `cancelOperation(_:)` — the standard action AppKit sends for the Escape
/// key — to hide the panel instead of beeping, and always reports
/// `canBecomeKey` as `true` so a `.nonactivatingPanel` can still receive
/// keyboard input (Escape) and later resign key (triggering
/// `PanelController`'s blur handling) without ever requiring the app
/// itself to fully activate.
final class SeerPanel: NSPanel {
    var onCancelOperation: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancelOperation?()
    }
}

// MARK: - WKWebView security configuration

/// Builds the exact, locked-down `WKWebViewConfiguration` Seer's standalone
/// panel uses: an ephemeral (nonpersistent) data store, JavaScript may never
/// open new windows, and the only URL scheme handler installed is
/// `seer://` — nothing else is ever registered here.
enum SeerWebViewFactory {
    @MainActor
    static func makeConfiguration(rendererRoot: SeerRendererRoot) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.setURLSchemeHandler(SeerSchemeHandler(rendererRoot: rendererRoot), forURLScheme: SeerSchemeHandler.scheme)
        return configuration
    }

    @MainActor
    static func makeWebView(rendererRoot: SeerRendererRoot, frame: CGRect) -> WKWebView {
        WKWebView(frame: frame, configuration: makeConfiguration(rendererRoot: rendererRoot))
    }
}

/// Denies every navigation `SeerNavigationPolicy` does not explicitly allow.
/// Covers both entry points a real navigation attempt can arrive through:
/// an ordinary `decidePolicyFor navigationAction` decision (link clicks,
/// `window.location` assignment, ...), and a server-issued redirect — which
/// WebKit does *not* route through `decidePolicyFor` at all, only through
/// `didReceiveServerRedirectForProvisionalNavigation`, so that redirect is
/// instead stopped outright via `webView.stopLoading()` the moment it is
/// reported.
final class SeerWebViewNavigationDelegate: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let request = SeerNavigationRequest(
            url: navigationAction.request.url ?? SeerNavigationPolicy.allowedInitialDocumentURL,
            targetFrameIsMain: navigationAction.targetFrame?.isMainFrame
        )
        decisionHandler(SeerNavigationPolicy.decide(request) == .allow ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        let request = SeerNavigationRequest(
            url: webView.url ?? SeerNavigationPolicy.allowedInitialDocumentURL,
            targetFrameIsMain: true,
            isServerRedirect: true
        )
        if SeerNavigationPolicy.decide(request) == .cancel {
            webView.stopLoading()
        }
    }
}

// MARK: - Panel controller

/// Owns Seer's single transient panel window and the `WKWebView` it hosts:
/// a fixed 340×440, non-resizable, vibrant-popover-styled `NSPanel` that is
/// centered below the status item's tray button (falling back above it, and
/// always clamped to the screen's visible frame — see `PanelGeometry`), with
/// hidden title-bar buttons, floating window level, and `.transient`/
/// `.fullScreenAuxiliary` collection behavior so it never appears in
/// Mission Control or interferes with full-screen spaces.
///
/// Hides on Escape (`SeerPanel.cancelOperation`) and on losing key focus
/// (`windowDidResignKey`); the latter path also arms a 300 ms "blur guard"
/// (`clock`-driven, never `Date()` directly) so the very same click that
/// caused the panel to resign key — which typically also reaches the status
/// item's own click handler an instant later — cannot immediately reopen
/// the panel it just closed.
@MainActor
public final class PanelController: NSObject {
    /// Seer's panel is always exactly this size — see `Seer.entitlements`'s
    /// non-resizable design; `minimumHeight` documents the floor a future
    /// resizable variant would need to respect, and is applied to the
    /// panel's `minSize` defensively even though the panel's `styleMask`
    /// itself never includes `.resizable`.
    public static let panelSize = CGSize(width: 340, height: 440)
    public static let minimumHeight: CGFloat = 280

    /// How long after a blur-triggered hide a `show`/`toggle` request is
    /// swallowed instead of immediately reopening the panel.
    static let blurGuardMilliseconds: Int64 = 300

    public let panel: NSPanel
    public let webView: WKWebView

    private let seerPanel: SeerPanel
    private let navigationDelegate = SeerWebViewNavigationDelegate()
    private let clock: Clock
    private var lastBlurHideAtMilliseconds: Int64?

    public var isVisible: Bool { panel.isVisible }

    /// `WKUserContentController` for the hosted web view — exposed so
    /// callers (`AppDelegate`) can register `BridgeMessageHandler` on it,
    /// and remove that registration again at shutdown, without needing
    /// direct access to `webView.configuration` themselves.
    public var userContentController: WKUserContentController {
        webView.configuration.userContentController
    }

    public init(rendererRoot: SeerRendererRoot, clock: Clock = SystemClock()) {
        self.clock = clock

        let contentRect = CGRect(origin: .zero, size: PanelController.panelSize)
        let webView = SeerWebViewFactory.makeWebView(rendererRoot: rendererRoot, frame: contentRect)
        self.webView = webView

        let panel = SeerPanel(
            contentRect: contentRect,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.seerPanel = panel
        self.panel = panel

        super.init()

        configureWebView(webView)
        configurePanel(panel, hosting: webView)
    }

    /// Loads Seer's single permitted document. Must only be called once
    /// `BridgeMessageHandlerRegistration.register(_:on:)` has already run
    /// against `userContentController` — the injected bridge relay script
    /// must be present before the document itself starts loading.
    public func loadInitialDocument() {
        webView.load(URLRequest(url: SeerNavigationPolicy.allowedInitialDocumentURL))
    }

    private func configureWebView(_ webView: WKWebView) {
        webView.navigationDelegate = navigationDelegate
        // Seer's document (`renderer/standalone/styles.css`) already
        // renders a fully transparent `html`/`body`/`#root` background —
        // but `WKWebView` itself still paints an opaque page background
        // behind that by default, hiding the vibrant `NSVisualEffectView`
        // this web view sits on top of entirely. `underPageBackgroundColor`
        // is the supported public API for this (macOS 13+; Seer's
        // deployment target is 14.0) — setting it to `.clear` lets the
        // panel's own vibrancy show through wherever the document leaves
        // its background transparent.
        webView.underPageBackgroundColor = .clear
        #if DEBUG
        webView.isInspectable = true
        #else
        webView.isInspectable = false
        #endif
    }

    private func configurePanel(_ panel: SeerPanel, hosting webView: WKWebView) {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = CGSize(width: PanelController.panelSize.width, height: PanelController.minimumHeight)
        panel.maxSize = PanelController.panelSize
        panel.setContentSize(PanelController.panelSize)
        panel.delegate = self

        let visualEffect = NSVisualEffectView(frame: CGRect(origin: .zero, size: PanelController.panelSize))
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true
        visualEffect.autoresizingMask = [.width, .height]

        webView.frame = visualEffect.bounds
        webView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(webView)

        panel.contentView = visualEffect
        panel.onCancelOperation = { [weak self] in self?.hide() }
    }

    // MARK: - Show / hide / toggle

    public func toggle(trayFrame: CGRect, screen: NSScreen?) {
        if panel.isVisible {
            hide()
        } else {
            show(trayFrame: trayFrame, screen: screen)
        }
    }

    public func show(trayFrame: CGRect, screen: NSScreen?) {
        guard !isBlurGuardActive() else { return }
        let visibleFrame = screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(origin: .zero, size: PanelController.panelSize)
        let origin = PanelGeometry.origin(tray: trayFrame, visibleFrame: visibleFrame, panelSize: panel.frame.size)
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Explicit, caller-initiated hide (Escape, the `panel.hide` bridge
    /// command, or app shutdown) — never arms the blur guard, since there
    /// is no risk of an immediately-following click re-triggering `show`.
    public func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    private func isBlurGuardActive() -> Bool {
        guard let lastBlurHideAtMilliseconds else { return false }
        return clock.nowMilliseconds() - lastBlurHideAtMilliseconds < Self.blurGuardMilliseconds
    }
}

extension PanelController: NSWindowDelegate {
    /// Hides the panel the moment it resigns key (the user clicked outside
    /// it, or another window/app became active), and arms the 300 ms blur
    /// guard so a click on the status item's own tray button — which both
    /// causes this resignation *and* reaches the tray's click handler an
    /// instant later — cannot immediately reopen the panel it just closed.
    public func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastBlurHideAtMilliseconds = clock.nowMilliseconds()
    }
}
