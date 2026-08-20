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

export type AppSettings = {
  keepAwakeMode: KeepAwakeMode;
  includePrereleaseUpdates: boolean;
};

export type UpdateState = {
  checking: boolean;
  availableVersion: string | null;
  releaseURL: string | null;
  lastCheckedAt: number | null;
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
