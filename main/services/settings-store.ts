import * as fs from "node:fs/promises";
import * as path from "node:path";

import { app, logger } from "@glaze/core/backend";

import type { AppSettings, KeepAwakeMode } from "./types.js";

const DEFAULT_SETTINGS: AppSettings = {
  keepAwakeMode: "system",
};

function isFileNotFound(error: unknown): boolean {
  return error instanceof Error && "code" in error && (error as NodeJS.ErrnoException).code === "ENOENT";
}

function isKeepAwakeMode(value: unknown): value is KeepAwakeMode {
  return value === "system" || value === "display";
}

function normalizeSettings(value: unknown): AppSettings {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { ...DEFAULT_SETTINGS };
  }

  const record = value as Record<string, unknown>;
  return {
    keepAwakeMode: isKeepAwakeMode(record.keepAwakeMode) ? record.keepAwakeMode : DEFAULT_SETTINGS.keepAwakeMode,
  };
}

class SettingsStore {
  private cache: AppSettings = { ...DEFAULT_SETTINGS };
  private settingsPath: string | null = null;
  private saveQueue: Promise<void> = Promise.resolve();
  private loaded = false;

  private async getSettingsPath(): Promise<string> {
    if (!this.settingsPath) {
      const userDataPath = app.getPath("userData");
      await fs.mkdir(userDataPath, { recursive: true });
      this.settingsPath = path.join(userDataPath, "settings.json");
    }
    return this.settingsPath;
  }

  async load(): Promise<AppSettings> {
    if (this.loaded) {
      return this.cache;
    }

    try {
      const data = await fs.readFile(await this.getSettingsPath(), "utf-8");
      const parsed: unknown = JSON.parse(data);
      this.cache = normalizeSettings(parsed);
    } catch (error) {
      if (!isFileNotFound(error)) {
        logger.error("settings", "Failed to load settings", error);
        throw error;
      }
      this.cache = { ...DEFAULT_SETTINGS };
    }

    this.loaded = true;
    return this.cache;
  }

  get(): AppSettings {
    return this.cache;
  }

  async setKeepAwakeMode(mode: KeepAwakeMode): Promise<AppSettings> {
    await this.load();
    this.cache = { ...this.cache, keepAwakeMode: mode };
    await this.persist();
    return this.cache;
  }

  private async persist(): Promise<void> {
    const snapshot = { ...this.cache };
    const save = this.saveQueue
      .catch(() => undefined)
      .then(async () => {
        const filePath = await this.getSettingsPath();
        const tempPath = `${filePath}.${process.pid}.tmp`;
        try {
          await fs.writeFile(tempPath, JSON.stringify(snapshot, null, 2), "utf-8");
          await fs.rename(tempPath, filePath);
        } finally {
          await fs.rm(tempPath, { force: true });
        }
      });

    this.saveQueue = save;
    await save;
  }
}

export const settingsStore = new SettingsStore();
