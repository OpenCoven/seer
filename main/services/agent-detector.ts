import { execFile } from "node:child_process";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { promisify } from "node:util";

import { logger } from "@glaze/core/backend";

import type { ActiveAgent, AgentActivitySource } from "./types.js";

const execFileAsync = promisify(execFile);

/**
 * Detection policy:
 * - Prefer session/transcript turn state over process presence.
 * - Idle agent processes (terminal open, waiting for input) must NOT keep the Mac awake.
 * - Process CPU alone is never enough for agents that leave daemons running.
 */
const SESSION_CANDIDATE_WINDOW_MS = 10 * 60_000;
const TURN_ACTIVE_GRACE_MS = 45_000;
const TOOL_TURN_GRACE_MS = 3 * 60_000;
/**
 * Codex writes explicit turn boundaries (task_started … task_complete), so an
 * open turn can be trusted far longer than a bare event — long builds/tests can
 * run for minutes without a single rollout write. Bounded so a crashed app
 * can't caffeinate forever (the 10 min candidate window caps it anyway).
 */
const CODEX_OPEN_TURN_GRACE_MS = 8 * 60_000;
const CODEX_TAIL_QUIET_MS = 15_000;
const CODEX_HEAD_SCAN_BYTES = 32_000;
const PROCESS_ONLY_CPU_THRESHOLD = 25;
const MAX_SESSION_WALK_DEPTH = 5;
const MAX_SESSION_FILES_PER_ROOT = 400;
const SESSION_TAIL_BYTES = 120_000;

/**
 * Grok CLI brackets every turn with turn_started … turn_ended in events.jsonl,
 * so an open turn is trustworthy for the same window as Codex. Streaming phase
 * events are extremely chatty, so the tail can flood past the turn boundary —
 * see the fallback in assessGrokTurn.
 */
const GROK_OPEN_TURN_GRACE_MS = 8 * 60_000;
const GROK_TAIL_QUIET_MS = 15_000;

/**
 * EXPERIMENTAL Raycast AI log hack (not a supported API).
 * Raycast encrypts ai.db; the only local mid-chat crumbs are debug logs:
 *   Track AI chat activity { activityType, source: "AiChat" }
 * UserMessage opens a turn; AssistantMessage closes it. During streaming the
 * log also floods ai.chatConversationsInvalidated + agent compaction checks.
 * Brittle across Raycast updates — kept for testing only.
 */
const RAYCAST_LOG_DIRS = [
  path.join("Library", "Logs", "com.raycast-x.macos.internal"),
  path.join("Library", "Logs", "com.raycast.macos"),
];
const RAYCAST_LOG_NAME_RE = /^raycast(?:-x)?-\d{4}-\d{2}-\d{2}/i;
const RAYCAST_OPEN_TURN_GRACE_MS = 5 * 60_000;
/** Only used to pick Writing vs Thinking while a turn is already open. */
const RAYCAST_STREAM_RECENT_MS = 8_000;
const RAYCAST_LOG_TAIL_BYTES = 250_000;

