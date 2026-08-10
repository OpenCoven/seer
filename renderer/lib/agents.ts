export type KeepAwakeMode = "system" | "display";

export type AgentActivitySource = "process" | "session" | "both";

export type ActiveAgent = {
  id: string;
  name: string;
  detail: string;
  source: AgentActivitySource;
  pid?: number;
  cpuPercent?: number;
  lastActivityAt: number;
};

export type AgentMonitorState = {
  active: boolean;
  keepingAwake: boolean;
  keepAwakeMode: KeepAwakeMode;
  agents: ActiveAgent[];
  lastScanAt: number;
};

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
