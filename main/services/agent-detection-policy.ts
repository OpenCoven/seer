import * as path from "node:path";

import type { AgentActivitySource } from "./types.js";

/**
 * Detection policy:
 * - Prefer session/transcript turn state over process presence.
 * - Idle agent processes (terminal open, waiting for input) must NOT keep the Mac awake.
 * - Process CPU alone is never enough for agents that leave daemons running.
 *
 * This module holds the pure, filesystem-free pieces of agent detection:
 * family definitions, timestamp parsing, friendly labels/activity, and the
 * turn assessors. `agent-detector.ts` imports these and keeps the
 * filesystem/process orchestration (walking session directories, reading
 * process lists, talking to Cursor's sqlite state) around them.
 */
export const SESSION_CANDIDATE_WINDOW_MS = 10 * 60_000;
export const TURN_ACTIVE_GRACE_MS = 45_000;
export const TOOL_TURN_GRACE_MS = 3 * 60_000;
/**
 * Codex writes explicit turn boundaries (task_started … task_complete), so an
 * open turn can be trusted far longer than a bare event — long builds/tests can
 * run for minutes without a single rollout write. Bounded so a crashed app
 * can't caffeinate forever (the 10 min candidate window caps it anyway).
 */
export const CODEX_OPEN_TURN_GRACE_MS = 8 * 60_000;
export const CODEX_TAIL_QUIET_MS = 15_000;
export const PROCESS_ONLY_CPU_THRESHOLD = 25.0;
/** Generic logs only get a short window — better false negatives than caffeinating idle CLIs. */
export const GENERIC_MTIME_WINDOW_MS = 20_000;

/**
 * Grok CLI brackets every turn with turn_started … turn_ended in events.jsonl,
 * so an open turn is trustworthy for the same window as Codex. Streaming phase
 * events are extremely chatty, so the tail can flood past the turn boundary —
 * see the fallback in assessGrokTurn.
 */
export const GROK_OPEN_TURN_GRACE_MS = 8 * 60_000;
export const GROK_TAIL_QUIET_MS = 15_000;

export type AgentKind = {
  id: string;
  name: string;
  processMatchers: RegExp[];
  sessionRoots: string[];
  sessionExtensions: string[];
  /** Only consider session files with these exact names (e.g. Grok's events.jsonl). */
  sessionFileNames?: string[];
  /** How to interpret session files for this agent family. */
  sessionFormat: "claude" | "codex" | "grok" | "generic-mtime" | "cursor" | "none";
  /** If true, never treat bare process CPU as active work. */
  requireSessionTurn?: boolean;
  /** Allow high-CPU process fallback even when a session format exists (e.g. Cursor CLI). */
  allowProcessFallback?: boolean;
};

export type ProcessHit = {
  pid: number;
  cpuPercent: number;
  command: string;
};

export type SessionCandidate = {
  filePath: string;
  mtimeMs: number;
  label: string;
};

export type TurnAssessment = {
  active: boolean;
  lastActivityAt: number;
  reason: string;
};

export type ActiveTurnHit = TurnAssessment & {
  label?: string;
  filePath?: string;
  /** Stable identity within the agent kind (session path, composer key, pid). */
  identity: string;
};