type AgentKind = {
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

type ProcessHit = {
  pid: number;
  cpuPercent: number;
  command: string;
};

type SessionCandidate = {
  filePath: string;
  mtimeMs: number;
  label: string;
};

type TurnAssessment = {
  active: boolean;
  lastActivityAt: number;
  reason: string;
};

const AGENT_KINDS: AgentKind[] = [
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

const CLAUDE_METADATA_TYPES = new Set([
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

function homePath(...parts: string[]): string {
  return path.join(os.homedir(), ...parts);
}

function titleCaseWords(raw: string): string {
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
function humanizeProjectName(raw: string): string {
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
function grokProjectLabel(filePath: string): string {
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

function friendlySessionLabel(filePath: string): string {
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
function friendlyActivity(reason: string | undefined, processOnly: boolean): string {
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

function buildFriendlyDetail(options: {
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

function matchAgentKind(command: string): AgentKind | null {
  for (const kind of AGENT_KINDS) {
    if (kind.processMatchers.some((re) => re.test(command))) {
      return kind;
    }
  }
  return null;
}

function parseTimestamp(value: unknown, fallbackMs: number): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value > 1e12 ? value : value * 1000;
  }
  if (typeof value === "string" && value.trim()) {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return fallbackMs;
}

async function listProcesses(): Promise<ProcessHit[]> {
  try {
    const { stdout } = await execFileAsync("/bin/ps", ["-axo", "pid=,pcpu=,args="], {
      timeout: 5_000,
      maxBuffer: 4 * 1024 * 1024,
      encoding: "utf-8",
    });

    const selfPid = process.pid;
    const hits: ProcessHit[] = [];

    for (const line of stdout.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      const match = trimmed.match(/^(\d+)\s+([0-9.]+)\s+(.+)$/);
      if (!match) continue;

      const pid = Number(match[1]);
      const cpuPercent = Number(match[2]);
      const command = match[3] ?? "";
      if (!Number.isFinite(pid) || !Number.isFinite(cpuPercent)) continue;
      if (pid === selfPid) continue;

      hits.push({ pid, cpuPercent, command });
    }

    return hits;
  } catch (error) {
    logger.warn("detector", "Failed to list processes", { error });
    return [];
  }
}

async function walkRecentSessions(
  root: string,
  extensions: string[],
  now: number,
  fileNames?: string[],
): Promise<SessionCandidate[]> {
  const hits: SessionCandidate[] = [];

  async function walk(dir: string, depth: number): Promise<void> {
    if (hits.length >= MAX_SESSION_FILES_PER_ROOT) return;
    if (depth > MAX_SESSION_WALK_DEPTH) return;

    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      if (hits.length >= MAX_SESSION_FILES_PER_ROOT) break;

      const fullPath = path.join(dir, entry.name);

      if (entry.isDirectory()) {
        if (entry.name === "node_modules" || entry.name === ".git" || entry.name === "cache") {
          continue;
        }
        // Skip subagent sidecar transcripts; parent session is the turn source of truth.
        if (entry.name === "subagents") continue;
        await walk(fullPath, depth + 1);
        continue;
      }

      if (!entry.isFile()) continue;
      if (fileNames && !fileNames.includes(entry.name)) continue;
      if (!extensions.some((ext) => entry.name.endsWith(ext))) continue;

      try {
        const stat = await fs.stat(fullPath);
        const age = now - stat.mtimeMs;
        if (age <= SESSION_CANDIDATE_WINDOW_MS) {
          hits.push({
            filePath: fullPath,
            mtimeMs: stat.mtimeMs,
            label: friendlySessionLabel(fullPath),
          });
        }
      } catch {
        // ignore
      }
    }
  }

  try {
    await fs.access(root);
  } catch {
    return hits;
  }

  await walk(root, 0);
  hits.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return hits;
}

async function readSessionTailLines(filePath: string): Promise<unknown[]> {
  const handle = await fs.open(filePath, "r");
  try {
    const stat = await handle.stat();
    const start = Math.max(0, stat.size - SESSION_TAIL_BYTES);
    const length = stat.size - start;
    if (length <= 0) return [];

    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, start);
    const text = buffer.toString("utf8");
    const lines = text.split("\n");
    // If we started mid-line, drop the first partial line.
    if (start > 0 && lines.length > 0) {
      lines.shift();
    }

    const parsed: unknown[] = [];
    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed.startsWith("{")) continue;
      try {
        parsed.push(JSON.parse(trimmed) as unknown);
      } catch {
        // skip corrupt/partial lines
      }
    }
    return parsed;
  } finally {
    await handle.close();
  }
}

function assessClaudeTurn(events: unknown[], mtimeMs: number, now: number): TurnAssessment {
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
const CODEX_TURN_START_EVENTS = new Set(["task_started", "user_message", "user_input"]);
/** Events that close a turn. */
const CODEX_TURN_END_EVENTS = new Set([
  "task_complete",
  "turn_aborted",
  "turn_failed",
  "shutdown_complete",
]);
/** Model output in progress. */
const CODEX_STREAM_EVENTS = new Set([
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
const CODEX_APPROVAL_EVENTS = new Set([
  "exec_approval_request",
  "apply_patch_approval_request",
  "elicitation_request",
]);
/** Bookkeeping that says nothing about whether a turn is running. */
const CODEX_META_EVENTS = new Set([
  "token_count",
  "thread_settings_applied",
  "session_configured",
  "notification",
  "background_event",
]);

type CodexSignalRole = "start" | "end" | "stream" | "tool" | "await-user" | "meta";
type CodexSignal = { role: CodexSignalRole; kind: string; at: number };

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" ? (value as Record<string, unknown>) : null;
}

/** Tool traffic keeps arriving under new names — match the shape, not a fixed list. */
function isCodexToolEventName(name: string): boolean {
  return /(_begin|_end|_delta|_call|_output|_result)$/.test(name);
}

function classifyCodexEvent(record: Record<string, unknown>): {
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

function codexSignalReason(signal: CodexSignal | null): string {
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
function codexProjectLabelFromPath(cwd: string): string | undefined {
  const base = path.basename(cwd.replace(/[/\\]+$/, ""));
  return base ? humanizeProjectName(base) : undefined;
}

function codexProjectLabel(events: unknown[]): string | undefined {
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

/** CLI sessions only write session_meta at the top of the file. */
async function readCodexSessionCwd(filePath: string): Promise<string | undefined> {
  try {
    const handle = await fs.open(filePath, "r");
    try {
      const buffer = Buffer.alloc(CODEX_HEAD_SCAN_BYTES);
      const { bytesRead } = await handle.read(buffer, 0, CODEX_HEAD_SCAN_BYTES, 0);
      const match = buffer.toString("utf8", 0, bytesRead).match(/"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"/);
      const cwd = match?.[1];
      return cwd ? codexProjectLabelFromPath(cwd.replace(/\\\//g, "/")) : undefined;
    } finally {
      await handle.close();
    }
  } catch {
    return undefined;
  }
}

/**
 * Codex (CLI and Desktop) brackets every turn with task_started … task_complete.
 * Reading only the newest event misses whole phases — the gap between a prompt
 * and the first reasoning chunk, or a long shell command — so track the turn
 * boundaries instead and use the newest signal only for the status wording.
 */
function assessCodexTurn(
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

type GrokSignalRole = "start" | "end" | "stream" | "tool" | "await-user" | "meta";
type GrokSignal = { role: GrokSignalRole; kind: string; at: number };

const GROK_PHASE_SIGNALS: Record<string, { role: GrokSignalRole; kind: string }> = {
  waiting_for_model: { role: "stream", kind: "awaiting model" },
  streaming_reasoning: { role: "stream", kind: "reasoning" },
  streaming_text: { role: "stream", kind: "streaming text" },
  tool_execution: { role: "tool", kind: "tool_call" },
  permission_prompt: { role: "await-user", kind: "permission prompt" },
};

function classifyGrokEvent(record: Record<string, unknown>): {
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
function assessGrokTurn(events: unknown[], mtimeMs: number, now: number): TurnAssessment {
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

function assessGenericMtime(mtimeMs: number, now: number): TurnAssessment {
  const age = now - mtimeMs;
  // Generic logs only get a short window — better false negatives than caffeinating idle CLIs.
  return {
    active: age <= 20_000,
    lastActivityAt: mtimeMs,
    reason: age <= 20_000 ? "recent session write" : "stale session write",
  };
}

async function assessSessionTurn(
  kind: AgentKind,
  candidate: SessionCandidate,
  now: number,
): Promise<TurnAssessment & { label?: string }> {
  if (kind.sessionFormat === "generic-mtime") {
    return assessGenericMtime(candidate.mtimeMs, now);
  }

  if (kind.sessionFormat === "none" || kind.sessionFormat === "cursor") {
    return { active: false, lastActivityAt: candidate.mtimeMs, reason: "no session format" };
  }

  try {
    const events = await readSessionTailLines(candidate.filePath);
    if (kind.sessionFormat === "claude") {
      return assessClaudeTurn(events, candidate.mtimeMs, now);
    }
    if (kind.sessionFormat === "grok") {
      return assessGrokTurn(events, candidate.mtimeMs, now);
    }
    if (kind.sessionFormat === "codex") {
      const assessment = assessCodexTurn(events, candidate.mtimeMs, now);
      if (assessment.active && !assessment.label) {
        const label = await readCodexSessionCwd(candidate.filePath);
        if (label) return { ...assessment, label };
      }
      return assessment;
    }
  } catch (error) {
    logger.debug("detector", "Failed to assess session turn", {
      filePath: candidate.filePath,
      error,
    });
  }

  return { active: false, lastActivityAt: candidate.mtimeMs, reason: "unreadable session" };
}

type CursorComposerRecord = {
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

type CursorConversationHeader = {
  type?: unknown;
  createdAt?: unknown;
  grouping?: unknown;
};

const CURSOR_RUNNING_TOOL_STATUSES = new Set([
  "loading",
  "running",
  "pending",
  "in_progress",
  "inProgress",
]);

function cursorProjectLabel(record: CursorComposerRecord): string | undefined {
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

function cursorHeaderGrouping(header: CursorConversationHeader): Record<string, unknown> {
  return header.grouping && typeof header.grouping === "object"
    ? (header.grouping as Record<string, unknown>)
    : {};
}

/**
 * Cursor often leaves composer status stuck at "completed" on disk while a turn
 * is still running (especially during shell/tool waits). Prefer conversation
 * headers: an open user turn without turnDurationMs, or a tool still loading.
 */
function assessCursorComposerRecord(
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

type ActiveTurnHit = TurnAssessment & {
  label?: string;
  filePath?: string;
  /** Stable identity within the agent kind (session path, composer key, pid). */
  identity: string;
};

/**
 * Cursor IDE stores composer/agent state in globalStorage state.vscdb
 * (cursorDiskKV composerData:*). Disk `status` is unreliable mid-turn, so we
 * also inspect conversation headers for open turns and running tools.
 * Returns every active composer so concurrent agents all appear in the menu.
 */
async function detectCursorComposerActivity(now: number): Promise<ActiveTurnHit[]> {
  const dbPath = path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Cursor",
    "User",
    "globalStorage",
    "state.vscdb",
  );

  try {
    await fs.access(dbPath);
  } catch {
    return [];
  }

  try {
    // Read-only URI so Cursor can keep the DB open while we poll.
    const dbUri = `file:${dbPath}?mode=ro`;
    // Recent composers only — full blobs are small but no need to scan ancient chats.
    const sinceMs = now - SESSION_CANDIDATE_WINDOW_MS;
    const { stdout } = await execFileAsync(
      "/usr/bin/sqlite3",
      [
        "-readonly",
        "-json",
        dbUri,
        `SELECT key, value FROM cursorDiskKV
         WHERE key LIKE 'composerData:%'
           AND value IS NOT NULL
           AND (
             json_extract(value, '$.status') = 'generating'
             OR json_extract(value, '$.isContinuationInProgress') = 1
             OR json_array_length(COALESCE(json_extract(value, '$.generatingBubbleIds'), '[]')) > 0
             OR COALESCE(json_extract(value, '$.conversationCheckpointLastUpdatedAt'), 0) >= ${sinceMs}
             OR COALESCE(json_extract(value, '$.lastUpdatedAt'), 0) >= ${sinceMs}
             OR COALESCE(json_extract(value, '$.createdAt'), 0) >= ${sinceMs}
           )`,
      ],
      {
        timeout: 4_000,
        maxBuffer: 8 * 1024 * 1024,
        encoding: "utf-8",
      },
    );

    const trimmed = stdout.trim();
    if (!trimmed || trimmed === "[]") return [];

    let rows: Array<{ key?: string; value?: string }> = [];
    try {
      rows = JSON.parse(trimmed) as Array<{ key?: string; value?: string }>;
    } catch (error) {
      logger.debug("detector", "Failed to parse Cursor composer rows", { error });
      return [];
    }

    const active: ActiveTurnHit[] = [];

    for (const row of rows) {
      if (typeof row.value !== "string" || !row.value) continue;

      let record: CursorComposerRecord;
      try {
        record = JSON.parse(row.value) as CursorComposerRecord;
      } catch {
        continue;
      }

      const assessment = assessCursorComposerRecord(record, now);
      if (!assessment.active) continue;

      const composerKey =
        typeof row.key === "string" && row.key.startsWith("composerData:")
          ? row.key.slice("composerData:".length)
          : typeof row.key === "string"
            ? row.key
            : `composer-${assessment.lastActivityAt}`;

      active.push({
        ...assessment,
        filePath: dbPath,
        identity: composerKey,
      });
    }

    active.sort((a, b) => b.lastActivityAt - a.lastActivityAt);
    return active;
  } catch (error) {
    logger.debug("detector", "Failed to read Cursor composer state", { error });
    return [];
  }
}

type RaycastChatEvent = {
  atMs: number;
  activityType: "UserMessage" | "AssistantMessage";
  source: string;
};

type RaycastStreamMark = {
  atMs: number;
  kind: "invalidate" | "compaction";
};

function parseRaycastLogStamp(timePart: string, day: { y: number; m: number; d: number }): number {
  const match = timePart.match(/^(\d{2}):(\d{2}):(\d{2})\.(\d{3})$/);
  if (!match) return Number.NaN;
  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  const seconds = Number(match[3]);
  const millis = Number(match[4]);
  // Interpret wall clock in the local timezone (Raycast logs use local time).
  return new Date(day.y, day.m - 1, day.d, hours, minutes, seconds, millis).getTime();
}

function dayFromMs(ms: number): { y: number; m: number; d: number } {
  const date = new Date(ms);
  return { y: date.getFullYear(), m: date.getMonth() + 1, d: date.getDate() };
}

function addDays(
  day: { y: number; m: number; d: number },
  delta: number,
): {
  y: number;
  m: number;
  d: number;
} {
  const date = new Date(day.y, day.m - 1, day.d + delta);
  return { y: date.getFullYear(), m: date.getMonth() + 1, d: date.getDate() };
}

async function findNewestRaycastLog(): Promise<{ filePath: string; mtimeMs: number } | null> {
  let best: { filePath: string; mtimeMs: number } | null = null;

  for (const rel of RAYCAST_LOG_DIRS) {
    const dir = homePath(rel);
    let entries;
    try {
      entries = await fs.readdir(dir, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      if (!entry.isFile()) continue;
      if (!entry.name.endsWith(".log")) continue;
      if (!RAYCAST_LOG_NAME_RE.test(entry.name)) continue;

      const filePath = path.join(dir, entry.name);
      try {
        const stat = await fs.stat(filePath);
        if (!best || stat.mtimeMs > best.mtimeMs) {
          best = { filePath, mtimeMs: stat.mtimeMs };
        }
      } catch {
        // ignore
      }
    }
  }

  return best;
}

async function readFileTail(filePath: string, maxBytes: number): Promise<string> {
  const handle = await fs.open(filePath, "r");
  try {
    const stat = await handle.stat();
    const size = stat.size;
    const start = size > maxBytes ? size - maxBytes : 0;
    const length = size - start;
    if (length <= 0) return "";
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, start);
    return buffer.toString("utf8");
  } finally {
    await handle.close();
  }
}

/**
 * Experimental: infer Raycast AI chat mid-turn from local debug logs.
 * Returns at most one synthetic agent when an open AiChat turn looks live.
 */
async function detectRaycastLogActivity(now: number): Promise<ActiveAgent[]> {
  const newest = await findNewestRaycastLog();
  if (!newest) return [];

  // Entire log file cold for longer than an open turn → definitely idle.
  if (now - newest.mtimeMs > RAYCAST_OPEN_TURN_GRACE_MS) return [];

  let tail: string;
  try {
    tail = await readFileTail(newest.filePath, RAYCAST_LOG_TAIL_BYTES);
  } catch (error) {
    logger.debug("detector", "Failed to read Raycast log tail", {
      filePath: newest.filePath,
      error,
    });
    return [];
  }
  if (!tail) return [];

  // Tail-only parse: track day offsets within the tail, then anchor the last
  // stamp near the file mtime (filename start date is wrong for multi-day logs).
  let dayOffset = 0;
  let lastTimeKey = -1;

  type PendingChat = {
    timePart: string;
    dayOffset: number;
    activityType?: "UserMessage" | "AssistantMessage";
    source?: string;
  };
  type RawChat = {
    timePart: string;
    dayOffset: number;
    activityType: "UserMessage" | "AssistantMessage";
    source: string;
  };
  type RawStream = {
    timePart: string;
    dayOffset: number;
    kind: "invalidate" | "compaction";
  };

  const rawChats: RawChat[] = [];
  const rawStreams: RawStream[] = [];

  const lines = tail.split("\n");
  let pending: PendingChat | null = null;

  const stampRe = /^\[(?:info|debug|error|warn)\s+(\d{2}:\d{2}:\d{2}\.\d{3})\]/;

  const noteStamp = (timePart: string): { timePart: string; dayOffset: number } | null => {
    const match = timePart.match(/^(\d{2}):(\d{2}):(\d{2})/);
    if (!match) return null;
    const timeKey = Number(match[1]) * 3600 + Number(match[2]) * 60 + Number(match[3]);
    if (lastTimeKey >= 0 && timeKey + 60 < lastTimeKey) {
      dayOffset += 1;
    }
    lastTimeKey = timeKey;
    return { timePart, dayOffset };
  };

  for (const line of lines) {
    const stampMatch = line.match(stampRe);
    if (stampMatch) {
      if (pending?.activityType && pending.source) {
        rawChats.push({
          timePart: pending.timePart,
          dayOffset: pending.dayOffset,
          activityType: pending.activityType,
          source: pending.source,
        });
      }
      pending = null;

      const stamped = noteStamp(stampMatch[1] ?? "");
      if (!stamped) continue;

      if (line.includes("Track AI chat activity")) {
        pending = { ...stamped };
        continue;
      }

      if (line.includes("ai.chatConversationsInvalidated")) {
        rawStreams.push({ ...stamped, kind: "invalidate" });
        continue;
      }

      if (line.includes("[ai] [agent] Auto-compaction check")) {
        rawStreams.push({ ...stamped, kind: "compaction" });
        continue;
      }

      continue;
    }

    if (!pending) continue;

    const typeMatch = line.match(/activityType:\s*"(UserMessage|AssistantMessage)"/);
    if (typeMatch) {
      pending.activityType = typeMatch[1] as "UserMessage" | "AssistantMessage";
    }
    const sourceMatch = line.match(/source:\s*"([^"]+)"/);
    if (sourceMatch) {
      pending.source = sourceMatch[1];
    }
    if (line.trim() === "}") {
      if (pending.activityType && pending.source) {
        rawChats.push({
          timePart: pending.timePart,
          dayOffset: pending.dayOffset,
          activityType: pending.activityType,
          source: pending.source,
        });
      }
      pending = null;
    }
  }

  if (pending?.activityType && pending.source) {
    rawChats.push({
      timePart: pending.timePart,
      dayOffset: pending.dayOffset,
      activityType: pending.activityType,
      source: pending.source,
    });
  }

  const lastRaw =
    rawStreams.length > 0
      ? rawStreams[rawStreams.length - 1]
      : rawChats.length > 0
        ? rawChats[rawChats.length - 1]
        : null;
  if (!lastRaw) return [];

  // Choose base day so the last tail stamp lands closest to file mtime.
  const mtimeDay = dayFromMs(newest.mtimeMs);
  let bestBase = mtimeDay;
  let bestErr = Number.POSITIVE_INFINITY;
  for (const delta of [0, -1, 1, -2, 2, -3, 3, -4, 4, -5, 5, -6, 6]) {
    const lastDay = addDays(mtimeDay, delta);
    const abs = parseRaycastLogStamp(lastRaw.timePart, lastDay);
    if (!Number.isFinite(abs)) continue;
    const err = Math.abs(abs - newest.mtimeMs);
    if (err < bestErr) {
      bestErr = err;
      bestBase = addDays(lastDay, -lastRaw.dayOffset);
    }
  }

  const toAbs = (timePart: string, offset: number): number =>
    parseRaycastLogStamp(timePart, addDays(bestBase, offset));

  const chatEvents: RaycastChatEvent[] = rawChats.map((event) => ({
    atMs: toAbs(event.timePart, event.dayOffset),
    activityType: event.activityType,
    source: event.source,
  }));
  const streamMarks: RaycastStreamMark[] = rawStreams.map((event) => ({
    atMs: toAbs(event.timePart, event.dayOffset),
    kind: event.kind,
  }));

  // Ignore title-generation noise; only real chat turns matter.
  const aiChatEvents = chatEvents.filter((event) => event.source === "AiChat");

  let lastUser: RaycastChatEvent | null = null;
  let lastAssistant: RaycastChatEvent | null = null;
  for (const event of aiChatEvents) {
    if (event.activityType === "UserMessage") lastUser = event;
    else lastAssistant = event;
  }

  const lastStream = streamMarks.length > 0 ? streamMarks[streamMarks.length - 1]! : null;

  const clampAt = (atMs: number): number => {
    if (!Number.isFinite(atMs)) return newest.mtimeMs;
    if (atMs > now + 60_000) return newest.mtimeMs;
    return atMs;
  };

  const userAt = lastUser ? clampAt(lastUser.atMs) : null;
  const assistantAt = lastAssistant ? clampAt(lastAssistant.atMs) : null;
  const streamAt = lastStream ? clampAt(lastStream.atMs) : null;

  const openTurn = userAt != null && (assistantAt == null || userAt > assistantAt);

  let active = false;
  let reason = "idle";
  let lastActivityAt = newest.mtimeMs;

  // AssistantMessage closes the turn immediately — do not keep alive on leftover
  // stream invalidation floods (those linger ~seconds after the reply finishes).
  if (openTurn && userAt != null) {
    const age = now - userAt;
    if (age <= RAYCAST_OPEN_TURN_GRACE_MS) {
      active = true;
      lastActivityAt = userAt;
      reason = "user prompt";

      // Fresher stream crumbs only refine copy while the turn is still open.
      if (streamAt != null && streamAt >= userAt && now - streamAt <= RAYCAST_STREAM_RECENT_MS) {
        lastActivityAt = streamAt;
        reason = "streaming";
      }
    }
  }

  if (!active) return [];

  logger.debug("detector", "Raycast log hack detected activity", {
    filePath: newest.filePath,
    reason,
    openTurn,
    userAt,
    assistantAt,
    streamAt,
  });

  return [
    {
      id: "raycast:ai-chat",
      name: "Raycast AI",
      detail: buildFriendlyDetail({ reason }),
      source: "session",
      lastActivityAt,
    },
  ];
}

export async function detectActiveAgents(now = Date.now()): Promise<ActiveAgent[]> {
  const processes = await listProcesses();

  const processByKind = new Map<string, ProcessHit[]>();
  for (const proc of processes) {
    const kind = matchAgentKind(proc.command);
    if (!kind) continue;
    const list = processByKind.get(kind.id) ?? [];
    list.push(proc);
    processByKind.set(kind.id, list);
  }

  const agents: ActiveAgent[] = [];

  for (const kind of AGENT_KINDS) {
    const kindProcesses = processByKind.get(kind.id) ?? [];
    const topProcess = [...kindProcesses].sort((a, b) => b.cpuPercent - a.cpuPercent)[0];

    const activeTurns: ActiveTurnHit[] = [];

    if (kind.sessionFormat === "cursor") {
      activeTurns.push(...(await detectCursorComposerActivity(now)));
    } else if (kind.sessionFormat !== "none") {
      const candidates: SessionCandidate[] = [];
      for (const root of kind.sessionRoots) {
        candidates.push(
          ...(await walkRecentSessions(
            homePath(root),
            kind.sessionExtensions,
            now,
            kind.sessionFileNames,
          )),
        );
      }
      candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);

      // Assess freshest sessions; keep every active turn so concurrent agents all show.
      for (const candidate of candidates.slice(0, 24)) {
        const assessment = await assessSessionTurn(kind, candidate, now);
        if (!assessment.active) continue;
        activeTurns.push({
          ...assessment,
          label: assessment.label || candidate.label,
          filePath: candidate.filePath,
          identity: candidate.filePath,
        });
      }
    }

    if (activeTurns.length > 0) {
      const source: AgentActivitySource = topProcess ? "both" : "session";
      for (const turn of activeTurns) {
        agents.push({
          id: `${kind.id}:${turn.identity}`,
          name: kind.name,
          detail: buildFriendlyDetail({
            projectLabel: turn.label,
            reason: turn.reason,
          }),
          source,
          pid: topProcess?.pid,
          cpuPercent: topProcess?.cpuPercent,
          lastActivityAt: turn.lastActivityAt,
        });
      }
      continue;
    }

    // Process-only fallback for agents without reliable session logs.
    // Intentionally strict: idle CLIs often sit at a few % CPU.
    // Cursor CLI is allowed as fallback alongside IDE composer detection.
    const allowProcessFallback =
      !kind.requireSessionTurn &&
      (kind.sessionFormat === "none" || kind.allowProcessFallback === true);

    if (!allowProcessFallback) {
      continue;
    }

    const busyProcesses = kindProcesses.filter(
      (proc) => proc.cpuPercent >= PROCESS_ONLY_CPU_THRESHOLD,
    );
    for (const proc of busyProcesses) {
      agents.push({
        id: `${kind.id}:pid:${proc.pid}`,
        name: kind.name,
        detail: buildFriendlyDetail({ processOnly: true }),
        source: "process",
        pid: proc.pid,
        cpuPercent: proc.cpuPercent,
        lastActivityAt: now,
      });
    }
  }

  // Experimental Raycast AI detection via local debug logs (see constants).
  try {
    agents.push(...(await detectRaycastLogActivity(now)));
  } catch (error) {
    logger.debug("detector", "Raycast log hack failed", { error });
  }

  agents.sort((a, b) => b.lastActivityAt - a.lastActivityAt);
  return agents;
}
