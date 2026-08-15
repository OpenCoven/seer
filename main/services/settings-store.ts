import * as fs from "node:fs/promises";
import * as path from "node:path";

import { app, logger } from "@glaze/core/backend";

import type { AppSettings, KeepAwakeMode } from "./types.js";

const DEFAULT_SETTINGS: AppSettings = {
  keepAwakeMode: "system",
  includePrereleaseUpdates: false,
};

function isFileNotFound(error: unknown): boolean {
  return (
    error instanceof Error &&
    "code" in error &&
    (error as NodeJS.ErrnoException).code === "ENOENT"
  );
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
    keepAwakeMode: isKeepAwakeMode(record.keepAwakeMode)
      ? record.keepAwakeMode
      : DEFAULT_SETTINGS.keepAwakeMode,
    includePrereleaseUpdates:
      typeof record.includePrereleaseUpdates === "boolean"
        ? record.includePrereleaseUpdates
        : DEFAULT_SETTINGS.includePrereleaseUpdates,
  };
}

class SettingsStore {
  private cache: AppSettings = { ...DEFAULT_SETTINGS };
  private settingsPath: string | null = null;
  private saveQueue: Promise<void> = Promise.resolve();
  private loaded = false;
  private readonly resolveUserDataPath: () => string;

  constructor(
    resolveUserDataPath: () => string = () => app.getPath("userData"),
  ) {
    this.resolveUserDataPath = resolveUserDataPath;
  }

  private async getSettingsPath(): Promise<string> {
    if (!this.settingsPath) {
      const userDataPath = this.resolveUserDataPath();
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
    return this.mutate((current) => ({ ...current, keepAwakeMode: mode }));
  }

  async setIncludePrereleaseUpdates(value: boolean): Promise<AppSettings> {
    return this.mutate((current) => ({
      ...current,
      includePrereleaseUpdates: value,
    }));
  }

  // Runs the entire read-current -> derive-next -> persist -> cache-commit
  // transaction as a single job chained onto `saveQueue`, so two
  // concurrent setters can never both derive `next` from the same stale
  // `this.cache` snapshot and silently clobber one another. Unlike the
  // previous implementation (which computed `next` from `this.cache`
  // *before* ever entering the queue), `transform` only runs once this
  // job is actually dequeued — after every previously queued transaction
  // has both persisted *and* committed its own cache update — so it
  // always sees the latest value, not a stale one captured at call time.
  //
  // Only commits `this.cache` once the write has actually succeeded — a
  // failed persist must never leave `get()` reporting a value that was
  // never durably saved. A failure here also must never leave
  // `saveQueue` permanently rejected (which would poison every later
  // call): the `.catch(() => undefined)` below means each job always
  // starts from a resolved queue regardless of whether the previous job
  // threw, and the queue is advanced to a settled (always-resolved)
  // continuation of this job rather than to the job's own
  // (possibly-rejected) promise, while the rejection itself still
  // propagates to this call's own caller via the returned `job` promise.
  private async mutate(
    transform: (current: AppSettings) => AppSettings,
  ): Promise<AppSettings> {
    await this.load();
    const job = this.saveQueue
      .catch(() => undefined)
      .then(async () => {
        const next = transform(this.cache);
        await this.writeToDisk(next);
        this.cache = next;
        return this.cache;
      });
    this.saveQueue = job.then(
      () => undefined,
      () => undefined,
    );
    return job;
  }

  private async writeToDisk(snapshot: AppSettings): Promise<void> {
    const filePath = await this.getSettingsPath();
    const tempPath = `${filePath}.${process.pid}.tmp`;
    try {
      await fs.writeFile(tempPath, JSON.stringify(snapshot, null, 2), "utf-8");
      await fs.rename(tempPath, filePath);
    } finally {
      await fs.rm(tempPath, { force: true });
    }
  }
}

export const settingsStore = new SettingsStore();
export { SettingsStore };
