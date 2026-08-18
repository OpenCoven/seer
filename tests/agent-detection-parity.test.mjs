import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
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
  TIMESTAMP_FUTURE_SKEW_MS,
  assessCursorComposerRecord,
  assessDetectionFixture,
  cursorRelevantBubbleIds,
  isRecentTimestamp,
  matchAgentKind,
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
