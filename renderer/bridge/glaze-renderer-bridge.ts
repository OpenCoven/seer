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

  function remember(snapshot: AppSnapshot): AppSnapshot {
    current = snapshot;
    return cloneSnapshot(snapshot);
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
    if (!current) {
      return;
    }

    const merged: AppSnapshot = {
      ...current,
      monitor: params as AgentMonitorState,
    };
    notifyListeners(remember(merged));
  });

  const unsubscribeHistory = ipc.onNotification("history:changed", (params) => {
    if (!current) {
      return;
    }

    const merged: AppSnapshot = {
      ...current,
      history: params as HistoryStats,
    };
    notifyListeners(remember(merged));
  });

  return {
    async getSnapshot(): Promise<AppSnapshot> {
      const snapshot = await fetchSnapshot();
      return remember(snapshot);
    },

    async setKeepAwakeMode(mode: KeepAwakeMode): Promise<AppSnapshot> {
      const monitor = await ipc.invoke<AgentMonitorState>("agents:setKeepAwakeMode", { mode });
      const base = current ?? (await fetchSnapshot());
      const merged: AppSnapshot = { ...base, monitor };
      return remember(merged);
    },

    async clearHistory(): Promise<AppSnapshot> {
      const history = await ipc.invoke<HistoryStats>("history:clear");
      const base = current ?? (await fetchSnapshot());
      const merged: AppSnapshot = { ...base, history };
      return remember(merged);
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
      const base = current ?? (await fetchSnapshot());
      return remember(base);
    },

    async openCurrentRelease(): Promise<void> {
      // No-op until Task 11 implements the update flow.
    },

    async quit(): Promise<void> {
      await ipc.invoke("app:quit");
    },

    disconnect(): void {
      unsubscribeAgents();
      unsubscribeHistory();
      listeners.clear();
      ipc.disconnect?.();
    },
  };
}
