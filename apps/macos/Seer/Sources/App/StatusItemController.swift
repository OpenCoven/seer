import Cocoa

// MARK: - Tray appearance

/// The pure, testable outcome of deciding how the status item's tray icon
/// should look for a given `AgentMonitorState` — the SF Symbol name, the
/// hex tint color to apply (`nil` meaning "use the system's default
/// template tint"), and the tooltip text. Kept independent of `NSImage`/
/// `NSColor` so it can be asserted directly in tests without inspecting a
/// real rendered image.
public struct StatusIconAppearance: Equatable {
    public let symbolName: String
    public let tintColorHex: String?
    public let tooltip: String
}

/// Builds `StatusIconAppearance` from `AgentMonitorState`, mirroring the
/// Electron host's `applyTrayAppearance` (`main/services/tray.ts`) exactly:
/// lit amber `bolt.fill` while actually keeping the Mac awake, template
/// `bolt.slash` otherwise — driven by `keepingAwake` (the *actual* power
/// state), never merely `active` (whether any agent was detected), so a
/// power-assertion failure is reflected honestly in the tray too.
public enum StatusIconAppearanceBuilder {
    public static let activeSymbolName = "bolt.fill"
    public static let idleSymbolName = "bolt.slash"
    public static let activeColorHex = "#F2A93B"
    public static let idleTooltip = "Seer · sleep allowed"

    public static func appearance(for monitor: AgentMonitorState) -> StatusIconAppearance {
        guard monitor.keepingAwake else {
            return StatusIconAppearance(symbolName: idleSymbolName, tintColorHex: nil, tooltip: idleTooltip)
        }
        return StatusIconAppearance(symbolName: activeSymbolName, tintColorHex: activeColorHex, tooltip: tooltip(for: monitor))
    }

    private static func tooltip(for monitor: AgentMonitorState) -> String {
        let agents = monitor.agents
        if agents.count == 1, let name = agents.first?.name {
            return "Seer · \(name) working"
        }
        return "Seer · \(agents.count) agents working"
    }
}

extension NSColor {
    /// Parses a `#RRGGBB` hex string (the `#` is optional) into an sRGB
    /// `NSColor`. Returns `nil` for anything else — never a partial/best
    /// guess color.
    convenience init?(seerHex hex: String) {
        var hexString = hex
        if hexString.hasPrefix("#") {
            hexString.removeFirst()
        }
        guard hexString.count == 6, let value = UInt32(hexString, radix: 16) else {
            return nil
        }
        let red = CGFloat((value & 0xFF0000) >> 16) / 255
        let green = CGFloat((value & 0x00FF00) >> 8) / 255
        let blue = CGFloat(value & 0x0000FF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

// MARK: - Menu labels

/// Every exact label the native status/application menus use. Centralized
/// so no literal string appears more than once and every test asserting an
/// exact label reads from the same source as production.
public enum StatusMenuLabel {
    public static let openSeer = "Open Seer"
    public static let preventSleepHeader = "Prevent Sleep"
    public static let systemOnly = "System Only"
    public static let systemAndDisplay = "System & Display"
    public static let includePrereleaseUpdates = "Include Prerelease Updates"
    public static let quitSeer = "Quit Seer"

    public static func viewRelease(version: String) -> String {
        "View Seer \(version)"
    }
}

// MARK: - Closure-backed menu item

/// An `NSMenuItem` whose action invokes a plain closure instead of
/// requiring a separate target/selector pair wired up by the caller.
/// `invoke()` is intentionally not `private` so tests (via `@testable
/// import Seer`) can trigger a built menu item's action directly, without
/// needing to simulate a real AppKit menu-tracking click.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        self.target = self
        self.state = state
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("ClosureMenuItem does not support NSCoding")
    }

    @objc func invoke() {
        handler()
    }
}

// MARK: - Status item controller

/// Owns Seer's single `NSStatusItem` and its two native menus: a left-click
/// toggles the panel directly (no menu shown at all); a right-click builds
/// a brand-new `NSMenu` from whatever `AppSnapshot`/prerelease-toggle state
/// is current *at that moment* — never a menu built once and mutated in
/// place — and presents it.
@MainActor
public final class StatusItemController: NSObject {
    /// Every action a built menu (or a left-click) can trigger, injected as
    /// plain closures so this controller has no direct dependency on
    /// `AppSnapshotCoordinator`/`PanelController`/`AppDelegate` — purely for
    /// testability, matching `StandaloneBridgeCommandRouter`'s own
    /// closure-injection pattern.
    public struct Actions {
        public var togglePanel: () -> Void
        public var setKeepAwakeMode: (KeepAwakeMode) -> Void
        public var setIncludePrereleaseUpdates: (Bool) -> Void
        public var viewLatestRelease: () -> Void
        public var quit: () -> Void