/** Exactly the ten approved agent families, with their process/session policy. */
export const AGENT_KINDS: AgentKind[] = [
  {
    id: "claude-code",
    name: "Claude Code",
    processMatchers: [/(^|[/\s])claude(\s|$)/i, /@anthropic-ai\/claude-code/, /claude[-_]code/i],
    sessionRoots: [".claude/projects"],
    sessionExtensions: [".jsonl"],
    sessionFormat: "claude",
    requireSessionTurn: true,
  },
  {
    id: "codex",
    name: "Codex",
    processMatchers: [/(^|[/\s])codex(\s|$)/i, /@openai\/codex/],
    sessionRoots: [".codex/sessions"],
    sessionExtensions: [".jsonl"],
    sessionFormat: "codex",
    requireSessionTurn: true,
  },
  {
    id: "grok",
    name: "Grok",
    // The launcher lives in ~/.grok/bin; the real binary is ~/.grok/downloads/grok-<ver>-macos-*.
    processMatchers: [
      /(^|[/\s])grok(\s|$)/i,
      /\.grok\/(?:bin|downloads)\//i,
      /grok-\d+\.\d+\.\d+-macos/i,
    ],
    sessionRoots: [".grok/sessions"],
    sessionExtensions: [".jsonl"],
    // Sessions also hold chat_history/updates/rewind_points — only events.jsonl has turn state.
    sessionFileNames: ["events.jsonl"],
    sessionFormat: "grok",
    requireSessionTurn: true,
  },
  {
    id: "gemini",
    name: "Gemini CLI",
    processMatchers: [/(^|[/\s])gemini(\s|$)/i, /@google\/gemini-cli/],
    sessionRoots: [".gemini"],
    sessionExtensions: [".jsonl", ".json"],
    sessionFormat: "generic-mtime",
  },
  {
    id: "aider",
    name: "Aider",
    processMatchers: [/(^|[/\s])aider(\s|$)/i],
    sessionRoots: [],
    sessionExtensions: [],
    sessionFormat: "none",
  },
  {
    id: "opencode",
    name: "OpenCode",
    processMatchers: [/(^|[/\s])opencode(\s|$)/i],
    sessionRoots: [".local/share/opencode", ".config/opencode"],
    sessionExtensions: [".jsonl", ".json"],
    sessionFormat: "generic-mtime",
  },
  {
    id: "goose",
    name: "Goose",
    processMatchers: [/(^|[/\s])goose(\s|$)/i],
    sessionRoots: [".config/goose"],
    sessionExtensions: [".jsonl", ".json"],
    sessionFormat: "generic-mtime",
  },
  {
    id: "amp",
    name: "Amp",
    processMatchers: [/(^|[/\s])amp(\s|$)/i, /@sourcegraph\/amp/],
    sessionRoots: [],
    sessionExtensions: [],
    sessionFormat: "none",
  },
  {
    id: "cursor",
    name: "Cursor",
    // IDE agent is detected via composer state; process matchers cover the CLI only.
    // Do not match bare Cursor.app — it stays open while idle.
    processMatchers: [
      /(^|[/\s])cursor-agent(\s|$)/i,
      /cursor-agent-svc/i,
      /cursor(?:-agent)?(?:\.js)?\s+--agent\b/i,
    ],
    sessionRoots: [],
    sessionExtensions: [],
    sessionFormat: "cursor",
    allowProcessFallback: true,
  },
  {
    id: "continue",
    name: "Continue",
    processMatchers: [/continue-cli/i, /@continuedev\/cli/],
    sessionRoots: [".continue/sessions"],
    sessionExtensions: [".jsonl", ".json"],
    sessionFormat: "generic-mtime",
  },
];

export const CLAUDE_METADATA_TYPES = new Set([
  "last-prompt",
  "mode",
  "permission-mode",
  "queue-operation",
  "ai-title",
  "custom-title",
  "agent-name",
  "pr-link",
  "file-history-snapshot",
]);

export function titleCaseWords(raw: string): string {
  return raw
    .split(/[\s_./]+/)
    .filter(Boolean)
    .map((word) => {
      if (/^[A-Z0-9]{2,}$/.test(word)) return word;
      if (word.length <= 2 && word === word.toLowerCase()) return word;
      return word.charAt(0).toUpperCase() + word.slice(1);
    })
    .join(" ");
}

/** Turn path slugs / bundle ids into short display names. */
export function humanizeProjectName(raw: string): string {
  let value = raw.trim();
  if (!value) return "";

  // my-project-local-1pwq7g9n → my-project
  value = value.replace(/-local-[a-z0-9]+$/i, "");
  // strip trailing build-ish ids
  value = value.replace(/-[a-f0-9]{6,}$/i, "");
  value = value.replace(/[_./]+/g, "-");
  value = value.replace(/-+/g, "-").replace(/^-|-$/g, "");

  const titled = titleCaseWords(value.replace(/-/g, " "));
  return titled || raw;
}

/** Grok sessions live at .grok/sessions/<url-encoded cwd>/<session id>/events.jsonl. */
export function grokProjectLabel(filePath: string): string {
  const parts = filePath.split(path.sep);
  const encodedCwd = parts[parts.length - 3];
  if (!encodedCwd) return "";

  let decoded: string;
  try {
    decoded = decodeURIComponent(encodedCwd);
  } catch {
    return "";
  }

  const base = path.basename(decoded.replace(/[/\\]+$/, ""));
  return base ? humanizeProjectName(base) : "";
}

