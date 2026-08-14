import { Menu, Tray, app, logger } from "@glaze/core/backend";
import type { MenuItemConstructorOptions, Rectangle } from "@glaze/core/backend";

import { getMonitorState, onMonitorStateChange, setKeepAwakeMode } from "./monitor.js";
import type { AgentMonitorState, KeepAwakeMode, UpdateState } from "./types.js";
import { getSharedUpdateService } from "./update-check.js";
import { showPanelWindow, togglePanelWindow } from "../windows/panel-window.js";

// Stable GUID — do not regenerate. Preserves menu-bar position across launches.
const TRAY_GUID = "b2ffcd25-6e8c-4df5-899f-0bf17b7dc7d1";

// Lit (amber) when actively keeping the Mac awake; template glyph when idle.
const ACTIVE_ICON = "bolt.fill";
const IDLE_ICON = "bolt.slash";
const ACTIVE_COLOR = "#F2A93B";

let tray: Tray | null = null;
let latestState: AgentMonitorState = getMonitorState();
let unsubscribeState: (() => void) | null = null;
let latestUpdate: UpdateState = {
  checking: false,
  availableVersion: null,
  releaseURL: null,
  lastCheckedAt: null,
};
let unsubscribeUpdateState: (() => void) | null = null;

function selectKeepAwakeMode(mode: KeepAwakeMode): void {
  void setKeepAwakeMode(mode).catch((error: unknown) => {
    logger.error("tray", "Failed to set keep-awake mode from menu", error);
  });
}

function buildContextMenu(state: AgentMonitorState, bounds?: Rectangle): Menu {
  const updateService = getSharedUpdateService();
  const items: MenuItemConstructorOptions[] = [
    {
      label: "Open Seer",
      click: () => {
        void showPanelWindow(bounds);
      },
    },
    { type: "separator" },
    { type: "header", label: "Prevent Sleep" },
    {
      id: "keep-awake-system",
      label: "System Only",
      type: "radio",
      checked: state.keepAwakeMode === "system",
      click: () => {
        selectKeepAwakeMode("system");
      },
    },
    {
      id: "keep-awake-display",
      label: "System & Display",
      type: "radio",
      checked: state.keepAwakeMode === "display",
      click: () => {
        selectKeepAwakeMode("display");
      },
    },
    { type: "separator" },
    { type: "header", label: "Updates" },
    {
      label: "Include Prerelease Updates",
      type: "checkbox",
      checked: updateService.includesPrereleaseUpdates(),
      click: () => {
        void updateService.setIncludePrereleaseUpdates(!updateService.includesPrereleaseUpdates()).catch((error: unknown) => {
          logger.error("tray", "Failed to change prerelease update setting", error);
        });
      },
    },
    ...(latestUpdate.availableVersion
      ? [
          {
            label: `View Seer ${latestUpdate.availableVersion}`,
            click: () => {
              void updateService.openCurrentRelease();
            },
          } satisfies MenuItemConstructorOptions,
        ]
      : []),
    { type: "separator" },
    {
      label: "Quit Seer",
      click: () => {
        app.quit();
      },
    },
  ];

  return Menu.buildFromTemplate(items);
}

function ensureTrayIcon(): Tray {
  if (tray && !tray.isDestroyed()) {
    return tray;
  }

  tray = new Tray(IDLE_ICON, { guid: TRAY_GUID });
  tray.setIgnoreDoubleClickEvents(true);

  // No persistent context menu: left-click toggles the panel, right-click
  // pops a small quick menu on demand.
  tray.on("click", (_event, bounds) => {
    void togglePanelWindow(bounds);
  });
  tray.on("right-click", (_event, bounds) => {
    tray?.popUpContextMenu(buildContextMenu(latestState, bounds));
  });

  logger.info("tray", "Menu bar icon created");
  return tray;
}

function applyTrayAppearance(state: AgentMonitorState): void {
  if (!tray || tray.isDestroyed()) return;

  if (state.keepingAwake) {
    tray.setImage(ACTIVE_ICON, { color: ACTIVE_COLOR });
  } else {
    tray.setImage(IDLE_ICON);
  }

  const count = state.agents.length;
  if (state.keepingAwake) {
    tray.setToolTip(
      count === 1
        ? `Seer · ${state.agents[0]?.name ?? "agent"} working`
        : `Seer · ${count} agents working`,
    );
  } else {
    tray.setToolTip("Seer · sleep allowed");
  }
}

/** Create the always-visible menu-bar icon and keep it in sync with state. */
export function createTray(): void {
  ensureTrayIcon();

  unsubscribeState?.();
  unsubscribeState = onMonitorStateChange((state) => {
    latestState = state;
    applyTrayAppearance(state);
  });
  const updateService = getSharedUpdateService();
  latestUpdate = updateService.getState();
  unsubscribeUpdateState?.();
  unsubscribeUpdateState = updateService.subscribe((state) => {
    latestUpdate = state;
  });

  latestState = getMonitorState();
  applyTrayAppearance(latestState);
}

export function destroyTray(): void {
  unsubscribeState?.();
  unsubscribeState = null;
  unsubscribeUpdateState?.();
  unsubscribeUpdateState = null;

  if (tray && !tray.isDestroyed()) {
    tray.closeContextMenu();
    tray.destroy();
  }
  tray = null;
  logger.info("tray", "Menu bar icon destroyed");
}