        public init(
            togglePanel: @escaping () -> Void,
            setKeepAwakeMode: @escaping (KeepAwakeMode) -> Void,
            setIncludePrereleaseUpdates: @escaping (Bool) -> Void,
            viewLatestRelease: @escaping () -> Void,
            quit: @escaping () -> Void
        ) {
            self.togglePanel = togglePanel
            self.setKeepAwakeMode = setKeepAwakeMode
            self.setIncludePrereleaseUpdates = setIncludePrereleaseUpdates
            self.viewLatestRelease = viewLatestRelease
            self.quit = quit
        }
    }

    public let statusItem: NSStatusItem
    private let actions: Actions

    /// Presents a right-click-built menu. Defaults to the real AppKit
    /// popup behavior (`statusItem.menu` + `performClick`, immediately
    /// cleared again so a left-click is never intercepted by a leftover
    /// menu); tests inject a capturing closure instead, so exercising the
    /// right-click path never has to drive a real, run-loop-blocking
    /// `NSMenu` tracking session.
    private let presentMenu: @MainActor (NSMenu, NSStatusItem) -> Void

    public private(set) var latestSnapshot: AppSnapshot
    public private(set) var includePrereleaseUpdates: Bool

    public init(
        statusItem: NSStatusItem,
        actions: Actions,
        initialSnapshot: AppSnapshot,
        includePrereleaseUpdates: Bool,
        presentMenu: @escaping @MainActor (NSMenu, NSStatusItem) -> Void = StatusItemController.presentMenuUsingStatusItem
    ) {
        self.statusItem = statusItem
        self.actions = actions
        self.latestSnapshot = initialSnapshot
        self.includePrereleaseUpdates = includePrereleaseUpdates
        self.presentMenu = presentMenu
        super.init()

        configureButton()
        applyAppearance()
    }