export function friendlySessionLabel(filePath: string): string {
  const parts = filePath.split(path.sep);
  const file = parts[parts.length - 1] ?? "session";
  const parent = parts[parts.length - 2] ?? "";

  // Grok's session id folder is a uuid — the project comes from the encoded cwd above it.
  if (file === "events.jsonl") return grokProjectLabel(filePath);

  // Codex rollouts live under sessions/YYYY/MM/DD — the project comes from the
  // session's cwd instead, so don't label the agent with a date folder.
  if (file.startsWith("rollout-")) return "";

  if (parent.startsWith("-")) {
    const withoutLeading = parent.replace(/^-/, "");
    const [primary = withoutLeading] = withoutLeading.split("--");
    const segments = primary.split("-").filter(Boolean);

    const appsIdx = segments.lastIndexOf("apps");
    if (appsIdx >= 0 && appsIdx < segments.length - 1) {
      return humanizeProjectName(segments.slice(appsIdx + 1).join("-"));
    }

    const codeIdx = segments.lastIndexOf("Code");
    if (codeIdx >= 0 && codeIdx < segments.length - 1) {
      return humanizeProjectName(segments.slice(codeIdx + 1).join("-"));
    }

    return humanizeProjectName(segments.slice(-3).join("-")) || "Project";
  }

  if (parent && parent !== "sessions" && parent !== "projects") {
    return humanizeProjectName(parent);
  }

  return humanizeProjectName(file.replace(/\.jsonl?$/i, "")) || "Session";
}

/** Internal turn reasons → short, human activity copy. */
export function friendlyActivity(reason: string | undefined, processOnly: boolean): string {
  if (processOnly) return "Busy";
  if (!reason) return "Working";

  const normalized = reason.toLowerCase();
  if (
    normalized.includes("tool_use") ||
    normalized.includes("tool_call") ||
    normalized.includes("function_call")
  ) {
    return "Running tools";
  }
  if (normalized.includes("awaiting model") || normalized.includes("tool result")) {
    return "Thinking";
  }
  if (normalized.includes("reasoning") || normalized.includes("thinking")) {
    return "Thinking";
  }
  if (
    normalized.includes("assistant") ||
    normalized.includes("agent_message") ||
    normalized.includes("agent_reasoning")
  ) {
    return "Writing";
  }
  if (normalized.includes("user prompt") || normalized.includes("started")) {
    return "Started";
  }
  if (normalized.includes("streaming")) return "Writing";
  if (normalized.includes("generating") || normalized.includes("continuation")) {
    return "Writing";
  }
  if (normalized.includes("recent session")) return "Active";
  if (normalized.startsWith("stale")) return "Wrapping up";
  return "Working";
}

export function buildFriendlyDetail(options: {
  projectLabel?: string;
  reason?: string;
  processOnly?: boolean;
}): string {
  const activity = friendlyActivity(options.reason, options.processOnly === true);
  if (options.projectLabel) {
    return `${options.projectLabel} · ${activity}`;
  }
  return activity;
}

export function matchAgentKind(command: string): AgentKind | null {
  for (const kind of AGENT_KINDS) {
    if (kind.processMatchers.some((re) => re.test(command))) {
      return kind;
    }
  }
  return null;
}

export function parseTimestamp(value: unknown, fallbackMs: number): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value > 1e12 ? value : value * 1000;
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallbackMs;
}

export function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : null;
}

