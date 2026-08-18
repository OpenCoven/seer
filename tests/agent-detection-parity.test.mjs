import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  AGENT_KINDS,
  CURSOR_MAX_ACTIVE_CANDIDATES,
  CURSOR_MAX_BUBBLE_LOOKUPS,
  CURSOR_MAX_INSPECTED_ROWS,
  CURSOR_MAX_KEY_BYTES,
  CURSOR_MAX_RECENT_HEADERS_PER_COMPOSER,
  CURSOR_MAX_TOTAL_DECODED_VALUE_BYTES,
  CURSOR_MAX_VALUE_BYTES,
  CURSOR_RUNNING_TOOL_STATUSES,
  CURSOR_SQLITE_BUSY_TIMEOUT_MS,
  CURSOR_SQLITE_QUERY_DEADLINE_MS,
  MAX_SUPPORTED_TIMESTAMP_MS,
  SESSION_CANDIDATE_WINDOW_MS,
  TIMESTAMP_FUTURE_SKEW_MS,
  assessCursorComposerRecord,
  assessDetectionFixture,
  cursorRecencySqlExpression,
  cursorRelevantBubbleIds,
  isCanonicalCursorIsoTimestamp,
  isDefinitelyOlderThanWindowLowerBound,
  isRecentTimestamp,
  matchAgentKind,
  parseCursorTimestamp,
} from "../main/services/agent-detection-policy.ts";

/**
 * Characterizes `assessDetectionFixture` (the pure policy extracted from
 * `main/services/agent-detector.ts`) against the shared synthetic fixture
 * oracle in `tests/fixtures/agent-detection`. The Swift port
 * (`apps/macos/Seer/Tests/Detection/TurnAssessorsTests.swift`) reads exactly
 * the same `expected.json` and fixture files — neither language restates the
 * expected results, so this file (and the Swift test) are the only places
 * that assert against the oracle.
 */

const here = dirname(fileURLToPath(import.meta.url));
const fixturesDir = join(here, "fixtures", "agent-detection");

function readJson(fileName) {
  return JSON.parse(readFileSync(join(fixturesDir, fileName), "utf8"));
}

/** Parses a `.jsonl` fixture into an array of already-parsed JSON records. */
function readJsonl(fileName) {
  const text = readFileSync(join(fixturesDir, fileName), "utf8");
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line));
}

const oracle = readJson("expected.json");
const now = Date.parse(oracle.now);
assert.ok(Number.isFinite(now), "expected.json 'now' must be a valid ISO timestamp");

test("Cursor continuation flags use strict booleans without refreshing malformed records", () => {
  for (const malformed of [1, 0]) {
    const assessment = assessCursorComposerRecord({
      status: "completed",
      isContinuationInProgress: malformed,
      fullConversationHeadersOnly: [],
    }, now);
    assert.equal(assessment.active, false);
    assert.equal(assessment.lastActivityAt, 0);
  }

  assert.equal(assessCursorComposerRecord({
    isContinuationInProgress: true,
    lastUpdatedAt: now,
  }, now).active, true);
  assert.equal(assessCursorComposerRecord({
    isContinuationInProgress: false,
  }, now).active, false);
});

test("Cursor activity signals require an explicit valid timestamp", () => {
  for (const timestamp of [undefined, null, true, "not-a-timestamp", Number.NaN, Number.POSITIVE_INFINITY]) {
    const record = {
      status: "generating",
      generatingBubbleIds: ["bubble"],
      ...(timestamp === undefined ? {} : { lastUpdatedAt: timestamp }),
    };
    for (const scanNow of [now, now + 1_000, now + 60_000]) {
      const assessment = assessCursorComposerRecord(record, scanNow);
      assert.equal(assessment.active, false);
      assert.notEqual(assessment.lastActivityAt, scanNow);
    }
  }
});

test("Cursor headers reject null, primitive, and non-array shapes without throwing", () => {
  for (const headers of [
    null,
    {},
    [null],
    [true],
    [1],
    ["header"],
    [[]],
  ]) {
    assert.doesNotThrow(() => {
      const assessment = assessCursorComposerRecord({
        status: "completed",
        lastUpdatedAt: now,
        fullConversationHeadersOnly: headers,
      }, now);
      assert.equal(assessment.active, false);
      assert.equal(assessment.reason, "malformed cursor composer");
    });
  }
});

test("Cursor header proxies and throwing getters are contained as malformed records", () => {
  const throwingPrototype = new Proxy({}, {
    getPrototypeOf() {
      throw new Error("private row content");
    },
  });
  const throwingType = {};
  Object.defineProperty(throwingType, "type", {
    get() {
      throw new Error("private row content");
    },
  });

  for (const header of [throwingPrototype, throwingType]) {
    const assessment = assessCursorComposerRecord({
      status: "completed",
      fullConversationHeadersOnly: [header],
    }, now);
    assert.equal(assessment.active, false);
    assert.equal(assessment.reason, "malformed cursor composer");
  }
});

