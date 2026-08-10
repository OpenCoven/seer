/**
 * Shared domain types for Seer's renderer bridge.
 *
 * These types describe the wire contract between the renderer and either the
 * Glaze host (via IPC) or the standalone native host (via postMessage). Both
 * `renderer/bridge/glaze-renderer-bridge.ts` and
 * `renderer/bridge/standalone-renderer-bridge.ts` produce/consume values shaped
 * exactly like these.
 */

/** Protocol version stamped on every standalone bridge request/response/event. */
export const BRIDGE_VERSION = "seer.bridge.v1" as const;

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

export type AgentUsage = {
  id: string;
  name: string;
  durationMs: number;
};

export type AwakeSession = {
  id: string;
  startedAt: number;
  endedAt: number | null;
  durationMs: number;
  mode: KeepAwakeMode;
  agents: AgentUsage[];
};

export type HistoryStats = {
  totalAwakeMs: number;
  todayAwakeMs: number;
  sessionCount: number;
  perAgent: AgentUsage[];
  currentSession: AwakeSession | null;
  recentSessions: AwakeSession[];
};

export type UpdateState = {
  checking: boolean;
  availableVersion: string | null;
  releaseURL: string | null;
  lastCheckedAt: number | null;
};

export type Diagnostic = {
  id: string;
  message: string;
  occurredAt: number;
};

export type AppSnapshot = {
  monitor: AgentMonitorState;
  history: HistoryStats;
  update: UpdateState;
  diagnostics: Diagnostic[];
  appVersion: string;
};