export function assessClaudeTurn(events: unknown[], mtimeMs: number, now: number): TurnAssessment {
  for (let i = events.length - 1; i >= 0; i -= 1) {
    const event = events[i];
    if (!event || typeof event !== "object") continue;
    const record = event as Record<string, unknown>;
    const type = typeof record.type === "string" ? record.type : "";

    if (CLAUDE_METADATA_TYPES.has(type)) continue;

    const timestamp = parseTimestamp(record.timestamp, mtimeMs);
    const age = now - timestamp;

    if (type === "system") {
      const subtype = typeof record.subtype === "string" ? record.subtype : "";
      if (subtype === "turn_duration" || subtype === "away_summary") {
        return { active: false, lastActivityAt: timestamp, reason: `turn ended (${subtype})` };
      }
      continue;
    }

    if (type === "assistant") {
      const message =
        record.message && typeof record.message === "object"
          ? (record.message as Record<string, unknown>)
          : null;
      const stopReason =
        (typeof message?.stop_reason === "string" && message.stop_reason) ||
        (typeof record.stop_reason === "string" && record.stop_reason) ||
        "";

      if (stopReason === "end_turn" || stopReason === "stop_sequence") {
        return { active: false, lastActivityAt: timestamp, reason: "end_turn" };
      }

      if (stopReason === "tool_use") {
        return {
          active: age <= TOOL_TURN_GRACE_MS,
          lastActivityAt: timestamp,
          reason: age <= TOOL_TURN_GRACE_MS ? "tool_use in progress" : "stale tool_use",
        };
      }

      // Streaming / incomplete assistant chunk without an end marker.
      return {
        active: age <= TURN_ACTIVE_GRACE_MS,
        lastActivityAt: timestamp,
        reason: age <= TURN_ACTIVE_GRACE_MS ? "assistant output" : "stale assistant output",
      };
    }

    if (type === "user") {
      const hasToolResult = "toolUseResult" in record;
      if (hasToolResult) {
        return {
          active: age <= TOOL_TURN_GRACE_MS,
          lastActivityAt: timestamp,
          reason: age <= TOOL_TURN_GRACE_MS ? "awaiting model after tool" : "stale tool result",
        };
      }

      // Fresh human prompt starts a turn.
      return {
        active: age <= TURN_ACTIVE_GRACE_MS,
        lastActivityAt: timestamp,
        reason: age <= TURN_ACTIVE_GRACE_MS ? "user prompt" : "stale user prompt",
      };
    }
  }

  // No turn events — file touch alone is not work.
  return { active: false, lastActivityAt: mtimeMs, reason: "no turn events" };
}

/** Codex rollout events that open a turn (both CLI and Codex Desktop). */
export const CODEX_TURN_START_EVENTS = new Set(["task_started", "user_message", "user_input"]);
/** Events that close a turn. */
export const CODEX_TURN_END_EVENTS = new Set([
  "task_complete",
  "turn_aborted",
  "turn_failed",
  "shutdown_complete",
]);
/** Model output in progress. */
export const CODEX_STREAM_EVENTS = new Set([
  "agent_message",
  "agent_message_delta",
  "agent_message_content_delta",
  "agent_reasoning",
  "agent_reasoning_delta",
  "agent_reasoning_section_break",
  "agent_reasoning_raw_content",
  "agent_reasoning_raw_content_delta",
]);
/** The turn is parked on a human decision — that is not the agent working. */
export const CODEX_APPROVAL_EVENTS = new Set([
  "exec_approval_request",
  "apply_patch_approval_request",
  "elicitation_request",
]);
/** Bookkeeping that says nothing about whether a turn is running. */
export const CODEX_META_EVENTS = new Set([
  "token_count",
  "thread_settings_applied",
  "session_configured",
  "notification",
  "background_event",
]);

export type CodexSignalRole = "start" | "end" | "stream" | "tool" | "await-user" | "meta";
export type CodexSignal = { role: CodexSignalRole; kind: string; at: number };

/** Tool traffic keeps arriving under new names — match the shape, not a fixed list. */
export function isCodexToolEventName(name: string): boolean {
  return /(_begin|_end|_delta|_call|_output|_result)$/.test(name);
}

export function classifyCodexEvent(record: Record<string, unknown>): {
  role: CodexSignalRole;
  kind: string;
} {
  const type = typeof record.type === "string" ? record.type : "";
  const payload = asRecord(record.payload);
  const payloadType = typeof payload?.type === "string" ? payload.type : "";

  if (type === "event_msg") {
    if (CODEX_META_EVENTS.has(payloadType)) return { role: "meta", kind: payloadType };
    if (CODEX_TURN_END_EVENTS.has(payloadType)) return { role: "end", kind: payloadType };
    if (CODEX_TURN_START_EVENTS.has(payloadType)) return { role: "start", kind: payloadType };
    if (CODEX_APPROVAL_EVENTS.has(payloadType)) return { role: "await-user", kind: payloadType };
    if (CODEX_STREAM_EVENTS.has(payloadType)) return { role: "stream", kind: payloadType };
    if (isCodexToolEventName(payloadType)) return { role: "tool", kind: payloadType };
    return { role: "meta", kind: payloadType || type };
  }

  if (type === "response_item") {
    if (payloadType === "reasoning") return { role: "stream", kind: "agent_reasoning" };
    if (payloadType === "message") {
      const role = typeof payload?.role === "string" ? payload.role : "";
      if (role === "assistant") return { role: "stream", kind: "agent_message" };
      if (role === "user") return { role: "start", kind: "user_message" };
      return { role: "meta", kind: "message" };
    }
    if (isCodexToolEventName(payloadType)) return { role: "tool", kind: payloadType };
    return { role: "meta", kind: payloadType || type };
  }

  return { role: "meta", kind: type };
}

