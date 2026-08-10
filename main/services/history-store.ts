import * as fs from "node:fs";
import * as fsp from "node:fs/promises";
import * as path from "node:path";

import { app, ipcMain, logger } from "@glaze/core/backend";

import type { AgentMonitorState, AgentUsage, AwakeSession, HistoryStats } from "./types.js";

const HISTORY_VERSION = 1;
const POLL_INTERVAL_MS = 3_000;
/** Cap per-tick accumulation so paused timers (e.g. sleep) can't inflate totals. */
const MAX_TICK_DELTA_MS = POLL_INTERVAL_MS * 5;
/** Sessions shorter than this are noise (a single scan flip) — don't record them. */
const MIN_SESSION_MS = 1_000;
const MAX_SESSIONS = 100;
const MAX_RECENT_SESSIONS = 40;
const MAX_DAILY_KEYS = 60;
const SAVE_DEBOUNCE_MS = 5_000;

type AgentTotal = { name: string; durationMs: number };

type PersistedHistory = {
  version: number;
  totalAwakeMs: number;
  sessionCount: number;
  agentTotals: Record<string, AgentTotal>;
  daily: Record<string, number>;
  sessions: AwakeSession[];
};

function emptyData(): PersistedHistory {
  return {
    version: HISTORY_VERSION,
    totalAwakeMs: 0,
    sessionCount: 0,
    agentTotals: {},
    daily: {},
    sessions: [],
  };
}

