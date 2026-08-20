import XCTest
@testable import Seer

@MainActor
final class StatusItemControllerTests: XCTestCase {
    private func activeSnapshot(agentNames: [String] = ["Codex"], keepAwakeMode: KeepAwakeMode = .system) -> AppSnapshot {
        let agents = agentNames.enumerated().map { index, name in
            ActiveAgent(id: "agent-\(index)", name: name, detail: "Working", source: .session, lastActivityAt: 1_000)
        }
        return AppSnapshot(
            monitor: AgentMonitorState(active: true, keepingAwake: true, keepAwakeMode: keepAwakeMode, agents: agents, lastScanAt: 1_000),
            history: HistoryStats(totalAwakeMs: 0, todayAwakeMs: 0, sessionCount: 0, perAgent: [], currentSession: nil, recentSessions: []),
            update: UpdateState(checking: false, availableVersion: nil, releaseURL: nil, lastCheckedAt: nil),
            diagnostics: [],
            appVersion: "1.0.0-test"
        )
    }

    private func idleSnapshot() -> AppSnapshot {
        AppSnapshot(
            monitor: AgentMonitorState(active: false, keepingAwake: false, keepAwakeMode: .system, agents: [], lastScanAt: 0),
            history: HistoryStats(totalAwakeMs: 0, todayAwakeMs: 0, sessionCount: 0, perAgent: [], currentSession: nil, recentSessions: []),
            update: UpdateState(checking: false, availableVersion: nil, releaseURL: nil, lastCheckedAt: nil),
            diagnostics: [],
            appVersion: "1.0.0-test"
        )
    }

    private func noopActions() -> StatusItemController.Actions {
        StatusItemController.Actions(
            togglePanel: {},
            setKeepAwakeMode: { _ in },
            setIncludePrereleaseUpdates: { _ in },
            viewLatestRelease: {},
            quit: {}
        )
    }

