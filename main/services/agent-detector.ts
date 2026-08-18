import { execFile } from "node:child_process";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { promisify } from "node:util";

import { logger } from "@glaze/core/backend";

import {
  AGENT_KINDS,
  assessClaudeTurn,
  assessCodexTurn,
  assessCursorComposerRecord,
  assessGenericMtime,
  assessGrokTurn,
  buildFriendlyDetail,
  codexProjectLabelFromPath,
  CURSOR_MAX_ACTIVE_CANDIDATES,
  CURSOR_MAX_BUBBLE_LOOKUPS,
  CURSOR_MAX_INSPECTED_ROWS,
  CURSOR_MAX_KEY_BYTES,
  CURSOR_MAX_TOTAL_DECODED_VALUE_BYTES,
  CURSOR_MAX_VALUE_BYTES,
  CURSOR_SQLITE_BUSY_TIMEOUT_MS,
  CURSOR_SQLITE_QUERY_DEADLINE_MS,
  cursorRelevantBubbleIds,
  friendlySessionLabel,
  isRecentTimestamp,
  matchAgentKind,
  PROCESS_ONLY_CPU_THRESHOLD,
  SESSION_CANDIDATE_WINDOW_MS,
  TOOL_TURN_GRACE_MS,
  type AgentKind,
  type CursorBubbleRecord,
  type CursorComposerRecord,
  type TurnAssessment,
} from "./agent-detection-policy.js";
import type { ActiveAgent, AgentActivitySource } from "./types.js";

const execFileAsync = promisify(execFile);

/**
 * IO-bound session/process scanning for agent detection. Pure policy
 * (agent definitions, timestamp parsing, friendly labels, turn assessors,
 * and the CPU threshold) lives in `agent-detection-policy.ts` — see that
 * module for the shared detection-policy contract. This module owns every
 * filesystem read, process listing, and SQLite query, and calls into the
 * pure policy module to interpret what it reads.
 */
const MAX_SESSION_WALK_DEPTH = 5;
const MAX_SESSION_FILES_PER_ROOT = 400;
export const MAX_SESSION_INSPECTED_ENTRIES_PER_ROOT = 2_048;
export const MAX_SESSION_INSPECTED_DIRECTORIES_PER_ROOT = 128;
const SESSION_TAIL_BYTES = 120_000;
const CODEX_HEAD_SCAN_BYTES = 32_000;

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

