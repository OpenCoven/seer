import { logger } from "@glaze/core/backend";

import { getMonitorState, setKeepAwakeMode } from "../services/monitor.js";
import type { AgentMonitorState, KeepAwakeMode } from "../services/types.js";

function isKeepAwakeMode(value: unknown): value is KeepAwakeMode {
  return value === "system" || value === "display";
}

export const agentHandlers = {
  getState: async (): Promise<AgentMonitorState> => {
    return getMonitorState();
  },

  setKeepAwakeMode: async (raw: unknown): Promise<AgentMonitorState> => {
    const mode = typeof raw === "object" && raw !== null ? (raw as { mode?: unknown }).mode : raw;

    if (!isKeepAwakeMode(mode)) {
      throw new Error('Invalid keep-awake mode. Expected "system" or "display".');
    }

    logger.info("agents", "Keep-awake mode changed", { mode });
    return await setKeepAwakeMode(mode);
  },
};
