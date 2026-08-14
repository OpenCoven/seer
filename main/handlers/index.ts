/**
 * Handler Registration
 */

import * as path from "path";
import { fileURLToPath } from "url";

import { agentHandlers } from "./agents.js";
import { appHandlers } from "./app.js";
import { historyHandlers } from "./history.js";
import { updateHandlers } from "./updates.js";
import { hidePanelWindow } from "../windows/panel-window.js";

import { app, ipcMain, logger } from "@glaze/core/backend";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

export function registerHandlers(): void {
  logger.info("handlers", "Registering IPC handlers...");

  ipcMain.handle("app:getInfo", async () => {
    return await appHandlers.getInfo();
  });

  ipcMain.handle("app:getProjectPath", async () => {
    return path.join(__dirname, "..", "..");
  });

  ipcMain.handle("agents:getState", async () => {
    return await agentHandlers.getState();
  });

  ipcMain.handle("agents:setKeepAwakeMode", async (_event, payload: unknown) => {
    return await agentHandlers.setKeepAwakeMode(payload);
  });

  ipcMain.handle("history:getStats", async () => {
    return await historyHandlers.getStats();
  });

  ipcMain.handle("history:clear", async () => {
    return await historyHandlers.clear();
  });

  ipcMain.handle("updates:getState", async () => {
    return updateHandlers.getState();
  });

  ipcMain.handle("updates:check", async () => {
    return await updateHandlers.check();
  });

  ipcMain.handle("updates:open", async () => {
    await updateHandlers.open();
  });

  ipcMain.handle("window:hidePanel", async () => {
    hidePanelWindow();
  });

  ipcMain.handle("app:quit", async () => {
    app.quit();
  });

  logger.info("handlers", "✓ IPC handlers registered");
}
