import type { RendererBridge } from "./renderer-bridge";
import type { AgentMonitorState, AppSnapshot, HistoryStats, KeepAwakeMode, UpdateState } from "./types";

/**
 * Minimal facade over the Glaze IPC bridge that this adapter depends on.
 * Injected so tests can supply a fake without touching `window.glazeAPI`.
 */
export interface GlazeIpcFacade {
  invoke<T = unknown>(channel: string, ...args: unknown[]): Promise<T>;
  onNotification(channel: string, callback: (params: unknown) => void): () => void;
  disconnect?: () => void;
}

type GlazeAppInfo = {
  name: string;
  version: string;
  environment: string;
};

function cloneMonitor(monitor: AgentMonitorState): AgentMonitorState {
  return {
    ...monitor,
    agents: monitor.agents.map((agent) => ({ ...agent })),
  };
}

function cloneHistory(history: HistoryStats): HistoryStats {
  return {
    ...history,
    perAgent: history.perAgent.map((usage) => ({ ...usage })),
    currentSession: history.currentSession
      ? {
          ...history.currentSession,
          agents: history.currentSession.agents.map((usage) => ({ ...usage })),
        }
      : null,
    recentSessions: history.recentSessions.map((session) => ({
      ...session,
      agents: session.agents.map((usage) => ({ ...usage })),
    })),
  };
}

function cloneSnapshot(snapshot: AppSnapshot): AppSnapshot {
  return {
    monitor: cloneMonitor(snapshot.monitor),
    history: cloneHistory(snapshot.history),
    update: { ...snapshot.update },
    diagnostics: snapshot.diagnostics.map((diagnostic) => ({ ...diagnostic })),
    appVersion: snapshot.appVersion,
  };
}

/**
 * Builds a full RendererBridge backed by the Glaze host. `getSnapshot`
 * fetches `agents:getState`, `history:getStats`, and `app:getInfo` (in that
 * order) and assembles them into one complete snapshot. Subsequent
 * `agents:state-changed` / `history:changed` notifications are merged into
 * the last known-good snapshot so subscribers always receive a complete,
 * immutably-cloned `AppSnapshot`.
 */