test("Cursor headers require strict field types, finite timestamps, and finite durations", () => {
  const malformedHeaders = [
    [{ type: "1", createdAt: now }],
    [{ type: 1, createdAt: null }],
    [{ type: 1, createdAt: Number.NaN }],
    [{ type: 1, createdAt: Number.POSITIVE_INFINITY }],
    [{ type: 1, createdAt: "not-a-timestamp" }],
    [{ type: 1, createdAt: now, grouping: null }],
    [{ type: 1, createdAt: now, grouping: { turnDurationMs: Number.NaN } }],
    [{ type: 1, createdAt: now, grouping: { turnDurationMs: -1 } }],
    [{ type: 1, createdAt: now, grouping: { shellStatus: true } }],
  ];

  for (const fullConversationHeadersOnly of malformedHeaders) {
    const assessment = assessCursorComposerRecord({
      status: "completed",
      fullConversationHeadersOnly,
    }, now);
    assert.equal(assessment.active, false);
    assert.equal(assessment.reason, "malformed cursor composer");
  }
});

test("Cursor mixed headers process valid entries without refreshing malformed entries", () => {
  const record = {
    status: "completed",
    lastUpdatedAt: now - 60_000,
    fullConversationHeadersOnly: [
      null,
      true,
      42,
      "header",
      [],
      { type: "1", createdAt: now },
      { type: 1, createdAt: null },
      { type: 1, createdAt: now - 1_000 },
    ],
  };

  const fresh = assessCursorComposerRecord(record, now);
  assert.equal(fresh.active, true);
  assert.equal(fresh.lastActivityAt, now - 1_000);
  assert.equal(fresh.reason, "user prompt");

  const repeated = assessCursorComposerRecord(record, now + 45_001);
  assert.equal(repeated.active, false);
  assert.equal(repeated.lastActivityAt, now - 1_000);
  assert.equal(repeated.reason, "stale user prompt");
});

test("CURSOR_RUNNING_TOOL_STATUSES stores the in-progress entry lowercase, matching the lowercased comparison", () => {
  // `toolStatus`/`shellStatus` are always lowercased (see the header loop below)
  // before being checked against this set, so a mixed-case entry like
  // "inProgress" can never match and silently never classifies a tool as running.
  assert.ok(CURSOR_RUNNING_TOOL_STATUSES.has("inprogress"));
  assert.ok(!CURSOR_RUNNING_TOOL_STATUSES.has("inProgress"));
});

test("Cursor tool status 'inProgress' (and normalized case variants) classify the composer as active", () => {
  for (const rawStatus of ["inProgress", "INPROGRESS", "InProgress", "inprogress", "in_progress"]) {
    const record = {
      status: "completed",
      lastUpdatedAt: now,
      fullConversationHeadersOnly: [
        { type: 2, createdAt: now, grouping: { toolFormerStatus: rawStatus } },
      ],
    };
    const assessment = assessCursorComposerRecord(record, now);
    assert.equal(assessment.active, true, `toolFormerStatus "${rawStatus}" should be active`);
    assert.equal(assessment.reason, "tool_call in progress", `toolFormerStatus "${rawStatus}" should report a running tool`);

    const shellRecord = {
      status: "completed",
      lastUpdatedAt: now,
      fullConversationHeadersOnly: [
        { type: 2, createdAt: now, grouping: { shellStatus: rawStatus } },
      ],
    };
    const shellAssessment = assessCursorComposerRecord(shellRecord, now);
    assert.equal(shellAssessment.active, true, `shellStatus "${rawStatus}" should be active`);
    assert.equal(shellAssessment.reason, "tool_call in progress", `shellStatus "${rawStatus}" should report a running tool`);
  }
});

// MARK: - Cursor bubble-aware assessor (issue B)
//
// Real Cursor state stores a running tool's actual status in a separate
// `bubbleId:<composerId>:<bubbleId>` row's `toolFormerData.status`, not
// embedded in the composer header itself (that legacy embedded shape is
// still supported — see the "inProgress" case-variant test above — but is
// not what real Cursor installs ever write). These mirror
// `TurnAssessorsTests.swift`'s bubble-aware tests 1:1 so both languages
// prove the same behavior against the same pure assessor contract.

test("Cursor bubble toolFormerData.status inProgress resolved via bubbleId makes the tool call active", () => {
  const timestampNow = 1_786_449_620_000;
  const record = {
    status: "completed",
    lastUpdatedAt: timestampNow - 5_000,
    fullConversationHeadersOnly: [
      { type: 2, createdAt: timestampNow - 5_000, bubbleId: "bubble-1" },
    ],
  };
  const bubbles = { "bubble-1": { toolFormerData: { status: "inProgress" } } };

  const withoutBubble = assessCursorComposerRecord(record, timestampNow);
  assert.equal(
    withoutBubble.active,
    false,
    "a bare bubble reference with no bubble content must not itself imply activity",
  );

  const withBubble = assessCursorComposerRecord(record, timestampNow, bubbles);
  assert.equal(
    withBubble.active,
    true,
    'toolFormerData.status "inProgress" resolved via the referenced bubble must classify the tool call as active',
  );
  assert.equal(withBubble.reason, "tool_call in progress");
});

test("Cursor bubble toolFormerData.status case variants are all active", () => {
  const timestampNow = 1_786_449_620_000;
  for (const rawStatus of ["inProgress", "INPROGRESS", "InProgress", "inprogress", "in_progress"]) {
    const record = {
      status: "completed",
      lastUpdatedAt: timestampNow - 5_000,
      fullConversationHeadersOnly: [
        { type: 2, createdAt: timestampNow - 5_000, bubbleId: "bubble-1" },
      ],
    };
    const bubbles = { "bubble-1": { toolFormerData: { status: rawStatus } } };
    const assessment = assessCursorComposerRecord(record, timestampNow, bubbles);
    assert.equal(assessment.active, true, `bubble toolFormerData.status "${rawStatus}" should be active`);
    assert.equal(
      assessment.reason,
      "tool_call in progress",
      `bubble toolFormerData.status "${rawStatus}" should report a running tool`,
    );
  }
});