function homePath(...parts: string[]): string {
  return path.join(os.homedir(), ...parts);
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

type SessionWalkResult = {
  candidates: SessionCandidate[];
  inspectedEntries: number;
  inspectedDirectories: number;
};

export async function walkRecentSessionsWithStats(
  root: string,
  extensions: string[],
  now: number,
  fileNames?: string[],
): Promise<SessionWalkResult> {
  const hits: SessionCandidate[] = [];
  const budget = {
    inspectedEntries: 0,
    inspectedDirectories: 0,
  };

  function retainRecent(candidate: SessionCandidate): void {
    if (hits.length < MAX_SESSION_FILES_PER_ROOT) {
      hits.push(candidate);
      return;
    }
    let oldestIndex = 0;
    for (let index = 1; index < hits.length; index += 1) {
      if (hits[index]!.mtimeMs < hits[oldestIndex]!.mtimeMs) oldestIndex = index;
    }
    if (candidate.mtimeMs > hits[oldestIndex]!.mtimeMs) hits[oldestIndex] = candidate;
  }

  async function walk(dir: string, depth: number): Promise<void> {
    if (depth > MAX_SESSION_WALK_DEPTH) return;
    if (budget.inspectedEntries >= MAX_SESSION_INSPECTED_ENTRIES_PER_ROOT) return;
    if (budget.inspectedDirectories >= MAX_SESSION_INSPECTED_DIRECTORIES_PER_ROOT) return;

    let directory;
    try {
      directory = await fs.opendir(dir);
    } catch {
      return;
    }
    budget.inspectedDirectories += 1;

    for await (const entry of directory) {
      if (budget.inspectedEntries >= MAX_SESSION_INSPECTED_ENTRIES_PER_ROOT) break;
      budget.inspectedEntries += 1;

      const fullPath = path.join(dir, entry.name);
      let stat;
      try {
        stat = await fs.lstat(fullPath);
      } catch {
        continue;
      }
      if (stat.isSymbolicLink()) continue;

      if (stat.isDirectory()) {
        if (entry.name === "node_modules" || entry.name === ".git" || entry.name === "cache") {
          continue;
        }
        // Skip subagent sidecar transcripts; parent session is the turn source of truth.
        if (entry.name === "subagents") continue;
        await walk(fullPath, depth + 1);
        continue;
      }

      if (!stat.isFile()) continue;
      if (fileNames && !fileNames.includes(entry.name)) continue;
      if (!extensions.some((ext) => entry.name.endsWith(ext))) continue;

      if (isRecentTimestamp(stat.mtimeMs, now, SESSION_CANDIDATE_WINDOW_MS)) {
        retainRecent({
          filePath: fullPath,
          mtimeMs: stat.mtimeMs,
          label: friendlySessionLabel(fullPath),
        });
      }
    }
  }

  await walk(root, 0);
  hits.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return {
    candidates: hits,
    inspectedEntries: budget.inspectedEntries,
    inspectedDirectories: budget.inspectedDirectories,
  };
}

async function walkRecentSessions(
  root: string,
  extensions: string[],
  now: number,
  fileNames?: string[],
): Promise<SessionCandidate[]> {
  return (await walkRecentSessionsWithStats(root, extensions, now, fileNames)).candidates;
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

type ActiveTurnHit = TurnAssessment & {
  label?: string;
  filePath?: string;
  /** Stable identity within the agent kind (session path, composer key, pid). */
  identity: string;
};

/** Every reason a Cursor scan can stop before conclusively enumerating every
 * matching `cursorDiskKV` row (natural `LIMIT`-bounded exhaustion aside). */
export type CursorScanIncompleteReason =
  | "rowLimit"
  | "decodedByteLimit"
  | "bubbleLookupLimit"
  | "deadline";

/**
 * Thrown when a Cursor scan is stopped — by a hard bound (rows, cumulative
 * decoded bytes, bubble lookups, or elapsed time) or by an operational
 * SQLite failure (busy/locked/corrupt) — before it could conclusively
 * enumerate every composer. `detectActiveAgents`'s caller
 * (`monitor.ts`'s `scanOnce`) must never treat this as "zero active Cursor
 * agents": its existing catch-and-retain behavior keeps the last
 * successful agent list instead, exactly as it already does for any other
 * unexpected detector failure.
 */
export class CursorSessionScanError extends Error {
  readonly reason: CursorScanIncompleteReason | "databaseError";
  readonly cause?: unknown;

  constructor(reason: CursorScanIncompleteReason | "databaseError", options?: { cause?: unknown }) {
    super(
      reason === "databaseError"
        ? `Cursor session database operation failed${
            options?.cause instanceof Error ? `: ${options.cause.message}` : ""
          }`
        : `Cursor session scan stopped before completion (${reason}); treating as inconclusive`,
    );
    this.name = "CursorSessionScanError";
    this.reason = reason;
    this.cause = options?.cause;
  }
}

/**
 * Test-only instrumentation. Every field is `undefined` at every production
 * call site, so none of this can affect real scans — only tests that
 * explicitly construct hooks can observe inspected-row/bubble-lookup counts
 * or force a near-immediate deadline.
 */
type CursorScanTestHooks = {
  onRowInspected?: () => void;
  onBubbleLookup?: () => void;
  deadlineMillisecondsOverride?: number;
};

/** Outcome of one bounded, parameterized `bubbleId:<composerId>:<bubbleId>` point lookup. */
type BubbleLookupOutcome =
  | { kind: "found"; bubble: CursorBubbleRecord }
  | { kind: "absentOrMalformed" }
  | { kind: "limitExceeded" };

/**
 * Cursor IDE stores composer/agent state in globalStorage state.vscdb
 * (cursorDiskKV composerData:*). Disk `status` is unreliable mid-turn, so we
 * also inspect conversation headers for open turns and running tools — and,
 * since real Cursor data records a running tool's actual status in a
 * separate `bubbleId:<composerId>:<bubbleId>` row rather than embedding it
 * in the header itself, a bounded set of those rows too (see
 * `cursorRelevantBubbleIds`). Returns every active composer so concurrent
 * agents all appear in the menu.
 *
 * Every hard bound below (see `agent-detection-policy.ts`'s
 * `CURSOR_MAX_*`/`CURSOR_SQLITE_*` constants) counts inactive, malformed,
 * duplicate, and active rows/lookups alike. Reaching any of them — other
 * than the intentional `CURSOR_MAX_ACTIVE_CANDIDATES` early exit once
 * plenty of concurrent agents are already found, or natural exhaustion of
 * the `LIMIT`-bounded result set — throws `CursorSessionScanError` rather
 * than silently returning whatever partial evidence was gathered so far: an
 * unbounded/pathological Cursor vault must never be able to make this
 * function falsely report "no active Cursor agents" merely because a bound
 * was hit before the scan could look far enough.
 */
export async function detectCursorComposerActivity(
  now: number,
  dbPath = path.join(
    os.homedir(),
    "Library",
    "Application Support",
    "Cursor",
    "User",
    "globalStorage",
    "state.vscdb",
  ),
  testHooks?: CursorScanTestHooks,
): Promise<ActiveTurnHit[]> {
  try {
    await fs.access(dbPath);
  } catch {
    return [];
  }

  return queryCursorComposers(dbPath, now, testHooks);
}

function queryCursorComposers(
  dbPath: string,
  now: number,
  testHooks?: CursorScanTestHooks,
): ActiveTurnHit[] {
  let db: DatabaseSync;
  try {
    db = new DatabaseSync(dbPath, { readOnly: true, timeout: CURSOR_SQLITE_BUSY_TIMEOUT_MS });
  } catch (error) {
    throw new CursorSessionScanError("databaseError", { cause: error });
  }

  try {
    return runCursorScan(db, dbPath, now, testHooks);
  } finally {
    try {
      db.close();
    } catch {
      // Best-effort close only: a result or a thrown error has already
      // been determined by this point, and a close failure must not
      // override either.
    }
  }
}

function runCursorScan(
  db: DatabaseSync,
  dbPath: string,
  now: number,
  testHooks?: CursorScanTestHooks,
): ActiveTurnHit[] {
  const deadlineAtMs =
    performance.now() + (testHooks?.deadlineMillisecondsOverride ?? CURSOR_SQLITE_QUERY_DEADLINE_MS);
  const deadlineExpired = () => performance.now() >= deadlineAtMs;

  let transactionOpen = false;
  try {
    db.exec("BEGIN");
    transactionOpen = true;

    // `ORDER BY rowid DESC`: cursorDiskKV is a plain SQLite KV table with no
    // timestamp column, so the implicit rowid — bumped on every
    // insert/upsert — is the only available, trustworthy (schema-level,
    // not attacker-controlled-JSON) recency proxy. Cursor rewrites a
    // composer's row whenever it changes, so the freshest activity
    // surfaces first, which keeps a bounded scan useful even if the
    // row/byte/time budget runs out before reaching the end of the table.
    // `LIMIT ?` is bound to the inspected-row cap **+ 1**: SQL fetches at
    // most that many rows (never the whole table); if the `(cap + 1)`-th
    // row is actually delivered, more matching rows exist beyond what this
    // scan inspected, which is the truncation signal.
    const composerStatement = db.prepare(
      "SELECT key, value FROM cursorDiskKV WHERE key LIKE ? ORDER BY rowid DESC LIMIT ?",
    );
    // Prepared once, reused (bound fresh per call) for every bubble
    // lookup — an exact parameterized point lookup, never SQL
    // concatenation.
    const bubbleStatement = db.prepare("SELECT value FROM cursorDiskKV WHERE key = ?");

    const evidence: ActiveTurnHit[] = [];
    let rowsInspected = 0;
    let totalDecodedBytes = 0;
    let totalBubbleLookups = 0;
    const attemptedBubbleKeys = new Set<string>();
    const bubbleCache = new Map<string, CursorBubbleRecord>();
    let stopReason: CursorScanIncompleteReason | null = null;

    // Every counter/flag here is charged identically whether the row or
    // bubble turns out to be inactive, malformed, or a duplicate reference
    // — limits count inspected work, not just active results.
    const lookUpBubble = (bubbleKey: string): BubbleLookupOutcome => {
      if (attemptedBubbleKeys.has(bubbleKey)) {
        // Duplicate reference (already attempted this scan): serve from
        // cache without a second round trip or byte charge.
        const cached = bubbleCache.get(bubbleKey);
        return cached ? { kind: "found", bubble: cached } : { kind: "absentOrMalformed" };
      }
      if (deadlineExpired()) {
        stopReason ??= "deadline";
        return { kind: "limitExceeded" };
      }
      if (totalBubbleLookups >= CURSOR_MAX_BUBBLE_LOOKUPS) {
        stopReason ??= "bubbleLookupLimit";
        return { kind: "limitExceeded" };
      }
      attemptedBubbleKeys.add(bubbleKey);
      totalBubbleLookups += 1;
      testHooks?.onBubbleLookup?.();

      const row = bubbleStatement.get(bubbleKey) as { value?: unknown } | undefined;
      if (!row || typeof row.value !== "string") return { kind: "absentOrMalformed" };
      const valueByteCount = Buffer.byteLength(row.value, "utf8");
      if (valueByteCount === 0 || valueByteCount > CURSOR_MAX_VALUE_BYTES) {
        return { kind: "absentOrMalformed" };
      }
      if (totalDecodedBytes + valueByteCount > CURSOR_MAX_TOTAL_DECODED_VALUE_BYTES) {
        stopReason ??= "decodedByteLimit";
        return { kind: "limitExceeded" };
      }
      totalDecodedBytes += valueByteCount;
      let bubble: unknown;
      try {
        bubble = JSON.parse(row.value);
      } catch {
        return { kind: "absentOrMalformed" };
      }
      if (!bubble || typeof bubble !== "object" || Array.isArray(bubble)) {
        return { kind: "absentOrMalformed" };
      }
      bubbleCache.set(bubbleKey, bubble as CursorBubbleRecord);
      return { kind: "found", bubble: bubble as CursorBubbleRecord };
    };

    rowLoop: for (const row of composerStatement.iterate("composerData:%", CURSOR_MAX_INSPECTED_ROWS + 1)) {
      if (deadlineExpired()) {
        stopReason = "deadline";
        break;
      }
      if (rowsInspected >= CURSOR_MAX_INSPECTED_ROWS) {
        stopReason = "rowLimit";
        break;
      }
      rowsInspected += 1;
      testHooks?.onRowInspected?.();

      if (typeof row.key !== "string") continue;
      const keyByteCount = Buffer.byteLength(row.key, "utf8");
      if (keyByteCount === 0 || keyByteCount > CURSOR_MAX_KEY_BYTES) continue;

      if (typeof row.value !== "string") continue;
      const valueByteCount = Buffer.byteLength(row.value, "utf8");
      // Bounded blob processing: skip (never log) anything implausibly
      // large for a composer record.
      if (valueByteCount === 0 || valueByteCount > CURSOR_MAX_VALUE_BYTES) continue;

      if (totalDecodedBytes + valueByteCount > CURSOR_MAX_TOTAL_DECODED_VALUE_BYTES) {
        stopReason = "decodedByteLimit";
        break;
      }
      totalDecodedBytes += valueByteCount;

      let record: unknown;
      try {
        record = JSON.parse(row.value);
      } catch {
        continue;
      }
      if (!record || typeof record !== "object" || Array.isArray(record)) continue;

      const key = row.key;
      const identity = key.startsWith("composerData:") ? key.slice("composerData:".length) : key;

      let finalAssessment: TurnAssessment & { label?: string };
      try {
        // First pass never touches bubbles; `lastActivityAt` is folded
        // purely from already-decoded, trusted composer/header fields, so
        // it is identical whether or not bubbles are ultimately consulted
        // below.
        const provisional = assessCursorComposerRecord(record as CursorComposerRecord, now);
        finalAssessment = provisional;

        if (!provisional.active && isRecentTimestamp(provisional.lastActivityAt, now, TOOL_TURN_GRACE_MS)) {
          // Only a plausibly-recent composer's verdict can change once a
          // hidden bubble tool status is known — this keeps bubble lookups
          // bounded to the small fraction of composers where they could
          // possibly matter, instead of spending budget on every
          // long-completed conversation the scan steps over.
          const bubbles: Record<string, CursorBubbleRecord> = {};
          let truncatedByBubbleLookup = false;
          for (const bubbleId of cursorRelevantBubbleIds(record as CursorComposerRecord)) {
            const outcome = lookUpBubble(`bubbleId:${identity}:${bubbleId}`);
            if (outcome.kind === "found") {
              bubbles[bubbleId] = outcome.bubble;
            } else if (outcome.kind === "limitExceeded") {
              truncatedByBubbleLookup = true;
              break;
            }
          }
          if (truncatedByBubbleLookup) break rowLoop;
          finalAssessment = assessCursorComposerRecord(record as CursorComposerRecord, now, bubbles);
        }
      } catch {
        logger.debug("detector", "Skipped malformed Cursor composer row", {
          reason: "assessment exception",
        });
        continue;
      }

      if (!finalAssessment.active) continue;
      evidence.push({
        ...finalAssessment,
        filePath: dbPath,
        identity,
      });
      if (evidence.length >= CURSOR_MAX_ACTIVE_CANDIDATES) break;
    }

    // Any stop reason other than natural `LIMIT`-bounded exhaustion or the
    // intentional `CURSOR_MAX_ACTIVE_CANDIDATES` early exit means an unseen
    // row or bubble could have been active — never trust the partial
    // evidence gathered so far in that case.
    if (stopReason) {
      throw new CursorSessionScanError(stopReason);
    }

    db.exec("COMMIT");
    transactionOpen = false;
    evidence.sort((a, b) => b.lastActivityAt - a.lastActivityAt);
    return evidence;
  } catch (error) {
    if (transactionOpen) {
      try {
        db.exec("ROLLBACK");
      } catch {
        // Best-effort rollback only; the error/result already determined
        // above takes precedence.
      }
    }
    if (error instanceof CursorSessionScanError) throw error;
    throw new CursorSessionScanError("databaseError", { cause: error });
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
