import { historyStore } from "../services/history-store.js";
import type { HistoryStats } from "../services/types.js";

export const historyHandlers = {
  getStats: async (): Promise<HistoryStats> => {
    return historyStore.getStats();
  },

  clear: async (): Promise<HistoryStats> => {
    return historyStore.clear();
  },
};