export function codexSignalReason(signal: CodexSignal | null): string {
  if (!signal) return "turn in progress";
  if (signal.role === "tool") {
    return /(_end|_output|_result)$/.test(signal.kind)
      ? "awaiting model after tool"
      : `tool_call ${signal.kind}`;
  }
  if (signal.role === "stream") return signal.kind;
  return "user prompt";
}

/** Codex records the working directory in session_meta / turn_context. */
export function codexProjectLabelFromPath(cwd: string): string | undefined {
  const base = path.basename(cwd.replace(/[/\\]+$/, ""));
  return base ? humanizeProjectName(base) : undefined;
}

export function codexProjectLabel(events: unknown[]): string | undefined {
  for (let i = events.length - 1; i >= 0; i -= 1) {
    const record = asRecord(events[i]);
    if (!record) continue;
    const payload = asRecord(record.payload);
    const cwd =
      (typeof payload?.cwd === "string" && payload.cwd) ||
      (typeof record.cwd === "string" && record.cwd) ||
      "";
    if (cwd) {
      const label = codexProjectLabelFromPath(cwd);
      if (label) return label;
    }
  }
  return undefined;
}

/**
 * Codex (CLI and Desktop) brackets every turn with task_started … task_complete.
 * Reading only the newest event misses whole phases — the gap between a prompt
 * and the first reasoning chunk, or a long shell command — so track the turn
 * boundaries instead and use the newest signal only for the status wording.
 */
export function assessCodexTurn(
  events: unknown[],
  mtimeMs: number,
  now: number,
): TurnAssessment & { label?: string } {
  const label = codexProjectLabel(events);

  let startedAt = -1;
  let endedAt = -1;
  let lastActivityAt = -1;
  let latest: CodexSignal | null = null;

  for (const event of events) {
    const record = asRecord(event);
    if (!record) continue;

    const { role, kind } = classifyCodexEvent(record);
    if (role === "meta") continue;

    const at = parseTimestamp(record.timestamp, mtimeMs);
    if (at > lastActivityAt) lastActivityAt = at;
    if (role === "start" && at > startedAt) startedAt = at;
    if (role === "end" && at > endedAt) endedAt = at;
    if (!latest || at >= latest.at) latest = { role, kind, at };
  }

  if (lastActivityAt < 0) {
    // Tail held nothing recognizable (huge single records) — trust fresh writes only.
    const age = now - mtimeMs;
    return {
      active: age <= CODEX_TAIL_QUIET_MS,
      lastActivityAt: mtimeMs,
      reason: age <= CODEX_TAIL_QUIET_MS ? "recent session write" : "no turn events",
      label,
    };
  }

  const age = now - lastActivityAt;

  if (latest?.role === "await-user") {
    return { active: false, lastActivityAt, reason: "waiting for approval", label };
  }

  if (startedAt > endedAt) {
    const active = age <= CODEX_OPEN_TURN_GRACE_MS;
    const reason = codexSignalReason(latest);
    return { active, lastActivityAt, reason: active ? reason : `stale ${reason}`, label };
  }

  // Turn is closed; only output written after the end marker still counts.
  if (latest && latest.at > endedAt && (latest.role === "stream" || latest.role === "tool")) {
    const grace = latest.role === "tool" ? TOOL_TURN_GRACE_MS : TURN_ACTIVE_GRACE_MS;
    const reason = codexSignalReason(latest);
    return { active: age <= grace, lastActivityAt, reason, label };
  }

  return { active: false, lastActivityAt, reason: endedAt >= 0 ? "turn complete" : "idle", label };
}

export type GrokSignalRole = "start" | "end" | "stream" | "tool" | "await-user" | "meta";
export type GrokSignal = { role: GrokSignalRole; kind: string; at: number };

export const GROK_PHASE_SIGNALS: Record<string, { role: GrokSignalRole; kind: string }> = {
  waiting_for_model: { role: "stream", kind: "awaiting model" },
  streaming_reasoning: { role: "stream", kind: "reasoning" },
  streaming_text: { role: "stream", kind: "streaming text" },
  tool_execution: { role: "tool", kind: "tool_call" },
  permission_prompt: { role: "await-user", kind: "permission prompt" },
};