test("Cursor bubble toolFormerData terminal statuses are not reported as a running tool", () => {
  const timestampNow = 1_786_449_620_000;
  for (const rawStatus of ["completed", "success", "error", "failed"]) {
    const record = {
      status: "completed",
      lastUpdatedAt: timestampNow - 5_000,
      fullConversationHeadersOnly: [
        { type: 1, createdAt: timestampNow - 10_000 },
        { type: 2, createdAt: timestampNow - 5_000, bubbleId: "bubble-1" },
      ],
    };
    const bubbles = { "bubble-1": { toolFormerData: { status: rawStatus } } };
    const assessment = assessCursorComposerRecord(record, timestampNow, bubbles);
    assert.notEqual(
      assessment.reason,
      "tool_call in progress",
      `terminal bubble status "${rawStatus}" must not report a running tool`,
    );
  }
});

test("Cursor missing or malformed bubble content never crashes or falsely activates", () => {
  const timestampNow = 1_786_449_620_000;
  const record = {
    status: "completed",
    lastUpdatedAt: timestampNow - 5_000,
    fullConversationHeadersOnly: [
      { type: 2, createdAt: timestampNow - 5_000, bubbleId: "bubble-missing" },
    ],
  };
  const malformedBubbleSets = [
    {}, // dangling reference: bubble id not present at all.
    { "bubble-missing": {} }, // bubble present, no toolFormerData at all.
    { "bubble-missing": { toolFormerData: "not-an-object" } },
    { "bubble-missing": { toolFormerData: { status: 1 } } },
    { "bubble-missing": { toolFormerData: { status: null } } },
  ];
  for (const bubbles of malformedBubbleSets) {
    assert.doesNotThrow(() => {
      const assessment = assessCursorComposerRecord(record, timestampNow, bubbles);
      assert.notEqual(assessment.reason, "tool_call in progress");
    });
  }
});

test("cursorRelevantBubbleIds excludes user bubbles and deduplicates repeated references", () => {
  const record = {
    fullConversationHeadersOnly: [
      { type: 1, createdAt: 0, bubbleId: "user-0" },
      { type: 2, createdAt: 1, bubbleId: "tool-0" },
      { type: 1, createdAt: 2, bubbleId: "user-1" },
      { type: 2, createdAt: 3, bubbleId: "tool-1" },
      // Duplicate reference to an already-listed bubble id.
      { type: 2, createdAt: 4, bubbleId: "tool-0" },
    ],
  };

  assert.deepEqual(cursorRelevantBubbleIds(record), ["tool-0", "tool-1"]);
});

test("cursorRelevantBubbleIds is bounded to the trailing CURSOR_MAX_RECENT_HEADERS_PER_COMPOSER references", () => {
  const headers = Array.from({ length: 12 }, (_, index) => ({
    type: 2,
    createdAt: index,
    bubbleId: `tool-${index}`,
  }));
  const record = { fullConversationHeadersOnly: headers };

  const ids = cursorRelevantBubbleIds(record);

  assert.equal(CURSOR_MAX_RECENT_HEADERS_PER_COMPOSER, 8);
  assert.deepEqual(ids, ["tool-4", "tool-5", "tool-6", "tool-7", "tool-8", "tool-9", "tool-10", "tool-11"]);
});

// MARK: - Cross-language bound-constant parity (issue A)

test("Cursor scan limit constants match the shared cross-language parity fixture", () => {
  const limits = readJson("cursor-scan-limits.json");

  assert.equal(limits.cursorMaximumValidCandidates, CURSOR_MAX_ACTIVE_CANDIDATES);
  assert.equal(limits.cursorMaximumKeyBytes, CURSOR_MAX_KEY_BYTES);
  assert.equal(limits.cursorMaximumValueBytes, CURSOR_MAX_VALUE_BYTES);
  assert.equal(limits.cursorSQLiteBusyTimeoutMilliseconds, CURSOR_SQLITE_BUSY_TIMEOUT_MS);
  assert.equal(limits.cursorSQLiteQueryDeadlineMilliseconds, CURSOR_SQLITE_QUERY_DEADLINE_MS);
  assert.equal(limits.cursorMaximumInspectedRows, CURSOR_MAX_INSPECTED_ROWS);
  assert.equal(limits.cursorMaximumTotalDecodedValueBytes, CURSOR_MAX_TOTAL_DECODED_VALUE_BYTES);
  assert.equal(limits.cursorMaximumBubbleLookups, CURSOR_MAX_BUBBLE_LOOKUPS);
  assert.equal(limits.cursorMaximumRecentHeadersPerComposer, CURSOR_MAX_RECENT_HEADERS_PER_COMPOSER);
});

const APPROVED_FAMILIES = [
  "claude-code",
  "codex",
  "grok",
  "gemini",
  "aider",
  "opencode",
  "goose",
  "amp",
  "cursor",
  "continue",
];

