import { BrowserWindow, app, logger, screen } from "@glaze/core/backend";
import type { Rectangle } from "@glaze/core/backend";

import { getPreloadPath, getWindowUrl } from "./window-paths.js";

const PANEL_WIDTH = 340;
const PANEL_HEIGHT = 440;
const PANEL_GAP = 6;

let panelWindow: BrowserWindow | null = null;
let blurCloseEnabled = true;
// Timestamp of the last hide, used to swallow the reopen when a tray click
// steals focus (the panel blur-hides first, then the click toggle fires).
let lastHiddenAt = 0;

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

function positionForTrayBounds(trayBounds: Rectangle): { x: number; y: number } {
  const display = screen.getDisplayNearestPoint({
    x: Math.round(trayBounds.x + trayBounds.width / 2),
    y: Math.round(trayBounds.y + trayBounds.height / 2),
  });
  const workArea = display.workArea;

  const x = clamp(
    Math.round(trayBounds.x + trayBounds.width / 2 - PANEL_WIDTH / 2),
    workArea.x + 8,
    workArea.x + workArea.width - PANEL_WIDTH - 8,
  );

  // Prefer below the menu bar icon; fall back above if needed.
  let y = Math.round(trayBounds.y + trayBounds.height + PANEL_GAP);
  if (y + PANEL_HEIGHT > workArea.y + workArea.height - 8) {
    y = Math.round(trayBounds.y - PANEL_HEIGHT - PANEL_GAP);
  }
  y = clamp(y, workArea.y + 8, workArea.y + workArea.height - PANEL_HEIGHT - 8);

  return { x, y };
}

export async function ensurePanelWindow(): Promise<BrowserWindow> {
  if (panelWindow && !panelWindow.isDestroyed()) {
    return panelWindow;
  }

  panelWindow = new BrowserWindow({
    windowKey: "panel",
    width: PANEL_WIDTH,
    height: PANEL_HEIGHT,
    minWidth: PANEL_WIDTH,
    minHeight: 280,
    maxWidth: 420,
    frame: true,
    titleBarStyle: "hidden",
    toolbarStyle: "none",
    backgroundColor: "#00000000",
    vibrancy: "popover",
    visualEffectState: "active",
    resizable: false,
    maximizable: false,
    minimizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    hiddenInMissionControl: true,
    alwaysOnTop: true,
    show: false,
    webPreferences: {
      preload: getPreloadPath(),
    },
  });

  panelWindow.setWindowButtonVisibility(false);
  panelWindow.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });

  panelWindow.on("blur", () => {
    if (!blurCloseEnabled) return;
    if (panelWindow && !panelWindow.isDestroyed()) {
      panelWindow.hide();
      lastHiddenAt = Date.now();
    }
  });

  panelWindow.on("closed", () => {
    panelWindow = null;
  });

  const url = await getWindowUrl("main-window.html");
  logger.info("panel", "Loading panel URL", { url });
  await panelWindow.loadURL(url);

  return panelWindow;
}

function fallbackMenuBarBounds(): Rectangle {
  const cursor = screen.getCursorScreenPoint();
  const display = screen.getDisplayNearestPoint(cursor);
  const { workArea } = display;
  // Approximate the menu-bar strip above the work area, centered on the cursor.
  return {
    x: cursor.x - 11,
    y: Math.max(display.bounds.y, workArea.y - 24),
    width: 22,
    height: 22,
  };
}

export async function showPanelWindow(trayBounds?: Rectangle): Promise<void> {
  const bounds = trayBounds ?? fallbackMenuBarBounds();
  const win = await ensurePanelWindow();

  const { x, y } = positionForTrayBounds(bounds);
  win.setBounds({ x, y, width: PANEL_WIDTH, height: PANEL_HEIGHT });

  if (!win.isVisible()) {
    win.show();
  }
  win.focus();
}

export function hidePanelWindow(): void {
  if (panelWindow && !panelWindow.isDestroyed() && panelWindow.isVisible()) {
    panelWindow.hide();
    lastHiddenAt = Date.now();
  }
}

export async function togglePanelWindow(trayBounds?: Rectangle): Promise<void> {
  if (panelWindow && !panelWindow.isDestroyed() && panelWindow.isVisible()) {
    hidePanelWindow();
    return;
  }
  // A tray click steals focus and blur-hides the panel first; don't immediately reopen it.
  if (Date.now() - lastHiddenAt < 300) {
    return;
  }
  await showPanelWindow(trayBounds);
}

export function getPanelWindow(): BrowserWindow | null {
  return panelWindow;
}

export function setPanelBlurCloseEnabled(enabled: boolean): void {
  blurCloseEnabled = enabled;
}

export async function prepareAccessoryActivation(): Promise<void> {
  // Keep Dock hidden for menu-bar-only behavior, including re-activation.
  try {
    app.dock.hide();
  } catch (error) {
    logger.debug("panel", "dock.hide unavailable", { error });
  }
}