export function createGlazeRendererBridge(ipc: GlazeIpcFacade): RendererBridge {
  let current: AppSnapshot | null = null;
  let disconnected = false;
  const listeners = new Set<(snapshot: AppSnapshot) => void>();

  /**
   * Monotonic ordering for every async operation that can eventually apply
   * a snapshot to `current` (a `getSnapshot`/mutation call, or a live
   * agents/history notification). Each operation grabs its ticket via
   * `nextSequence()` at the moment it *starts*, so `appliedSequence` can
   * reject an update from an operation that started earlier but resolves
   * later than one that has already been applied — an older concurrent
   * fetch/mutation completion must never clobber a newer one.
   */
  let sequenceCounter = 0;
  let appliedSequence = 0;

  function nextSequence(): number {
    sequenceCounter += 1;
    return sequenceCounter;
  }

  /**
   * Independent generation counter for the `history` field specifically,
   * deliberately separate from `sequenceCounter`/`appliedSequence` above. An
   * agent scan tick kicks off a background `history:getStats` refresh (see
   * the `agents:state-changed` handler below); if that refresh's own
   * freshness were judged against the *general* sequence, a later, purely
   * monitor-only tick (which never changes `history` at all) would bump
   * `appliedSequence` past the refresh's ticket and make it look stale
   * relative to data that never actually changed. Tracking history
   * freshness in its own generation means only another history refresh, a
   * mutation that changes history (`clearHistory`), or a `history:changed`
   * notification can ever supersede a still in-flight refresh.
   */
  let historyGenCounter = 0;
  let appliedHistoryGen = 0;

  function nextHistoryGen(): number {
    historyGenCounter += 1;
    return historyGenCounter;
  }

  /**
   * Decides which `HistoryStats` value belongs in the next snapshot:
   * `candidate` if `gen` is at least as new as the last history update that
   * was actually applied, or the current known-good history otherwise
   * (never `undefined` — once `current` exists it always has a `history`).
   */
  function resolveHistory(candidate: HistoryStats, gen: number): HistoryStats {
    if (current === null || gen >= appliedHistoryGen) {
      appliedHistoryGen = gen;
      return candidate;
    }
    return current.history;
  }

  /**
   * A single-slot buffer per notification channel. Notifications that
   * arrive while `current` is still null (i.e. the very first `getSnapshot`
   * fetch is in flight) cannot be merged into a base snapshot yet, so they
   * are held here — only the newest one per channel — and merged in as soon
   * as a snapshot becomes available, instead of being silently dropped.
   */
  interface PendingNotification {
    seq: number;
    apply: (base: AppSnapshot) => AppSnapshot;
  }
  let pendingAgentsNotification: PendingNotification | null = null;
  let pendingHistoryNotification: PendingNotification | null = null;
  let pendingUpdateNotification: PendingNotification | null = null;

  function drainPendingNotifications(): void {
    if (current === null) {
      return;
    }
    const entries = [pendingAgentsNotification, pendingHistoryNotification, pendingUpdateNotification].filter(
      (entry): entry is PendingNotification => entry !== null,
    );
    if (entries.length === 0) {
      return;
    }
    entries.sort((a, b) => a.seq - b.seq);
    pendingAgentsNotification = null;
    pendingHistoryNotification = null;
    pendingUpdateNotification = null;
    for (const entry of entries) {
      if (entry.seq >= appliedSequence) {
        appliedSequence = entry.seq;
        current = entry.apply(current);
      }
    }
  }

  /**
   * Applies `snapshot` as the new current state unless a newer update
   * (higher sequence number) has already been applied, then drains any
   * notifications buffered while there was no current snapshot yet.
   * Always returns a clone of whatever ends up being the freshest known
   * snapshot — even if this particular call's own result was stale and
   * therefore not applied.
   */
  function commit(snapshot: AppSnapshot, seq: number): AppSnapshot {
    if (current === null || seq >= appliedSequence) {
      appliedSequence = seq;
      current = snapshot;
    }
    drainPendingNotifications();
    // Invariant: `current` cannot still be null here. `appliedSequence`
    // starts at 0 and every sequence number is >= 1, so the branch above
    // always executes (and sets `current`) the first time this runs.
    return cloneSnapshot(current!);
  }

  function notifyListeners(snapshot: AppSnapshot): void {
    if (disconnected) {
      // Disconnected: no listener should ever observe another emission,
      // even if something raced its way to calling this after teardown.
      return;
    }
    for (const listener of listeners) {
      listener(cloneSnapshot(snapshot));
    }
  }

  async function fetchSnapshot(): Promise<AppSnapshot> {
    const [monitor, history, update, info] = await Promise.all([
      ipc.invoke<AgentMonitorState>("agents:getState"),
      ipc.invoke<HistoryStats>("history:getStats"),
      ipc.invoke<UpdateState>("updates:getState"),
      ipc.invoke<GlazeAppInfo>("app:getInfo"),
    ]);

    return {
      monitor,
      history,
      update,
      diagnostics: [],
      appVersion: info.version,
    };
  }

  /**
   * Returns the current known-good snapshot, or bootstraps one via
   * `fetchSnapshot` if none exists yet. Used by mutations/`requestUpdateCheck`
   * that need *some* base snapshot to merge their own result into. The
   * bootstrap fetch's `history` is still routed through `resolveHistory` (with
   * its own generation ticket grabbed before the fetch) so it participates
   * correctly in history-freshness arbitration alongside any concurrent
   * refresh/notification, exactly like every other path that can produce a
   * `history` value.
   */
  async function ensureBase(): Promise<AppSnapshot> {
    if (current !== null) {
      return current;
    }
    const historyGen = nextHistoryGen();
    const fetched = await fetchSnapshot();
    const history = resolveHistory(fetched.history, historyGen);
    return { ...fetched, history };
  }

  const unsubscribeAgents = ipc.onNotification("agents:state-changed", (params) => {
    const monitor = params as AgentMonitorState;
    const seq = nextSequence();
    if (current === null) {
      // No base snapshot exists yet (the initial getSnapshot fetch is still
      // in flight) — buffer this notification instead of dropping it.
      pendingAgentsNotification = { seq, apply: (base) => ({ ...base, monitor }) };
      return;
    }

    const merged: AppSnapshot = { ...current, monitor };
    notifyListeners(commit(merged, seq));

    if (disconnected) {
      return;
    }

    // An agent scan tick can correspond to an in-progress awake session's
    // live duration ticking upward (the old RootView invalidated its
    // History view on every `agents:state-changed` for exactly this
    // reason). Refresh history stats in the background and emit a second
    // full snapshot once they arrive. This ticket is grabbed *now* (in its
    // own independent `historyGen` space, not the general `sequenceCounter`
    // above) so a later, purely monitor-only tick can never make this
    // still-in-flight refresh look stale — only a newer refresh, a
    // history-changing mutation, or a `history:changed` notification can.
    const historyGen = nextHistoryGen();
    ipc
      .invoke<HistoryStats>("history:getStats")
      .then((historyRaw) => {
        if (disconnected) {
          return;
        }
        // The *general* commit ticket is grabbed here, at resolution time —
        // this refresh's non-history fields (whatever `current` looks like
        // right now) are always the freshest available, so this commit
        // should never be treated as stale on the general axis. Only
        // `resolveHistory` (independent generation) decides whether the
        // fetched history itself is still the freshest one.
        const historySeq = nextSequence();
        const history = resolveHistory(historyRaw, historyGen);
        const base = current ?? merged;
        const refreshed: AppSnapshot = { ...base, history };
        notifyListeners(commit(refreshed, historySeq));
      })
      .catch(() => {
        // Best-effort background refresh: a rejected `history:getStats`
        // call must never surface as an unhandled rejection. The existing,
        // still-valid history value is simply kept until a future
        // refresh/mutation/notification succeeds.
      });
  });

  const unsubscribeHistory = ipc.onNotification("history:changed", (params) => {
    const historyRaw = params as HistoryStats;
    const seq = nextSequence();
    const historyGen = nextHistoryGen();
    if (current === null) {
      pendingHistoryNotification = {
        seq,
        apply: (base) => ({ ...base, history: resolveHistory(historyRaw, historyGen) }),
      };
      return;
    }

    const history = resolveHistory(historyRaw, historyGen);
    const merged: AppSnapshot = { ...current, history };
    notifyListeners(commit(merged, seq));
  });

  const unsubscribeUpdates = ipc.onNotification("updates:changed", (params) => {
    const update = params as UpdateState;
    const seq = nextSequence();
    if (current === null) {
      pendingUpdateNotification = {
        seq,
        apply: (base) => ({ ...base, update }),
      };
      return;
    }

    notifyListeners(commit({ ...current, update }, seq));
  });

  return {
    async getSnapshot(): Promise<AppSnapshot> {
      const seq = nextSequence();
      const historyGen = nextHistoryGen();
      const snapshot = await fetchSnapshot();
      const history = resolveHistory(snapshot.history, historyGen);
      return commit({ ...snapshot, history }, seq);
    },

    async setKeepAwakeMode(mode: KeepAwakeMode): Promise<AppSnapshot> {
      const seq = nextSequence();
      const monitor = await ipc.invoke<AgentMonitorState>("agents:setKeepAwakeMode", { mode });
      const base = await ensureBase();
      const merged: AppSnapshot = { ...base, monitor };
      return commit(merged, seq);
    },

    async clearHistory(): Promise<AppSnapshot> {
      const seq = nextSequence();
      const historyGen = nextHistoryGen();
      const historyRaw = await ipc.invoke<HistoryStats>("history:clear");
      const base = await ensureBase();
      const history = resolveHistory(historyRaw, historyGen);
      const merged: AppSnapshot = { ...base, history };
      return commit(merged, seq);
    },

    subscribe(listener: (snapshot: AppSnapshot) => void): () => void {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },

    async requestUpdateCheck(): Promise<AppSnapshot> {
      const seq = nextSequence();
      const update = await ipc.invoke<UpdateState>("updates:check");
      const base = await ensureBase();
      return commit({ ...base, update }, seq);
    },

    async openCurrentRelease(): Promise<void> {
      await ipc.invoke("updates:open");
    },

    async quit(): Promise<void> {
      await ipc.invoke("app:quit");
    },

    async hidePanel(): Promise<void> {
      await ipc.invoke("window:hidePanel");
    },

    disconnect(): void {
      disconnected = true;
      unsubscribeAgents();
      unsubscribeHistory();
      unsubscribeUpdates();
      listeners.clear();
      ipc.disconnect?.();
    },
  };
}
