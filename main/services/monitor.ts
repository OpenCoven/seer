import { ipcMain, logger } from "@glaze/core/backend";

import { detectActiveAgents } from "./agent-detector.js";
import { keepAwakeService } from "./keep-awake.js";
import { settingsStore } from "./settings-store.js";
import type { AgentMonitorState, KeepAwakeMode } from "./types.js";

const POLL_INTERVAL_MS = 3_000;

type StateListener = (state: AgentMonitorState) => void;

let pollTimer: ReturnType<typeof setInterval> | null = null;
let latestState: AgentMonitorState = {
  active: false,
  keepingAwake: false,
  keepAwakeMode: "system",
  agents: [],
  lastScanAt: 0,
};
let scanning = false;
const listeners = new Set<StateListener>();

function buildState(partial: Partial<AgentMonitorState> = {}): AgentMonitorState {
  latestState = {
    ...latestState,
    ...partial,
    keepingAwake: keepAwakeService.isActive(),
    keepAwakeMode: keepAwakeService.getMode(),
  };
  return latestState;
}

function publishState(): AgentMonitorState {
  const state = buildState();
  for (const listener of listeners) {
    try {
      listener(state);
    } catch (error) {
      logger.warn("monitor", "State listener failed", { error });
    }
  }
  ipcMain.broadcast("agents:state-changed", state);
  return state;
}

async function scanOnce(): Promise<AgentMonitorState> {
  if (scanning) {
    return latestState;
  }

  scanning = true;
  try {
    const agents = await detectActiveAgents();
    const active = agents.length > 0;
    keepAwakeService.setDesired(active);

    latestState = {
      active,
      keepingAwake: keepAwakeService.isActive(),
      keepAwakeMode: keepAwakeService.getMode(),
      agents,
      lastScanAt: Date.now(),
    };

    for (const listener of listeners) {
      try {
        listener(latestState);
      } catch (error) {
        logger.warn("monitor", "State listener failed", { error });
      }
    }
    ipcMain.broadcast("agents:state-changed", latestState);
    return latestState;
  } catch (error) {
    logger.error("monitor", "Agent scan failed", error);
    return latestState;
  } finally {
    scanning = false;
  }
}

export function onMonitorStateChange(listener: StateListener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

export function getMonitorState(): AgentMonitorState {
  return buildState();
}

export async function setKeepAwakeMode(mode: KeepAwakeMode): Promise<AgentMonitorState> {
  // Apply immediately so tray/settings update even if disk write is slow.
  keepAwakeService.setMode(mode);
  const state = publishState();

  try {
    await settingsStore.setKeepAwakeMode(mode);
  } catch (error) {
    logger.error("monitor", "Failed to persist keep-awake mode", error);
  }

  logger.info("monitor", "Keep-awake mode set", {
    mode,
    keepingAwake: keepAwakeService.isActive(),
  });
  return state;
}

export async function startMonitor(): Promise<void> {
  const settings = await settingsStore.load();
  keepAwakeService.setMode(settings.keepAwakeMode);
  latestState = buildState({ keepAwakeMode: settings.keepAwakeMode });

  await scanOnce();

  if (pollTimer) {
    clearInterval(pollTimer);
  }

  pollTimer = setInterval(() => {
    void scanOnce();
  }, POLL_INTERVAL_MS);

  logger.info("monitor", "Agent monitor started", { intervalMs: POLL_INTERVAL_MS });
}

export function stopMonitor(): void {
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
  keepAwakeService.dispose();
  latestState = buildState({
    active: false,
    agents: [],
    keepingAwake: false,
  });
  listeners.clear();
  logger.info("monitor", "Agent monitor stopped");
}