/** Builds the `DetectionFixture` union member `assessDetectionFixture` expects for one oracle row. */
function buildFixture(testCase) {
  if (testCase.kind === "process") {
    const rows = readJson(testCase.fixtureFile);
    const row = rows.find((candidate) => candidate.key === testCase.selector);
    assert.ok(row, `${testCase.fixtureFile} is missing selector ${testCase.selector}`);
    return {
      kind: "process",
      family: testCase.family,
      pid: row.pid,
      cpuPercent: row.cpuPercent,
    };
  }

  if (testCase.format === "generic-mtime") {
    const doc = readJson(testCase.fixtureFile);
    const entry = doc[testCase.selector];
    assert.ok(entry, `${testCase.fixtureFile} is missing selector ${testCase.selector}`);
    return {
      kind: "session",
      family: testCase.family,
      format: "generic-mtime",
      identity: entry.identity,
      mtimeMs: Date.parse(entry.mtimeMs),
    };
  }

  if (testCase.format === "cursor") {
    const doc = readJson(testCase.fixtureFile);
    return {
      kind: "session",
      family: testCase.family,
      format: "cursor",
      identity: doc.composerKey,
      record: doc.record,
      bubbles: doc.bubbles ?? {},
    };
  }

  // claude | codex | grok: newline-delimited turn events.
  return {
    kind: "session",
    family: testCase.family,
    format: testCase.format,
    identity: testCase.identity,
    mtimeMs: Date.parse(testCase.mtimeMs),
    events: readJsonl(testCase.fixtureFile),
  };
}

test("shared fixture oracle covers all ten approved families", () => {
  const covered = new Set(oracle.cases.map((testCase) => testCase.family));
  for (const family of APPROVED_FAMILIES) {
    assert.ok(covered.has(family), `expected.json is missing family: ${family}`);
  }
  assert.equal(covered.size, APPROVED_FAMILIES.length);
});

test("shared fixture oracle proves the 25.0 process-only CPU threshold for Aider, Amp, and Cursor CLI", () => {
  for (const family of ["aider", "amp", "cursor"]) {
    const rows = oracle.cases.filter(
      (testCase) => testCase.family === family && testCase.kind === "process",
    );
    assert.ok(rows.length > 0, `${family} is missing process-only fixture rows`);
    assert.ok(
      rows.some((row) => row.expected.active === false),
      `${family} is missing a below-threshold process case`,
    );
    assert.ok(
      rows.some((row) => row.expected.active === true),
      `${family} is missing an at/above-threshold process case`,
    );
  }
});

test("shared fixture oracle rows have unique ids", () => {
  const ids = oracle.cases.map((testCase) => testCase.id);
  assert.equal(new Set(ids).size, ids.length);
});

test("shared fixture oracle covers bounded skew and extreme future evidence for every assessor path", () => {
  const ids = new Set(oracle.cases.map(({ id }) => id));
  for (const prefix of ["claude", "codex", "grok", "generic-mtime", "cursor"]) {
    assert.ok(ids.has(`${prefix}-bounded-future-skew`), `${prefix} is missing bounded skew coverage`);
    assert.ok(ids.has(`${prefix}-extreme-future`), `${prefix} is missing extreme future coverage`);
  }
  for (const prefix of ["codex-fallback", "grok-fallback"]) {
    assert.ok(ids.has(`${prefix}-bounded-future-skew`), `${prefix} is missing bounded skew coverage`);
    assert.ok(ids.has(`${prefix}-extreme-future`), `${prefix} is missing extreme future coverage`);
  }
});

test("isRecentTimestamp rejects invalid ranges and permits only bounded future skew", () => {
  const timestampNow = 1_786_449_620_000;
  assert.equal(isRecentTimestamp(timestampNow - 45_000, timestampNow, 45_000), true);
  assert.equal(isRecentTimestamp(timestampNow - 45_001, timestampNow, 45_000), false);
  assert.equal(isRecentTimestamp(timestampNow + TIMESTAMP_FUTURE_SKEW_MS, timestampNow, 45_000), true);
  assert.equal(isRecentTimestamp(timestampNow + TIMESTAMP_FUTURE_SKEW_MS + 1, timestampNow, 45_000), false);
  for (const value of [Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY, Number.NaN, Number.MAX_VALUE]) {
    assert.equal(isRecentTimestamp(value, timestampNow, 45_000), false);
  }
  assert.equal(isRecentTimestamp(timestampNow, Number.POSITIVE_INFINITY, 45_000), false);
  assert.equal(isRecentTimestamp(timestampNow, timestampNow, -1), false);
});

for (const testCase of oracle.cases) {
  test(`assessDetectionFixture: ${testCase.id}`, () => {
    const fixture = buildFixture(testCase);
    const result = assessDetectionFixture(fixture, now);
    assert.deepEqual(result, testCase.expected, testCase.id);
  });
}

// MARK: - Process matcher case-sensitivity oracle (Finding 2)
//
// `matcherCases` in expected.json is the same shared oracle asserted by the
// Swift `testProcessMatcherOracle` in TurnAssessorsTests.swift: "family" rows
// exercise `matchAgentKind` end-to-end (does *some* pattern for this family
// match, first-match-wins across all ten families in declaration order,
// exactly like non-global JS `RegExp.test`), and "pattern" rows exercise one
// specific `processMatchers[patternIndex]` regex in isolation — required
// because the five case-sensitive scoped-package patterns each overlap with
// a case-insensitive sibling pattern in the same family (e.g. Claude Code's
// unanchored `/claude[-_]code/i` always matches wherever
// `/@anthropic-ai\/claude-code/` would, in any case), so whole-family
// matching alone cannot prove per-pattern case-sensitivity.
assert.ok(Array.isArray(oracle.matcherCases) && oracle.matcherCases.length > 0);