    /// The real, production `presentMenu` implementation: temporarily
    /// attaches `menu` to `statusItem` and synthesizes the click that shows
    /// it, then detaches it again so a later left-click is never
    /// intercepted by a stale menu.
    public static func presentMenuUsingStatusItem(_ menu: NSMenu, _ statusItem: NSStatusItem) {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Snapshot / settings application

    public func apply(_ snapshot: AppSnapshot) {
        latestSnapshot = snapshot
        applyAppearance()
    }

    public func apply(includePrereleaseUpdates value: Bool) {
        includePrereleaseUpdates = value
    }

    private func applyAppearance() {
        let appearance = StatusIconAppearanceBuilder.appearance(for: latestSnapshot.monitor)
        statusItem.button?.image = NSImage(systemSymbolName: appearance.symbolName, accessibilityDescription: appearance.tooltip)
        statusItem.button?.contentTintColor = appearance.tintColorHex.flatMap { NSColor(seerHex: $0) }
        statusItem.button?.toolTip = appearance.tooltip
    }

    // MARK: - Click routing

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleButtonClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleButtonClick(_ sender: Any?) {
        handle(isRightClick: NSApp.currentEvent?.type == .rightMouseUp)
    }

    /// The testable core of click routing, decoupled from `NSApp
    /// .currentEvent` so tests can exercise both branches deterministically
    /// without needing to synthesize a real `NSEvent`.
    func handle(isRightClick: Bool) {
        if isRightClick {
            showMenu()
        } else {
            actions.togglePanel()
        }
    }

    private func showMenu() {
        let menu = Self.buildMenu(snapshot: latestSnapshot, includePrereleaseUpdates: includePrereleaseUpdates, actions: actions)
        presentMenu(menu, statusItem)
    }

    // MARK: - Menu building

    /// Builds a brand-new `NSMenu` from `snapshot`/`includePrereleaseUpdates`
    /// — never mutates a previously built one — with the exact labels
    /// `StatusMenuLabel` defines, in this exact order: `Open Seer`; a
    /// `Prevent Sleep` section header followed by the two keep-awake mode
    /// radio-style items (checked to match `snapshot.monitor.keepAwakeMode`);
    /// `Include Prerelease Updates` (checked to match
    /// `includePrereleaseUpdates`); `View Seer vX.Y.Z` *only* when
    /// `snapshot.update.availableVersion` is non-nil; and finally `Quit Seer`.
    static func buildMenu(snapshot: AppSnapshot, includePrereleaseUpdates: Bool, actions: Actions) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(ClosureMenuItem(title: StatusMenuLabel.openSeer, handler: actions.togglePanel))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem.sectionHeader(title: StatusMenuLabel.preventSleepHeader))
        menu.addItem(ClosureMenuItem(
            title: StatusMenuLabel.systemOnly,
            state: snapshot.monitor.keepAwakeMode == .system ? .on : .off
        ) {
            actions.setKeepAwakeMode(.system)
        })
        menu.addItem(ClosureMenuItem(
            title: StatusMenuLabel.systemAndDisplay,
            state: snapshot.monitor.keepAwakeMode == .display ? .on : .off
        ) {
            actions.setKeepAwakeMode(.display)
        })
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(
            title: StatusMenuLabel.includePrereleaseUpdates,
            state: includePrereleaseUpdates ? .on : .off
        ) {
            actions.setIncludePrereleaseUpdates(!includePrereleaseUpdates)
        })
        if let version = snapshot.update.availableVersion {
            menu.addItem(ClosureMenuItem(title: StatusMenuLabel.viewRelease(version: version), handler: actions.viewLatestRelease))
        }
        menu.addItem(.separator())

        menu.addItem(ClosureMenuItem(title: StatusMenuLabel.quitSeer, handler: actions.quit))

        return menu
    }
}

// MARK: - Application menu

/// Builds the standalone app's main menu bar. Even though Seer runs as an
/// accessory (`LSUIElement`) app with no Dock icon, `NSApp.mainMenu` is
/// still assigned this so the standard `Cmd+Q`/`Cmd+H` application-menu
/// shortcuts and behavior (Quit, Hide, ...) remain available whenever the
/// panel is key.
@MainActor
public enum AppMainMenuBuilder {
    public static func build(appName: String, quit: @escaping () -> Void) -> NSMenu {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        appMenu.addItem(ClosureMenuItem(title: "About \(appName)") {
            NSApp.orderFrontStandardAboutPanel(nil)
        })
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())

        appMenu.addItem(ClosureMenuItem(title: "Hide \(appName)") {
            NSApp.hide(nil)
        })
        let hideOthers = ClosureMenuItem(title: "Hide Others") {
            NSApp.hideOtherApplications(nil)
        }
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.keyEquivalent = "h"
        appMenu.addItem(hideOthers)
        appMenu.addItem(ClosureMenuItem(title: "Show All") {
            NSApp.unhideAllApplications(nil)
        })
        appMenu.addItem(.separator())

        appMenu.addItem(ClosureMenuItem(title: StatusMenuLabel.quitSeer, handler: quit))

        return mainMenu
    }
}

// MARK: - AppSnapshotRendererSink conformance

/// Lets `StatusItemController` be listed directly alongside
/// `RendererEventSink` in a broadcasting sink (see `AppDelegate`'s
/// `MulticastRendererSink`), so `AppSnapshotCoordinator` has exactly one
/// `renderer` to publish to at construction time, rather than the app shell
/// needing a bespoke fan-out type per consumer.
extension StatusItemController: AppSnapshotRendererSink {
    public func emit(_ snapshot: AppSnapshot) {
        apply(snapshot)
    }
}