    private var createdStatusItems: [NSStatusItem] = []

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        createdStatusItems.append(item)
        return item
    }

    override func tearDown() {
        for item in createdStatusItems {
            NSStatusBar.system.removeStatusItem(item)
        }
        createdStatusItems.removeAll()
        super.tearDown()
    }

    // MARK: - Pure tray appearance

    func testActiveSnapshotUsesAmberBoltAndSingleAgentTooltip() {
        let appearance = StatusIconAppearanceBuilder.appearance(for: activeSnapshot().monitor)
        XCTAssertEqual(appearance.symbolName, "bolt.fill")
        XCTAssertEqual(appearance.tintColorHex, "#F2A93B")
        XCTAssertEqual(appearance.tooltip, "Seer · Codex working")
    }

    func testActiveSnapshotWithMultipleAgentsUsesPluralTooltip() {
        let appearance = StatusIconAppearanceBuilder.appearance(for: activeSnapshot(agentNames: ["Codex", "Claude"]).monitor)
        XCTAssertEqual(appearance.symbolName, "bolt.fill")
        XCTAssertEqual(appearance.tooltip, "Seer · 2 agents working")
    }

    func testIdleSnapshotUsesTemplateBoltSlashWithNoTint() {
        let appearance = StatusIconAppearanceBuilder.appearance(for: idleSnapshot().monitor)
        XCTAssertEqual(appearance.symbolName, "bolt.slash")
        XCTAssertNil(appearance.tintColorHex)
        XCTAssertEqual(appearance.tooltip, StatusIconAppearanceBuilder.idleTooltip)
    }

    // MARK: - Controller applies appearance to the real status item

    func testControllerAppliesActiveAppearanceToStatusItemButton() {
        let controller = StatusItemController(
            statusItem: makeStatusItem(),
            actions: noopActions(),
            initialSnapshot: activeSnapshot(),
            includePrereleaseUpdates: false
        )
        XCTAssertEqual(controller.statusItem.button?.toolTip, "Seer · Codex working")
        XCTAssertEqual(controller.statusItem.button?.contentTintColor, NSColor(seerHex: "#F2A93B"))
    }

    func testControllerAppliesIdleAppearanceToStatusItemButton() {
        let controller = StatusItemController(
            statusItem: makeStatusItem(),
            actions: noopActions(),
            initialSnapshot: idleSnapshot(),
            includePrereleaseUpdates: false
        )
        XCTAssertEqual(controller.statusItem.button?.toolTip, StatusIconAppearanceBuilder.idleTooltip)
        XCTAssertNil(controller.statusItem.button?.contentTintColor)
    }

    func testApplyUpdatesAppearanceAfterConstruction() {
        let controller = StatusItemController(
            statusItem: makeStatusItem(),
            actions: noopActions(),
            initialSnapshot: idleSnapshot(),
            includePrereleaseUpdates: false
        )
        controller.apply(activeSnapshot())
        XCTAssertEqual(controller.statusItem.button?.toolTip, "Seer · Codex working")
        XCTAssertEqual(controller.statusItem.button?.contentTintColor, NSColor(seerHex: "#F2A93B"))
    }

    // MARK: - Click routing

    func testLeftClickTogglesThePanel() {
        var toggled = false
        let actions = StatusItemController.Actions(
            togglePanel: { toggled = true },
            setKeepAwakeMode: { _ in },
            setIncludePrereleaseUpdates: { _ in },
            viewLatestRelease: {},
            quit: {}
        )
        let controller = StatusItemController(
            statusItem: makeStatusItem(),
            actions: actions,
            initialSnapshot: idleSnapshot(),
            includePrereleaseUpdates: false
        )

        controller.handle(isRightClick: false)

        XCTAssertTrue(toggled)
    }

    func testRightClickPresentsAFreshMenuBuiltFromTheLatestSnapshot() {
        var presentedMenu: NSMenu?
        let controller = StatusItemController(
            statusItem: makeStatusItem(),
            actions: noopActions(),
            initialSnapshot: activeSnapshot(),
            includePrereleaseUpdates: false,
            presentMenu: { menu, _ in presentedMenu = menu }
        )

        controller.handle(isRightClick: true)

        XCTAssertNotNil(presentedMenu)
        XCTAssertEqual(presentedMenu?.items.first?.title, StatusMenuLabel.openSeer)
    }

    // MARK: - Menu contents

    func testMenuContainsExactLabelsInOrderWithoutAvailableUpdate() {
        let menu = StatusItemController.buildMenu(snapshot: activeSnapshot(), includePrereleaseUpdates: false, actions: noopActions())

        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles, [
            StatusMenuLabel.openSeer,
            "",
            StatusMenuLabel.preventSleepHeader,
            StatusMenuLabel.systemOnly,
            StatusMenuLabel.systemAndDisplay,
            "",
            StatusMenuLabel.includePrereleaseUpdates,
            "",
            StatusMenuLabel.quitSeer,
        ])
    }

    func testMenuIncludesViewReleaseItemOnlyWhenAnUpdateIsAvailable() {
        var snapshotWithUpdate = activeSnapshot()
        snapshotWithUpdate.update = UpdateState(checking: false, availableVersion: "v1.1.0", releaseURL: "https://github.com/OpenCoven/seer-releases/releases/tag/v1.1.0", lastCheckedAt: 1_000)

        let menuWithUpdate = StatusItemController.buildMenu(snapshot: snapshotWithUpdate, includePrereleaseUpdates: false, actions: noopActions())
        XCTAssertTrue(menuWithUpdate.items.contains { $0.title == "View Seer v1.1.0" })

        let menuWithoutUpdate = StatusItemController.buildMenu(snapshot: activeSnapshot(), includePrereleaseUpdates: false, actions: noopActions())
        XCTAssertFalse(menuWithoutUpdate.items.contains { $0.title.hasPrefix("View Seer") })
    }

    func testSystemOnlyModeItemIsCheckedWhenCurrentModeIsSystem() {
        let menu = StatusItemController.buildMenu(
            snapshot: activeSnapshot(keepAwakeMode: .system),
            includePrereleaseUpdates: false,
            actions: noopActions()
        )
        let systemItem = menu.items.first { $0.title == StatusMenuLabel.systemOnly }
        let displayItem = menu.items.first { $0.title == StatusMenuLabel.systemAndDisplay }
        XCTAssertEqual(systemItem?.state, .on)
        XCTAssertEqual(displayItem?.state, .off)
    }

    func testSystemAndDisplayModeItemIsCheckedWhenCurrentModeIsDisplay() {
        let menu = StatusItemController.buildMenu(
            snapshot: activeSnapshot(keepAwakeMode: .display),
            includePrereleaseUpdates: false,
            actions: noopActions()
        )
        let systemItem = menu.items.first { $0.title == StatusMenuLabel.systemOnly }
        let displayItem = menu.items.first { $0.title == StatusMenuLabel.systemAndDisplay }
        XCTAssertEqual(systemItem?.state, .off)
        XCTAssertEqual(displayItem?.state, .on)
    }

    func testClickingSystemOnlyInvokesSetKeepAwakeModeWithSystem() {
        var requestedMode: KeepAwakeMode?
        let actions = StatusItemController.Actions(
            togglePanel: {},
            setKeepAwakeMode: { mode in requestedMode = mode },
            setIncludePrereleaseUpdates: { _ in },
            viewLatestRelease: {},
            quit: {}
        )
        let menu = StatusItemController.buildMenu(snapshot: activeSnapshot(keepAwakeMode: .display), includePrereleaseUpdates: false, actions: actions)

        (menu.items.first { $0.title == StatusMenuLabel.systemOnly } as? ClosureMenuItem)?.invoke()

        XCTAssertEqual(requestedMode, .system)
    }

    func testClickingSystemAndDisplayInvokesSetKeepAwakeModeWithDisplay() {
        var requestedMode: KeepAwakeMode?
        let actions = StatusItemController.Actions(
            togglePanel: {},
            setKeepAwakeMode: { mode in requestedMode = mode },
            setIncludePrereleaseUpdates: { _ in },
            viewLatestRelease: {},
            quit: {}
        )
        let menu = StatusItemController.buildMenu(snapshot: activeSnapshot(keepAwakeMode: .system), includePrereleaseUpdates: false, actions: actions)

        (menu.items.first { $0.title == StatusMenuLabel.systemAndDisplay } as? ClosureMenuItem)?.invoke()

        XCTAssertEqual(requestedMode, .display)
    }

    func testIncludePrereleaseCheckboxReflectsCurrentValueAndTogglesOnClick() {
        var requestedValue: Bool?
        let actions = StatusItemController.Actions(
            togglePanel: {},
            setKeepAwakeMode: { _ in },
            setIncludePrereleaseUpdates: { value in requestedValue = value },
            viewLatestRelease: {},
            quit: {}
        )
        let menu = StatusItemController.buildMenu(snapshot: activeSnapshot(), includePrereleaseUpdates: false, actions: actions)
        let item = menu.items.first { $0.title == StatusMenuLabel.includePrereleaseUpdates }
        XCTAssertEqual(item?.state, .off)

        (item as? ClosureMenuItem)?.invoke()

        XCTAssertEqual(requestedValue, true)
    }

    func testIncludePrereleaseCheckboxShowsCheckedWhenAlreadyEnabled() {
        let menu = StatusItemController.buildMenu(snapshot: activeSnapshot(), includePrereleaseUpdates: true, actions: noopActions())
        let item = menu.items.first { $0.title == StatusMenuLabel.includePrereleaseUpdates }
        XCTAssertEqual(item?.state, .on)
    }

    func testClickingOpenSeerInvokesTogglePanel() {
        var toggled = false
        let actions = StatusItemController.Actions(
            togglePanel: { toggled = true },
            setKeepAwakeMode: { _ in },
            setIncludePrereleaseUpdates: { _ in },
            viewLatestRelease: {},
            quit: {}
        )
        let menu = StatusItemController.buildMenu(snapshot: activeSnapshot(), includePrereleaseUpdates: false, actions: actions)

        (menu.items.first { $0.title == StatusMenuLabel.openSeer } as? ClosureMenuItem)?.invoke()

        XCTAssertTrue(toggled)
    }

    func testClickingViewReleaseInvokesViewLatestRelease() {
        var viewed = false
        let actions = StatusItemController.Actions(
            togglePanel: {},
            setKeepAwakeMode: { _ in },
            setIncludePrereleaseUpdates: { _ in },
            viewLatestRelease: { viewed = true },
            quit: {}
        )
        var snapshotWithUpdate = activeSnapshot()
        snapshotWithUpdate.update = UpdateState(checking: false, availableVersion: "v1.1.0", releaseURL: "https://github.com/OpenCoven/seer-releases/releases/tag/v1.1.0", lastCheckedAt: 1_000)
        let menu = StatusItemController.buildMenu(snapshot: snapshotWithUpdate, includePrereleaseUpdates: false, actions: actions)

        (menu.items.first { $0.title == "View Seer v1.1.0" } as? ClosureMenuItem)?.invoke()

        XCTAssertTrue(viewed)
    }

    func testClickingQuitInvokesQuit() {
        var quit = false
        let actions = StatusItemController.Actions(
            togglePanel: {},
            setKeepAwakeMode: { _ in },
            setIncludePrereleaseUpdates: { _ in },
            viewLatestRelease: {},
            quit: { quit = true }
        )
        let menu = StatusItemController.buildMenu(snapshot: activeSnapshot(), includePrereleaseUpdates: false, actions: actions)

        (menu.items.first { $0.title == StatusMenuLabel.quitSeer } as? ClosureMenuItem)?.invoke()

        XCTAssertTrue(quit)
    }

    // MARK: - Application menu keyboard shortcuts

    func testAppMainMenuHideHasCmdHKeyEquivalent() {
        let appMenu = AppMainMenuBuilder.build(appName: "Seer", quit: {}).items.first?.submenu
        let hideItem = appMenu?.items.first { $0.title == "Hide Seer" }

        XCTAssertEqual(hideItem?.keyEquivalent, "h")
        XCTAssertEqual(hideItem?.keyEquivalentModifierMask, .command)
    }

    func testAppMainMenuHideOthersHasOptionCmdHKeyEquivalent() {
        let appMenu = AppMainMenuBuilder.build(appName: "Seer", quit: {}).items.first?.submenu
        let hideOthersItem = appMenu?.items.first { $0.title == "Hide Others" }

        XCTAssertEqual(hideOthersItem?.keyEquivalent, "h")
        XCTAssertEqual(hideOthersItem?.keyEquivalentModifierMask, [.command, .option])
    }

    func testAppMainMenuQuitHasCmdQKeyEquivalent() {
        let appMenu = AppMainMenuBuilder.build(appName: "Seer", quit: {}).items.first?.submenu
        let quitItem = appMenu?.items.first { $0.title == StatusMenuLabel.quitSeer }

        XCTAssertEqual(quitItem?.keyEquivalent, "q")
        XCTAssertEqual(quitItem?.keyEquivalentModifierMask, .command)
    }

    // MARK: - Hex color parsing

    func testNSColorParsesHexWithAndWithoutHash() {
        XCTAssertEqual(NSColor(seerHex: "#F2A93B"), NSColor(seerHex: "F2A93B"))
        XCTAssertNil(NSColor(seerHex: "not-a-color"))
        XCTAssertNil(NSColor(seerHex: "#FFF"))
    }
}