for (const testCase of oracle.matcherCases) {
  test(`matcherCases: ${testCase.id}`, () => {
    if (testCase.kind === "family") {
      const matched = matchAgentKind(testCase.command);
      assert.equal(matched?.id ?? null, testCase.expectedFamily ?? null, testCase.id);
      return;
    }

    if (testCase.kind === "pattern") {
      const kind = AGENT_KINDS.find((candidate) => candidate.id === testCase.family);
      assert.ok(kind, `unknown family in matcherCases: ${testCase.family}`);
      const pattern = kind.processMatchers[testCase.patternIndex];
      assert.ok(pattern, `${testCase.family} has no processMatchers[${testCase.patternIndex}]`);
      assert.equal(pattern.test(testCase.command), testCase.expectedMatch, testCase.id);
      return;
    }

    assert.fail(`unknown matcherCases kind: ${testCase.kind}`);
  });
}

test("matcherCases rows have unique ids", () => {
  const ids = oracle.matcherCases.map((testCase) => testCase.id);
  assert.equal(new Set(ids).size, ids.length);
});

test("exactly five scoped-package process matchers are case-sensitive", () => {
  const caseSensitive = AGENT_KINDS.flatMap((kind) =>
    kind.processMatchers.filter((re) => !re.flags.includes("i")).map((re) => re.source),
  );
  assert.equal(caseSensitive.length, 5);
  assert.deepEqual(
    new Set(caseSensitive),
    new Set([
      "@anthropic-ai\\/claude-code",
      "@openai\\/codex",
      "@google\\/gemini-cli",
      "@sourcegraph\\/amp",
      "@continuedev\\/cli",
    ]),
  );
});

// MARK: - Cursor SQL recency vs. assessor-derived recency parity
//
// `cursorRecencySqlExpression` computes a `cursorDiskKV` composer row's
// recency directly in SQLite so a bounded query can `ORDER BY` real
// last-activity time instead of `rowid` (see its doc comment in
// `agent-detection-policy.ts`). These cases execute that *exact* SQL
// expression through a real SQLite connection (`node:sqlite`, the same
// engine `agent-detector.ts`'s scan Worker uses) — via a bound `$value`
// parameter standing in for the table column, never a table — and assert
// it agrees with `assessCursorComposerRecord`'s own `lastActivityAt` for
// every timestamp shape the assessor can turn into an *active* composer.
// That agreement is exactly what lets the row-limit sentinel (see
// `agent-detector.test.ts`'s "row limit recovers"/"still throws" tests)
// safely treat an unrankable (SQL `NULL`) row as provably never a lost
// active composer: a row can only be unrankable here if it is also
// unassessable (malformed JSON/oversized), and this suite is the proof
// that every *other*, assessable shape always gets a real, matching rank.
function sqlRecencyForRawValue(rawValue) {
  const db = new DatabaseSync(":memory:");
  try {
    const expression = cursorRecencySqlExpression("$value");
    const row = db.prepare(`SELECT (${expression}) AS recencyMs`).get({ value: rawValue });
    return row.recencyMs === null ? null : Number(row.recencyMs);
  } finally {
    db.close();
  }
}

function sqlRecencyFor(record) {
  return sqlRecencyForRawValue(JSON.stringify(record));
}

function assessedLastActivityAt(record) {
  return assessCursorComposerRecord(record, now).lastActivityAt;
}

test("Cursor SQL recency matches the assessor for a numeric root timestamp (milliseconds and seconds)", () => {
  for (const record of [
    { status: "generating", lastUpdatedAt: now },
    { status: "generating", lastUpdatedAt: Math.round(now / 1000) },
  ]) {
    const raw = JSON.stringify(record);
    assert.equal(sqlRecencyFor(record), assessedLastActivityAt(record), raw);
    assert.equal(assessedLastActivityAt(record), now, raw);
  }
});

