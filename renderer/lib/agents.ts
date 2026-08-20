import type { AgentMonitorState } from "../bridge/types";

export type { ActiveAgent, AgentActivitySource, AgentMonitorState, KeepAwakeMode } from "../bridge/types";

export const EMPTY_STATE: AgentMonitorState = {
  active: false,
  keepingAwake: false,
  keepAwakeMode: "system",
  agents: [],
  lastScanAt: 0,
};
