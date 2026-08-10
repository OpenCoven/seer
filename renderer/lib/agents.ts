import type { AgentMonitorState, KeepAwakeMode } from "../bridge/types";

export type { ActiveAgent, AgentActivitySource, AgentMonitorState, KeepAwakeMode } from "../bridge/types";

export const EMPTY_STATE: AgentMonitorState = {
  active: false,
  keepingAwake: false,
  keepAwakeMode: "system",
  agents: [],
  lastScanAt: 0,
};

export async function fetchAgentState(): Promise<AgentMonitorState> {
  return await window.glazeAPI.glaze.ipc.invoke<AgentMonitorState>("agents:getState");
}

export async function updateKeepAwakeMode(mode: KeepAwakeMode): Promise<AgentMonitorState> {
  return await window.glazeAPI.glaze.ipc.invoke<AgentMonitorState>("agents:setKeepAwakeMode", {
    mode,
  });
}
