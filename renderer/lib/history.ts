import type { AwakeSession, HistoryStats } from "../bridge/types";

export type { AgentUsage, AwakeSession, HistoryStats, KeepAwakeMode } from "../bridge/types";

export const EMPTY_STATS: HistoryStats = {
  totalAwakeMs: 0,
  todayAwakeMs: 0,
  sessionCount: 0,
  perAgent: [],
  currentSession: null,
  recentSessions: [],
};

/** "38s", "12m", "2h 14m" — compact, at most two units. */
export function formatDuration(ms: number): string {
  const totalSeconds = Math.max(0, Math.round(ms / 1000));
  if (totalSeconds < 60) return `${totalSeconds}s`;

  const totalMinutes = Math.floor(totalSeconds / 60);
  if (totalMinutes < 60) {
    const seconds = totalSeconds % 60;
    return seconds ? `${totalMinutes}m ${seconds}s` : `${totalMinutes}m`;
  }

  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return minutes ? `${hours}h ${minutes}m` : `${hours}h`;
}

/** "Today 2:14 PM", "Yesterday 9:10 AM", "Aug 6 2:14 PM". */
export function formatSessionTime(ts: number): string {
  const date = new Date(ts);
  const now = new Date();
  const time = date.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });

  if (date.toDateString() === now.toDateString()) return `Today ${time}`;

  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  if (date.toDateString() === yesterday.toDateString()) return `Yesterday ${time}`;

  const day = date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  return `${day} ${time}`;
}

/** Comma-joined agent names, busiest first. */
export function sessionAgentNames(session: AwakeSession): string {
  if (session.agents.length === 0) return "No agent recorded";
  return [...session.agents]
    .sort((a, b) => b.durationMs - a.durationMs)
    .map((agent) => agent.name)
    .join(", ");
}
