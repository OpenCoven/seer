// Main process entry point - Node.js backend for Glaze app
//
// Menu-bar agent monitor: detects active agents, keeps Mac awake, native tray menu.

import { app, Menu, logger, initDevToolsButtonState } from "@glaze/core/backend";

import { registerHandlers } from "./handlers/index.js";
import { historyStore } from "./services/history-store.js";
import { onMonitorStateChange, startMonitor, stopMonitor } from "./services/monitor.js";
import { createTray, destroyTray } from "./services/tray.js";

// ── IPC Handlers ──────────────────────────────────────────────────────
registerHandlers();

// ── Dev-only parity harness ───────────────────────────────────────────
type DevHarness = {
  applyParityScenarioStartup(): void;
  runParityAutotestIfRequested(): Promise<void>;
};
type AppAiDevHarness = {
  runAppAiAutotest(): Promise<void>;
};
let devHarness: DevHarness | null = null;
let appAiDevHarness: AppAiDevHarness | null = null;
if (process.env.GLAZE_DEV_HARNESS === "1") {
  // @ts-ignore dev-only harness; present only in the template, excluded from scaffolded apps
  devHarness = (await import("./dev/parity-autotest.js")) as DevHarness;
  devHarness.applyParityScenarioStartup();
  // @ts-ignore dev-only harness; present only in the template, excluded from scaffolded apps
  appAiDevHarness = (await import("./dev/app-ai-autotest.js")) as AppAiDevHarness;
}

// ── Application menu ──────────────────────────────────────────────────
async function setupApplicationMenu() {
  await initDevToolsButtonState();
  const menu = Menu.buildFromTemplate([
    {
      label: "Seer",
      submenu: [
        { role: "about" },
        { type: "separator" },
        { role: "services" },
        { type: "separator" },
        { role: "hide" },
        { role: "hideOthers" },
        { role: "unhide" },
        { type: "separator" },
        { role: "quit" },
      ],
    },
    { role: "editMenu" },
    { role: "windowMenu" },
  ]);
  Menu.setApplicationMenu(menu);
}

function hideDockIcon(): void {
  try {
    app.dock.hide();
  } catch (error) {
    logger.debug("main", "dock.hide unavailable", { error });
  }
}

// ── Lifecycle events ──────────────────────────────────────────────────
app.on("window-all-closed", () => {
  // Menu-bar app: stay running with no windows.
});

app.on("activate", () => {
  hideDockIcon();
});

app.on("before-quit", () => {
  logger.info("main", "App before-quit, cleaning up...");
  stopMonitor();
  destroyTray();
  historyStore.flush();
});

// ── App ready ─────────────────────────────────────────────────────────
app.whenReady().then(async () => {
  logger.info("main", "App ready — starting Seer");

  await devHarness?.runParityAutotestIfRequested();
  await appAiDevHarness?.runAppAiAutotest();

  hideDockIcon();
  await setupApplicationMenu();

  await historyStore.init();
  onMonitorStateChange((state) => {
    historyStore.recordState(state);
  });

  createTray();
  await startMonitor();
});