export function classifyGrokEvent(record: Record<string, unknown>): {
  role: GrokSignalRole;
  kind: string;
} {
  const type = typeof record.type === "string" ? record.type : "";
  const toolName = typeof record.tool_name === "string" ? record.tool_name : "";

  switch (type) {
    case "turn_started":
      return { role: "start", kind: "user prompt" };
    case "turn_ended":
      return { role: "end", kind: "turn complete" };
    case "permission_requested":
      return { role: "await-user", kind: "permission prompt" };
    case "permission_resolved":
    case "loop_started":
    case "first_token":
      return { role: "stream", kind: "awaiting model" };
    case "tool_started":
      return { role: "tool", kind: toolName ? `tool_call ${toolName}` : "tool_call" };
    case "tool_completed":
      return { role: "tool", kind: "awaiting model after tool" };
    case "phase_changed": {
      const phase = typeof record.phase === "string" ? record.phase : "";
      return GROK_PHASE_SIGNALS[phase] ?? { role: "meta", kind: phase || "phase" };
    }
    default:
      return { role: "meta", kind: type };
  }
}

/**
 * Grok CLI ("grok", incl. the grok-build fork) writes turn_started … turn_ended plus
 * fine-grained phase_changed events. Turn boundaries decide active/idle; the newest
 * signal only picks the status wording. An unresolved permission_requested means Grok
 * is waiting on the human, which must never keep the Mac awake.
 */
export function assessGrokTurn(events: unknown[], mtimeMs: number, now: number): TurnAssessment {
  let startedAt = -1;
  let endedAt = -1;
  let lastActivityAt = -1;
  let latest: GrokSignal | null = null;

  for (const event of events) {
    const record = asRecord(event);
    if (!record) continue;

    const { role, kind } = classifyGrokEvent(record);
    if (role === "meta") continue;

    const at = parseTimestamp(record.ts, mtimeMs);
    if (at > lastActivityAt) lastActivityAt = at;
    if (role === "start" && at > startedAt) startedAt = at;
    if (role === "end" && at > endedAt) endedAt = at;
    if (!latest || at >= latest.at) latest = { role, kind, at };
  }

  if (lastActivityAt < 0) {
    const age = now - mtimeMs;
    return {
      active: age <= GROK_TAIL_QUIET_MS,
      lastActivityAt: mtimeMs,
      reason: age <= GROK_TAIL_QUIET_MS ? "recent session write" : "no turn events",
    };
  }

  const age = now - lastActivityAt;
  const reason = latest?.kind ?? "turn in progress";

  if (latest?.role === "await-user") {
    return { active: false, lastActivityAt, reason: "waiting for approval" };
  }

  if (startedAt > endedAt) {
    const active = age <= GROK_OPEN_TURN_GRACE_MS;
    return { active, lastActivityAt, reason: active ? reason : `stale ${reason}` };
  }

  // Long streaming turns emit thousands of phase events, so the tail can begin after
  // turn_started. Fall back to the newest signal with the short grace instead.
  const noBoundaryInTail = startedAt < 0 && endedAt < 0;
  const outputAfterEnd = latest !== null && latest.at > endedAt;

  if (
    (noBoundaryInTail || outputAfterEnd) &&
    latest &&
    (latest.role === "stream" || latest.role === "tool")
  ) {
    const grace = latest.role === "tool" ? TOOL_TURN_GRACE_MS : TURN_ACTIVE_GRACE_MS;
    return { active: age <= grace, lastActivityAt, reason };
  }

  return { active: false, lastActivityAt, reason: endedAt >= 0 ? "turn complete" : "idle" };
}

export function assessGenericMtime(mtimeMs: number, now: number): TurnAssessment {
  const age = now - mtimeMs;
  return {
    active: age <= GENERIC_MTIME_WINDOW_MS,
    lastActivityAt: mtimeMs,
    reason: age <= GENERIC_MTIME_WINDOW_MS ? "recent session write" : "stale session write",
  };
}

export type CursorComposerRecord = {
  status?: unknown;
  name?: unknown;
  subtitle?: unknown;
  lastUpdatedAt?: unknown;
  createdAt?: unknown;
  conversationCheckpointLastUpdatedAt?: unknown;
  unifiedMode?: unknown;
  isContinuationInProgress?: unknown;
  generatingBubbleIds?: unknown;
  workspaceIdentifier?: unknown;
  fullConversationHeadersOnly?: unknown;
};

export type CursorConversationHeader = {
  type?: unknown;
  createdAt?: unknown;
  grouping?: unknown;
};

