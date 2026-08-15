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
  // Coalesces every concurrent cold-cache `load()` attempt (whether
  // called directly or via `mutate()`) into a single shared read, so
  // racing callers never each perform their own independent disk read
  // and never let a later-resolving read reset `this.cache` out from
  // under an earlier caller's already-applied change. Cleared once the
  // attempt settles unsuccessfully so a failed read never permanently
  // wedges later `load()`/`mutate()` calls behind the same rejection.
  private loadPromise: Promise<AppSettings> | null = null;
  private readonly resolveUserDataPath: () => string;
  private readonly readSettingsFile: (filePath: string) => Promise<string>;

  constructor(
    resolveUserDataPath: () => string = () => app.getPath("userData"),
    readSettingsFile: (filePath: string) => Promise<string> = (filePath) =>
      fs.readFile(filePath, "utf-8"),
  ) {
    this.resolveUserDataPath = resolveUserDataPath;
    this.readSettingsFile = readSettingsFile;
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

    if (!this.loadPromise) {
      this.loadPromise = this.performLoad();
    }

    try {
      return await this.loadPromise;
    } finally {
      if (!this.loaded) {
        // This attempt failed (or was superseded before completing) —
        // drop it so the next `load()` call starts a fresh attempt
        // instead of forever replaying the same rejection.
        this.loadPromise = null;
      }
    }
  }

  private async performLoad(): Promise<AppSettings> {
    try {
      const data = await this.readSettingsFile(await this.getSettingsPath());
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

  // Runs the entire ensure-loaded -> read-current -> derive-next ->
  // persist -> cache-commit transaction as a single job chained onto
  // `saveQueue`, so two concurrent setters can never both derive `next`
  // from the same stale `this.cache` snapshot and silently clobber one
  // another. `transform` only runs once this job is actually dequeued —
  // after every previously queued transaction has both persisted *and*
  // committed its own cache update — so it always sees the latest
  // value, not a stale one captured at call time.
  //
  // Critically, this job is chained onto `saveQueue` — and `saveQueue`
  // reassigned — synchronously, with no `await` beforehand (not even
  // for `this.load()`, which now runs *inside* the queued job instead
  // of before joining the queue). That fixes each caller's FIFO queue
  // position at the moment `mutate()` is called, not at whenever that
  // caller's own `load()` happens to resolve. With a cold (`!loaded`)
  // cache, the previous ordering let every concurrent caller
  // independently observe `!loaded`, each perform its own `load()`, and
  // join the queue only once that settled — so queue order (and thus
  // which change won) depended on read-completion timing rather than
  // call order, and whichever read resolved last could reset
  // `this.cache` back to stale disk contents after an earlier-queued
  // job had already applied and persisted a newer value on top of it.
  // Because `load()` itself now coalesces concurrent attempts through a
  // shared `loadPromise` (see above), only the first-queued job here
  // ever performs the actual disk read; every later job's `load()` call
  // simply resolves against the already-populated cache.
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
  private mutate(
    transform: (current: AppSettings) => AppSettings,
  ): Promise<AppSettings> {
    const job = this.saveQueue
      .catch(() => undefined)
      .then(async () => {
        await this.load();
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
