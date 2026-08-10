import type { RendererBridge } from "./renderer-bridge";
import type { AgentMonitorState, AppSnapshot, HistoryStats, KeepAwakeMode } from "./types";

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

  function drainPendingNotifications(): void {
    if (current === null) {
      return;
    }
    const entries = [pendingAgentsNotification, pendingHistoryNotification].filter(
      (entry): entry is PendingNotification => entry !== null,
    );
    if (entries.length === 0) {
      return;
    }
    entries.sort((a, b) => a.seq - b.seq);
    pendingAgentsNotification = null;
    pendingHistoryNotification = null;
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
    for (const listener of listeners) {
      listener(cloneSnapshot(snapshot));
    }
  }

  async function fetchSnapshot(): Promise<AppSnapshot> {
    const [monitor, history, info] = await Promise.all([
      ipc.invoke<AgentMonitorState>("agents:getState"),
      ipc.invoke<HistoryStats>("history:getStats"),
      ipc.invoke<GlazeAppInfo>("app:getInfo"),
    ]);

    return {
      monitor,
      history,
      update: {
        checking: false,
        availableVersion: null,
        releaseURL: null,
        lastCheckedAt: null,
      },
      diagnostics: [],
      appVersion: info.version,
    };
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

    // An agent scan tick can correspond to an in-progress awake session's
    // live duration ticking upward (the old RootView invalidated its
    // History view on every `agents:state-changed` for exactly this
    // reason). Refresh history stats in the background and emit a second
    // full snapshot once they arrive, using a fresh sequence ticket so a
    // slow refresh can never clobber a newer mutation/notification/fetch
    // that lands before it resolves.
    const historySeq = nextSequence();
    void ipc.invoke<HistoryStats>("history:getStats").then((history) => {
      const base = current ?? merged;
      const refreshed: AppSnapshot = { ...base, history };
      notifyListeners(commit(refreshed, historySeq));
    });
  });

  const unsubscribeHistory = ipc.onNotification("history:changed", (params) => {
    const history = params as HistoryStats;
    const seq = nextSequence();
    if (current === null) {
      pendingHistoryNotification = { seq, apply: (base) => ({ ...base, history }) };
      return;
    }

    const merged: AppSnapshot = { ...current, history };
    notifyListeners(commit(merged, seq));
  });

  return {
    async getSnapshot(): Promise<AppSnapshot> {
      const seq = nextSequence();
      const snapshot = await fetchSnapshot();
      return commit(snapshot, seq);
    },

    async setKeepAwakeMode(mode: KeepAwakeMode): Promise<AppSnapshot> {
      const seq = nextSequence();
      const monitor = await ipc.invoke<AgentMonitorState>("agents:setKeepAwakeMode", { mode });
      const base = current ?? (await fetchSnapshot());
      const merged: AppSnapshot = { ...base, monitor };
      return commit(merged, seq);
    },

    async clearHistory(): Promise<AppSnapshot> {
      const seq = nextSequence();
      const history = await ipc.invoke<HistoryStats>("history:clear");
      const base = current ?? (await fetchSnapshot());
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
      // Update checks are unavailable until Task 11 wires the real update
      // channel; return the current known-good snapshot unchanged.
      const seq = nextSequence();
      const base = current ?? (await fetchSnapshot());
      return commit(base, seq);
    },

    async openCurrentRelease(): Promise<void> {
      // No-op until Task 11 implements the update flow.
    },

    async quit(): Promise<void> {
      await ipc.invoke("app:quit");
    },

    async hidePanel(): Promise<void> {
      await ipc.invoke("window:hidePanel");
    },

    disconnect(): void {
      unsubscribeAgents();
      unsubscribeHistory();
      listeners.clear();
      ipc.disconnect?.();
    },
  };
}