export const CURSOR_RUNNING_TOOL_STATUSES = new Set([
  "loading",
  "running",
  "pending",
  "in_progress",
  "inProgress",
]);

export function cursorProjectLabel(record: CursorComposerRecord): string | undefined {
  const workspace = record.workspaceIdentifier;
  if (workspace && typeof workspace === "object") {
    const ws = workspace as Record<string, unknown>;
    const uri = ws.uri && typeof ws.uri === "object" ? (ws.uri as Record<string, unknown>) : null;
    const fsPath =
      (typeof uri?.fsPath === "string" && uri.fsPath) ||
      (typeof uri?.path === "string" && uri.path) ||
      (typeof ws.id === "string" && !/^[a-f0-9]{16,}$/i.test(ws.id) ? ws.id : "");
    if (fsPath) {
      const base = path.basename(fsPath.replace(/[/\\]+$/, ""));
      if (base) return humanizeProjectName(base);
    }
  }

  if (typeof record.name === "string" && record.name.trim()) {
    return record.name.trim();
  }
  return undefined;
}

export function cursorHeaderGrouping(header: CursorConversationHeader): Record<string, unknown> {
  return header.grouping && typeof header.grouping === "object"
    ? (header.grouping as Record<string, unknown>)
    : {};
}

/**
 * Cursor often leaves composer status stuck at "completed" on disk while a turn
 * is still running (especially during shell/tool waits). Prefer conversation
 * headers: an open user turn without turnDurationMs, or a tool still loading.
 */
export function assessCursorComposerRecord(
  record: CursorComposerRecord,
  now: number,
): TurnAssessment & { label?: string } {
  const status = typeof record.status === "string" ? record.status : "none";
  const generatingIds = Array.isArray(record.generatingBubbleIds) ? record.generatingBubbleIds : [];
  const continuation = record.isContinuationInProgress === true;
  const label = cursorProjectLabel(record);

  let lastActivityAt = parseTimestamp(
    record.conversationCheckpointLastUpdatedAt ?? record.lastUpdatedAt ?? record.createdAt,
    now,
  );

  if (status === "generating" || continuation || generatingIds.length > 0) {
    let reason = "generating";
    if (generatingIds.length > 0) reason = "generating bubbles";
    else if (continuation) reason = "continuation in progress";
    else if (typeof record.unifiedMode === "string" && record.unifiedMode === "agent") {
      reason = "agent generating";
    }
    return { active: true, lastActivityAt, reason, label };
  }

  const headers = Array.isArray(record.fullConversationHeadersOnly)
    ? (record.fullConversationHeadersOnly as CursorConversationHeader[])
    : [];

  let openUserTurnAt: number | null = null;
  let sawCompletedTurnAfterUser = false;
  let openTurnTouchesTools = false;
  let runningTool = false;

  for (const header of headers) {
    const createdAt = parseTimestamp(header.createdAt, lastActivityAt);
    if (createdAt > lastActivityAt) lastActivityAt = createdAt;

    const grouping = cursorHeaderGrouping(header);
    const toolStatus =
      typeof grouping.toolFormerStatus === "string" ? grouping.toolFormerStatus.toLowerCase() : "";
    const shellStatus =
      typeof grouping.shellStatus === "string" ? grouping.shellStatus.toLowerCase() : "";

    if (
      CURSOR_RUNNING_TOOL_STATUSES.has(toolStatus) ||
      CURSOR_RUNNING_TOOL_STATUSES.has(shellStatus)
    ) {
      runningTool = true;
      openTurnTouchesTools = true;
      sawCompletedTurnAfterUser = false;
    }

    // Cursor bubble types: 1 = user, 2 = assistant/tool/thinking
    if (header.type === 1) {
      openUserTurnAt = createdAt;
      sawCompletedTurnAfterUser = false;
      openTurnTouchesTools = false;
      continue;
    }

    if (openUserTurnAt == null) continue;

    if (typeof grouping.turnDurationMs === "number") {
      // Final assistant bubble for the turn.
      sawCompletedTurnAfterUser = true;
      openTurnTouchesTools = false;
      continue;
    }

    if (
      toolStatus === "completed" ||
      shellStatus === "success" ||
      shellStatus === "completed" ||
      shellStatus === "error" ||
      shellStatus === "failed"
    ) {
      // Tool finished but the turn may still stream a final reply.
      openTurnTouchesTools = true;
      sawCompletedTurnAfterUser = false;
      continue;
    }

    // Thinking / streaming text / other assistant bubbles before turnDurationMs.
    sawCompletedTurnAfterUser = false;
  }

  if (runningTool) {
    return {
      active: true,
      lastActivityAt,
      reason: "tool_call in progress",
      label,
    };
  }

  if (openUserTurnAt != null && !sawCompletedTurnAfterUser) {
    const age = now - lastActivityAt;
    const grace = openTurnTouchesTools ? TOOL_TURN_GRACE_MS : TURN_ACTIVE_GRACE_MS;
    if (age <= grace) {
      return {
        active: true,
        lastActivityAt,
        reason: openTurnTouchesTools ? "awaiting model after tool" : "user prompt",
        label,
      };
    }
    return {
      active: false,
      lastActivityAt,
      reason: openTurnTouchesTools ? "stale tool turn" : "stale user prompt",
      label,
    };
  }

  return {
    active: false,
    lastActivityAt,
    reason: status === "completed" ? "completed" : status === "aborted" ? "aborted" : "idle",
    label,
  };
}