test("Cursor SQL recency matches the assessor for an ISO-8601 string root timestamp", () => {
  const isoNow = new Date(now).toISOString();
  // toISOString() always emits this exact shape (milliseconds + trailing
  // "Z") — precisely what cursorRecencySqlExpression's GLOB guard requires
  // and what real Cursor data would use if it ever emitted string
  // timestamps at all.
  assert.match(isoNow, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  const record = { status: "generating", lastUpdatedAt: isoNow };
  assert.equal(sqlRecencyFor(record), assessedLastActivityAt(record), isoNow);
  assert.equal(assessedLastActivityAt(record), now);
});

test("Cursor SQL recency matches the assessor for a header-only composer (numeric and string createdAt)", () => {
  const isoNow = new Date(now).toISOString();
  for (const createdAt of [now, isoNow]) {
    // No root-level lastUpdatedAt/createdAt/conversationCheckpointLastUpdatedAt
    // at all: this composer's only recency signal is a conversation
    // header's own createdAt.
    const record = { fullConversationHeadersOnly: [{ type: 1, createdAt }] };
    const raw = JSON.stringify(record);
    assert.equal(sqlRecencyFor(record), assessedLastActivityAt(record), raw);
    assert.equal(assessedLastActivityAt(record), now, raw);
  }
});

test("Cursor SQL recency matches the assessor's field priority order for an updated-old row", () => {
  const oldCreatedAt = now - 86_400_000;
  for (const record of [
    // createdAt is a day old, but lastUpdatedAt reflects a recent update:
    // the higher-priority defined field must win over the older createdAt.
    { status: "completed", createdAt: oldCreatedAt, lastUpdatedAt: now },
    // conversationCheckpointLastUpdatedAt outranks both lastUpdatedAt and
    // createdAt even though all three are defined.
    {
      status: "completed",
      createdAt: oldCreatedAt,
      lastUpdatedAt: oldCreatedAt,
      conversationCheckpointLastUpdatedAt: now,
    },
  ]) {
    const raw = JSON.stringify(record);
    assert.equal(sqlRecencyFor(record), assessedLastActivityAt(record), raw);
    assert.equal(assessedLastActivityAt(record), now, raw);
  }

  // Priority order is a COALESCE, not a flat MAX: a lower-priority field's
  // numerically *larger* raw value must never outrank a defined
  // higher-priority field, in SQL exactly as in the `??` chain.
  const prioritized = {
    status: "completed",
    conversationCheckpointLastUpdatedAt: Math.round(now / 1000),
    lastUpdatedAt: now + 999_000_000,
  };
  const raw = JSON.stringify(prioritized);
  assert.equal(sqlRecencyFor(prioritized), assessedLastActivityAt(prioritized), raw);
  assert.equal(assessedLastActivityAt(prioritized), now, raw);
});

test("Cursor SQL recency is unrankable (NULL) for malformed/unparseable records, while the assessor's own in-memory lastActivityAt still falls back to 0", () => {
  // Each of these records is valid JSON, but every field that would
  // otherwise contribute a root/header recency signal is either absent or
  // fails the SQL shape guard (an unparseable string, non-object header
  // entries, or a bare top-level array with no matching `$.field` paths at
  // all). `cursorRecencySqlExpression`'s `rootRecency`/`headerRecency` no
  // longer default an unrankable set of candidates to `COALESCE(..., 0)`,
  // so SQL now correctly reports `NULL` ("cannot rank this row") instead of
  // a numeric `0` for every one of these — even though the assessor's own
  // `lastActivityAt` still separately falls back to its in-memory `0` seed
  // (see `assessCursorComposerRecord`'s own comment on that seed; it is
  // never surfaced through this SQL expression). This is the intentional
  // divergence that lets the row-limit sentinel treat such a row as
  // inconclusive rather than definitively old.
  for (const record of [
    { lastUpdatedAt: "not-a-timestamp" },
    { fullConversationHeadersOnly: [42, null, "x"] },
    [],
  ]) {
    const raw = JSON.stringify(record);
    assert.equal(sqlRecencyFor(record), null, raw);
    assert.equal(assessedLastActivityAt(record), 0, raw);
  }

  // Genuinely invalid JSON syntax never even reaches the assessor: the
  // scan Worker's own JSON.parse throws first and the row is skipped
  // before assessment. SQL correctly reports this shape as unrankable
  // (NULL, sorts last) rather than a numeric 0 — the only "parity" claim
  // meaningful for a row nothing ever assesses.
  assert.equal(sqlRecencyForRawValue('{"status":'), null);
  assert.equal(sqlRecencyForRawValue(""), null);
});

test("Cursor SQL recency matches the assessor for a future-skewed timestamp, and is unrankable (not a defaulted 0) for one beyond the supported bound", () => {
  for (const futureMs of [now + 60_000, now + 86_400_000, MAX_SUPPORTED_TIMESTAMP_MS - 1]) {
    // lastActivityAt itself is never clamped by "is this in the future" —
    // only the separate active/inactive boolean is. Recency ranking must
    // track the assessor's raw value exactly, future or not.
    const record = { status: "generating", lastUpdatedAt: futureMs };
    assert.equal(sqlRecencyFor(record), assessedLastActivityAt(record), String(futureMs));
    assert.equal(assessedLastActivityAt(record), futureMs);
  }

  // Beyond maxSupportedTimestampMs: the assessor rejects the whole record
  // as malformed (`validateCursorRecordFields` already rejects any defined
  // priority field that fails `parseCursorTimestamp`'s own bound check),
  // falling back to its in-memory `0` seed. SQL independently rejects the
  // same out-of-range numeric value via its own `ABS(ms) <=
  // maxSupportedTimestampMs` guard, yielding `NULL` (unrankable) rather
  // than a `COALESCE(..., 0)`-defaulted `0` — an out-of-range value must
  // never poison the row's rank with a nonsensical magnitude OR silently
  // masquerade as "provably epoch-zero old".
  const outOfRange = { status: "generating", lastUpdatedAt: MAX_SUPPORTED_TIMESTAMP_MS + 1 };
  assert.equal(sqlRecencyFor(outOfRange), null);
  assert.equal(assessedLastActivityAt(outOfRange), 0);
});

test("parseCursorTimestamp accepts exactly the canonical ISO-8601 grammar and rejects every lenient Date.parse shape", () => {
  // The one grammar `parseCursorTimestamp`, `cursorRecencySqlExpression`'s
  // SQL shape guard, and the Swift port's `Date.ISO8601FormatStyle` all
  // intentionally agree on: `YYYY-MM-DDTHH:MM:SS[.fraction](Z|±HH:MM)`,
  // case-sensitive `T`/`Z`, seconds required, fraction restricted to
  // EXACTLY 1-3 digits. `isCanonicalCursorIsoTimestamp` is the single
  // exported validator `parseCursorTimestamp` itself uses, so this test
  // and the parser cannot silently drift apart.
  for (const canonical of [
    "2024-01-15T10:20:30Z",
    "2024-01-15T10:20:30.123Z",
    "2024-01-15T10:20:30.1Z",
    "2024-01-15T10:20:30+00:00",
    "2024-01-15T10:20:30-05:30",
    "2024-01-15T10:20:30.123+05:30",
  ]) {
    assert.ok(isCanonicalCursorIsoTimestamp(canonical), canonical);
    assert.notEqual(parseCursorTimestamp(canonical), null, canonical);
  }

  // Every shape `Date.parse` alone would happily accept, but that must NOT
  // be blessed as a Cursor-timestamp string: this is the fix for the
  // formerly-"documented divergence" — these shapes must be rejected
  // consistently by `isCanonicalCursorIsoTimestamp` and `parseCursorTimestamp`
  // alike, not treated as an intentional TS/Swift/SQL disagreement.
  for (const lenient of [
    "2024-01-15", // date-only
    "2024-01-15t10:20:30Z", // lower-case t
    "2024-01-15T10:20:30z", // lower-case z
    "2024-01-15 10:20:30Z", // space instead of T
    "Mon, 15 Jan 2024 10:20:30 GMT", // RFC-2822
    "2024-01-15T10:20Z", // minute-only, no seconds
    "2024-01-15T10:20:30", // zone-less
    "2024-01-15T10:20:30.123456Z", // 6-digit (sub-millisecond) fraction — restricted to 1-3 digits
  ]) {
    assert.equal(isCanonicalCursorIsoTimestamp(lenient), false, lenient);
    assert.equal(parseCursorTimestamp(lenient), null, lenient);
    // Confirm these really are shapes `Date.parse` alone would accept —
    // otherwise this test would not be exercising the intended divergence
    // from unrestricted `Date.parse` at all.
    assert.ok(Number.isFinite(Date.parse(lenient)), `fixture assumption: Date.parse must accept ${lenient}`);
  }
});

test("Cursor SQL recency and the assessor now agree that every lenient string shape is unrankable — no blessed divergence in WHICH shapes are rejected", () => {
  // Previously "documented" as the one intentional assessor divergence:
  // `Date.parse` (and so the old, unrestricted `parseCursorTimestamp`)
  // happily accepted a bare date-only string, while Swift's
  // `Date.ISO8601FormatStyle` flatly rejected it. `parseCursorTimestamp` is
  // now gated by the same `isCanonicalCursorIsoTimestamp` grammar the SQL
  // shape guard already enforced, so all three engines agree on WHICH
  // shapes are unrankable: a date-only (or lower-case/RFC/space/
  // minute-only) header timestamp contributes nothing to the composer's
  // `lastActivityAt` on any engine. SQL now represents "unrankable" as a
  // real `NULL` (never a `COALESCE(..., 0)`-defaulted `0`) while the
  // assessor represents it as its own in-memory `0` fallback — those two
  // representations are allowed, and expected, to differ; what must never
  // differ is which shapes each side calls unrankable in the first place.
  for (const createdAt of [
    "2024-01-15",
    "2024-01-15t10:20:30Z",
    "2024-01-15T10:20:30z",
    "2024-01-15 10:20:30Z",
    "Mon, 15 Jan 2024 10:20:30 GMT",
    "2024-01-15T10:20Z",
    "2024-01-15T10:20:30",
  ]) {
    const record = { fullConversationHeadersOnly: [{ type: 1, createdAt }] };
    assert.equal(sqlRecencyFor(record), null, createdAt);
    assert.equal(assessedLastActivityAt(record), 0, createdAt);
  }
});

// MARK: - Cursor canonical ISO grammar: fractional-second digit-count
// boundary. GLOB has no `{1,3}`-style repetition operator, so
// `cursorRecencySqlExpression`'s shape guard has to spell out each digit
// count (1, 2, 3) as its own alternative rather than reach for an
// unrestricted `.*` wildcard — `.*` would also match a 4-or-more-digit
// (sub-millisecond) fraction, which `julianday()`, `Date.parse`, and
// Swift's `Date.ISO8601FormatStyle` are each free to round to a DIFFERENT
// integer millisecond, silently breaking the cross-engine recency parity
// this whole grammar exists to guarantee. `isCanonicalCursorIsoTimestamp`
// must reject the exact same 4+-digit shapes the SQL guard rejects, and
// every value both accept must resolve to the identical millisecond value.

test("Cursor canonical ISO grammar accepts exactly 1-3 fractional-second digits and rejects the 0- and 4-digit boundary cutoffs, in lockstep with the SQL shape guard and Date.parse", () => {
  const acceptedFractionDigits = ["1", "12", "123", "000", "007", "999"];
  for (const fraction of acceptedFractionDigits) {
    for (const zone of ["Z", "+00:00", "-05:30"]) {
      const value = `2024-01-15T10:20:30.${fraction}${zone}`;
      assert.equal(isCanonicalCursorIsoTimestamp(value), true, value);
      const parsedMs = Date.parse(value);
      assert.ok(Number.isFinite(parsedMs), value);
      const record = { status: "generating", lastUpdatedAt: value };
      assert.equal(sqlRecencyFor(record), parsedMs, value);
      assert.equal(assessedLastActivityAt(record), parsedMs, value);
    }
  }

  // Lower-bound cutoff: a bare `.` with ZERO fractional digits (one digit
  // short of the 1-3 range) must be rejected exactly like the upper-bound
  // cutoff, a 4-(or-more)-digit fraction (one digit over). Since the field
  // is DEFINED but fails the shape guard, SQL recency is now unrankable
  // (`NULL`) rather than a `COALESCE(..., 0)`-defaulted `0`.
  const rejectedFractionShapes = ["", "1234", "12345", "123456"];
  for (const fraction of rejectedFractionShapes) {
    const value = `2024-01-15T10:20:30.${fraction}Z`;
    assert.equal(isCanonicalCursorIsoTimestamp(value), false, value);
    assert.equal(parseCursorTimestamp(value), null, value);
    const record = { status: "generating", lastUpdatedAt: value };
    assert.equal(sqlRecencyFor(record), null, value);
    assert.equal(assessedLastActivityAt(record), 0, value);
  }
});

// MARK: - Cursor SQL recency: no COALESCE(..., 0) default for a composer
// with no rankable root or header timestamp at all.
//
// `rootRecency` used to default an entirely absent/unrankable set of root
// fields to `COALESCE(..., 0)`, so a composer with NEITHER a root
// timestamp NOR a valid header timestamp got a definite, rankable SQL
// recency of exactly `0` instead of the correct `NULL` ("unrankable").
// `isDefinitelyOlderThanWindowLowerBound(0, ...)` reports literal
// epoch-zero as definitively old, so the row-limit sentinel
// (`agent-detector.test.ts`'s "no root or header timestamp at all" case)
// would have wrongly treated hitting the cap on such a row as "safe to
// truncate". A header-only composer must still rank correctly — only a
// composer with no signal anywhere becomes unrankable.

test("Cursor SQL recency is NULL, never 0, for a composer with no root timestamp and no valid header — while header-only recency keeps working", () => {
  const noSignalAtAll = { status: "completed" };
  assert.equal(sqlRecencyFor(noSignalAtAll), null, JSON.stringify(noSignalAtAll));
  // The assessor's own in-memory `lastActivityAt` still separately seeds
  // `0` as a JS fallback — that in-memory fallback is never surfaced by
  // this SQL expression, which is exactly the point: the two are allowed
  // to diverge (SQL NULL vs. assessor 0) so the row-limit sentinel treats
  // this row as inconclusive rather than definitively old.
  assert.equal(assessedLastActivityAt(noSignalAtAll), 0);
  assert.equal(isDefinitelyOlderThanWindowLowerBound(0, now, SESSION_CANDIDATE_WINDOW_MS), true);

  // A record with only malformed/unrankable headers (no root fields
  // either) must likewise stay NULL, not fall back to a rankable 0.
  const onlyMalformedHeaders = { fullConversationHeadersOnly: [42, null, "x"] };
  assert.equal(sqlRecencyFor(onlyMalformedHeaders), null, JSON.stringify(onlyMalformedHeaders));

  // Header-only recency must still work when a header genuinely IS valid,
  // even though the root fields remain entirely absent.
  const headerOnlyValid = { fullConversationHeadersOnly: [{ type: 2, createdAt: now }] };
  assert.equal(sqlRecencyFor(headerOnlyValid), now, JSON.stringify(headerOnlyValid));
  assert.equal(assessedLastActivityAt(headerOnlyValid), now);
});

// MARK: - Cursor row-limit truncation safety: overflow-safe lower-bound
// comparison (`isDefinitelyOlderThanWindowLowerBound`), not `isRecentTimestamp`.
//
// `isRecentTimestamp` reports a far-future timestamp as "not recent" (its
// future-skew tolerance rejects it), which is a completely different claim
// from "definitely older than the candidate window's lower bound". Treating
// "not recent" as "safe to truncate" would let a corrupt/adversarial
// far-future recency value rank ahead of, and thereby hide, a genuinely
// active composer beyond `CURSOR_MAX_INSPECTED_ROWS`.

test("isDefinitelyOlderThanWindowLowerBound is not the negation of isRecentTimestamp: a far-future timestamp is inconclusive, not safe", () => {
  const now = 1_700_000_000_000;
  const windowMs = SESSION_CANDIDATE_WINDOW_MS;
  const farFuture = now + 365 * 24 * 60 * 60 * 1000;

  // isRecentTimestamp reports the far-future timestamp as NOT recent...
  assert.equal(isRecentTimestamp(farFuture, now, windowMs), false);
  // ...but it must also NOT be treated as definitively old: it is neither
  // recent nor safely-in-the-past, it is inconclusive.
  assert.equal(isDefinitelyOlderThanWindowLowerBound(farFuture, now, windowMs), false);

  // A genuinely recent timestamp is inconclusive too (not definitively old).
  assert.equal(isDefinitelyOlderThanWindowLowerBound(now - 1_000, now, windowMs), false);

  // Exactly at the lower bound is not *strictly* older, so still inconclusive.
  assert.equal(isDefinitelyOlderThanWindowLowerBound(now - windowMs, now, windowMs), false);

  // Only a timestamp strictly older than the lower bound is definitively old.
  assert.equal(isDefinitelyOlderThanWindowLowerBound(now - windowMs - 1, now, windowMs), true);
  assert.equal(isDefinitelyOlderThanWindowLowerBound(0, now, windowMs), true);
});