function dayKey(ts: number): string {
  const d = new Date(ts);
  const year = d.getFullYear();
  const month = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function makeSessionId(startedAt: number): string {
  return `s_${startedAt}_${Math.random().toString(36).slice(2, 8)}`;
}

function isFileNotFound(error: unknown): boolean {
  return (
    error instanceof Error &&
    "code" in error &&
    (error as NodeJS.ErrnoException).code === "ENOENT"
  );
}

function isAgentUsage(value: unknown): value is AgentUsage {
  if (!value || typeof value !== "object") return false;
  const usage = value as AgentUsage;
  return (
    typeof usage.id === "string" &&
    typeof usage.name === "string" &&
    typeof usage.durationMs === "number"
  );
}

function isAwakeSession(value: unknown): value is AwakeSession {
  if (!value || typeof value !== "object") return false;
  const session = value as AwakeSession;
  return (
    typeof session.id === "string" &&
    typeof session.startedAt === "number" &&
    (session.endedAt === null || typeof session.endedAt === "number") &&
    typeof session.durationMs === "number" &&
    (session.mode === "system" || session.mode === "display") &&
    Array.isArray(session.agents) &&
    session.agents.every(isAgentUsage)
  );
}

function normalizeAgentTotals(value: unknown): Record<string, AgentTotal> {
  const out: Record<string, AgentTotal> = {};
  if (value && typeof value === "object") {
    for (const [id, raw] of Object.entries(value as Record<string, unknown>)) {
      if (raw && typeof raw === "object") {
        const total = raw as AgentTotal;
        if (typeof total.name === "string" && typeof total.durationMs === "number" && total.durationMs >= 0) {
          out[id] = { name: total.name, durationMs: total.durationMs };
        }
      }
    }
  }
  return out;
}

function normalizeDaily(value: unknown): Record<string, number> {
  const out: Record<string, number> = {};
  if (value && typeof value === "object") {
    for (const [key, raw] of Object.entries(value as Record<string, unknown>)) {
      if (typeof raw === "number" && raw >= 0) out[key] = raw;
    }
  }
  return out;
}

function normalize(value: unknown): PersistedHistory {
  if (!value || typeof value !== "object") return emptyData();
  const v = value as Partial<PersistedHistory>;
  return {
    version: HISTORY_VERSION,
    totalAwakeMs: typeof v.totalAwakeMs === "number" && v.totalAwakeMs >= 0 ? v.totalAwakeMs : 0,
    sessionCount: typeof v.sessionCount === "number" && v.sessionCount >= 0 ? v.sessionCount : 0,
    agentTotals: normalizeAgentTotals(v.agentTotals),
    daily: normalizeDaily(v.daily),
    sessions: Array.isArray(v.sessions)
      ? v.sessions.filter(isAwakeSession).slice(0, MAX_SESSIONS)
      : [],
  };
}

/**
 * Records how long the Mac was kept awake, per-agent working time, and a
 * timeline of recent awake sessions. Fed by the monitor's periodic state
 * ticks; aggregates are accumulated tick-by-tick so trimming the recent
 * session list never loses all-time totals.
 */
class HistoryStore {
  private data: PersistedHistory = emptyData();
  private current: AwakeSession | null = null;
  private lastTickAt = Date.now();
  private historyPath: string | null = null;
  private saveQueue: Promise<void> = Promise.resolve();
  private saveScheduled = false;
  private loaded = false;

  private resolvePath(): string {
    if (!this.historyPath) {
      const userDataPath = app.getPath("userData");
      fs.mkdirSync(userDataPath, { recursive: true });
      this.historyPath = path.join(userDataPath, "history.json");
    }
    return this.historyPath;
  }

  async init(): Promise<void> {
    if (this.loaded) return;
    try {
      const raw = await fsp.readFile(this.resolvePath(), "utf-8");
      this.data = normalize(JSON.parse(raw) as unknown);
    } catch (error) {
      if (!isFileNotFound(error)) {
        logger.error("history", "Failed to load history, starting fresh", error);
      }
      this.data = emptyData();
    }
    this.lastTickAt = Date.now();
    this.loaded = true;
    logger.info("history", "History store loaded", {
      sessions: this.data.sessions.length,
      totalAwakeMs: this.data.totalAwakeMs,
    });
  }

  recordState(state: AgentMonitorState): void {
    const now = Date.now();

    if (state.keepingAwake) {
      if (!this.current) {
        this.current = {
          id: makeSessionId(now),
          startedAt: now,
          endedAt: null,
          durationMs: 0,
          mode: state.keepAwakeMode,
          agents: [],
        };
      } else {
        const delta = Math.min(Math.max(now - this.lastTickAt, 0), MAX_TICK_DELTA_MS);
        if (delta > 0) {
          this.current.durationMs += delta;
          this.current.mode = state.keepAwakeMode;
          this.data.totalAwakeMs += delta;

          const key = dayKey(now);
          this.data.daily[key] = (this.data.daily[key] ?? 0) + delta;

          for (const agent of state.agents) {
            addAgentTime(this.current.agents, agent.id, agent.name, delta);
            const total = this.data.agentTotals[agent.id] ?? { name: agent.name, durationMs: 0 };
            total.durationMs += delta;
            total.name = agent.name;
            this.data.agentTotals[agent.id] = total;
          }

          this.scheduleSave();
        }
      }
    } else if (this.current) {
      this.closeCurrent(now);
      void this.saveNow();
      this.broadcast();
    }

    this.lastTickAt = now;
  }

  getStats(): HistoryStats {
    const perAgent = Object.entries(this.data.agentTotals)
      .map(([id, total]) => ({ id, name: total.name, durationMs: total.durationMs }))
      .sort((a, b) => b.durationMs - a.durationMs);

    return {
      totalAwakeMs: this.data.totalAwakeMs,
      todayAwakeMs: this.data.daily[dayKey(Date.now())] ?? 0,
      sessionCount: this.data.sessionCount,
      perAgent,
      currentSession: this.current ? cloneSession(this.current) : null,
      recentSessions: this.data.sessions.slice(0, MAX_RECENT_SESSIONS).map(cloneSession),
    };
  }

  clear(): HistoryStats {
    this.data = emptyData();
    this.current = null;
    this.lastTickAt = Date.now();
    void this.saveNow();
    const stats = this.getStats();
    ipcMain.broadcast("history:changed", stats);
    logger.info("history", "History cleared");
    return stats;
  }

  /** Synchronous close + write for use in before-quit handlers. */
  flush(): void {
    if (this.current) {
      this.closeCurrent(Date.now());
    }
    if (!this.loaded) return;
    try {
      this.trimDaily();
      const filePath = this.resolvePath();
      const tmp = `${filePath}.${process.pid}.flush.tmp`;
      fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2), "utf-8");
      fs.renameSync(tmp, filePath);
    } catch (error) {
      logger.error("history", "Failed to flush history on quit", error);
    }
  }

  private closeCurrent(now: number): void {
    if (!this.current) return;
    this.current.endedAt = now;
    if (this.current.durationMs >= MIN_SESSION_MS) {
      this.data.sessions.unshift(this.current);
      if (this.data.sessions.length > MAX_SESSIONS) {
        this.data.sessions.length = MAX_SESSIONS;
      }
      this.data.sessionCount += 1;
    }
    this.current = null;
  }

  private trimDaily(): void {
    const keys = Object.keys(this.data.daily);
    if (keys.length <= MAX_DAILY_KEYS) return;
    const keep = keys.sort().slice(-MAX_DAILY_KEYS);
    const next: Record<string, number> = {};
    for (const key of keep) {
      next[key] = this.data.daily[key]!;
    }
    this.data.daily = next;
  }

  private broadcast(): void {
    ipcMain.broadcast("history:changed", this.getStats());
  }

  private scheduleSave(): void {
    if (this.saveScheduled) return;
    this.saveScheduled = true;
    setTimeout(() => {
      this.saveScheduled = false;
      void this.saveNow();
    }, SAVE_DEBOUNCE_MS);
  }

  private async saveNow(): Promise<void> {
    this.trimDaily();
    const snapshot = JSON.stringify(this.data, null, 2);
    const filePath = this.resolvePath();
    this.saveQueue = this.saveQueue
      .catch(() => undefined)
      .then(async () => {
        const tmp = `${filePath}.${process.pid}.tmp`;
        try {
          await fsp.writeFile(tmp, snapshot, "utf-8");
          await fsp.rename(tmp, filePath);
        } catch (error) {
          logger.error("history", "Failed to persist history", error);
          await fsp.rm(tmp, { force: true }).catch(() => undefined);
        }
      });
    await this.saveQueue;
  }
}

function addAgentTime(list: AgentUsage[], id: string, name: string, delta: number): void {
  const existing = list.find((agent) => agent.id === id);
  if (existing) {
    existing.durationMs += delta;
    existing.name = name;
  } else {
    list.push({ id, name, durationMs: delta });
  }
}

function cloneSession(session: AwakeSession): AwakeSession {
  return { ...session, agents: session.agents.map((agent) => ({ ...agent })) };
}

export const historyStore = new HistoryStore();