/**
 * A single fixture-oracle input, exactly describing one row loaded from
 * `tests/fixtures/agent-detection/expected.json`. This union covers every
 * shape the shared fixture corpus produces: parsed session-turn events
 * (Claude/Codex/Grok), a bare mtime (Gemini/OpenCode/Goose/Continue), a
 * Cursor composer record, or a process CPU sample (Aider/Amp/Cursor CLI).
 * Deliberately fixture/test-oriented and pure: it carries only already-
 * parsed data. Loading and parsing the referenced fixture file is the
 * caller's job (`tests/agent-detection-parity.test.mjs` on the TS side,
 * `TurnAssessorsTests.swift` on the Swift side) — this module never reads
 * the filesystem or live runtime data.
 */
export type DetectionFixture =
  | {
      kind: "session";
      family: string;
      format: "claude" | "codex" | "grok";
      identity: string;
      mtimeMs: number;
      events: unknown[];
    }
  | {
      kind: "session";
      family: string;
      format: "generic-mtime";
      identity: string;
      mtimeMs: number;
    }
  | {
      kind: "session";
      family: string;
      format: "cursor";
      identity: string;
      record: CursorComposerRecord;
    }
  | {
      kind: "process";
      family: string;
      pid: number;
      cpuPercent: number;
    };

export type DetectionAssessment = {
  active: boolean;
  source: AgentActivitySource;
  detail: string;
  id: string;
};

/**
 * Fixture-only turn assessor: assesses one already-parsed detection fixture
 * (never touches disk, never reads `Date.now()`) using exactly the same pure
 * turn-classification policy above. Used solely by
 * `tests/agent-detection-parity.test.mjs` to characterize this module
 * against the shared oracle in `tests/fixtures/agent-detection/expected.json`.
 */
export function assessDetectionFixture(fixture: DetectionFixture, now: number): DetectionAssessment {
  if (fixture.kind === "process") {
    const active = fixture.cpuPercent >= PROCESS_ONLY_CPU_THRESHOLD;
    return {
      active,
      source: "process",
      detail: buildFriendlyDetail({ processOnly: true }),
      id: `${fixture.family}:pid:${fixture.pid}`,
    };
  }

  if (fixture.format === "cursor") {
    const assessment = assessCursorComposerRecord(fixture.record, now);
    return {
      active: assessment.active,
      source: "session",
      detail: buildFriendlyDetail({ projectLabel: assessment.label, reason: assessment.reason }),
      id: `${fixture.family}:${fixture.identity}`,
    };
  }

  let assessment: TurnAssessment & { label?: string };
  if (fixture.format === "generic-mtime") {
    assessment = assessGenericMtime(fixture.mtimeMs, now);
  } else if (fixture.format === "claude") {
    assessment = assessClaudeTurn(fixture.events, fixture.mtimeMs, now);
  } else if (fixture.format === "grok") {
    assessment = assessGrokTurn(fixture.events, fixture.mtimeMs, now);
  } else {
    assessment = assessCodexTurn(fixture.events, fixture.mtimeMs, now);
  }

  const label = assessment.label ?? friendlySessionLabel(fixture.identity);
  return {
    active: assessment.active,
    source: "session",
    detail: buildFriendlyDetail({ projectLabel: label, reason: assessment.reason }),
    id: `${fixture.family}:${fixture.identity}`,
  };
}
