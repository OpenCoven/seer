import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  utimesSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  CURSOR_MAX_BUBBLE_LOOKUPS,
  CURSOR_MAX_INSPECTED_ROWS,
  CURSOR_MAX_RECENT_HEADERS_PER_COMPOSER,
  CURSOR_MAX_TOTAL_DECODED_VALUE_BYTES,
  SESSION_CANDIDATE_WINDOW_MS,
} from "./agent-detection-policy";
import {
  CURSOR_WORKER_SOURCE,
  CursorSessionScanError,
  MAX_SESSION_INSPECTED_DIRECTORIES_PER_ROOT,
  MAX_SESSION_INSPECTED_ENTRIES_PER_ROOT,
  detectCursorComposerActivity,
  walkRecentSessionsWithStats,
} from "./agent-detector";

const repoRoot = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const detectorSource = readFileSync(join(repoRoot, "main/services/agent-detector.ts"), "utf8");
const now = 1_700_000_000_000;

async function withDatabase(callback: (database: string) => Promise<void>) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "cursor-stream-"));
  const database = join(scratch, "state.vscdb");
  try {
    execFileSync("/usr/bin/sqlite3", [
      database,
      "CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value TEXT);",
    ]);
    await callback(database);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

async function withScratch(callback: (scratch: string) => Promise<void>) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "session-walk-"));
  try {
    await callback(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

function sqlString(value: string) {
  return `'${value.replace(/'/g, "''")}'`;
}

function insertRows(database: string, rows: Array<{ key: string; value: string }>) {
  const values = rows
    .map(({ key, value }) => `(${sqlString(key)},${sqlString(value)})`)
    .join(",");
  execFileSync("/usr/bin/sqlite3", [
    database,
    `INSERT INTO cursorDiskKV (key, value) VALUES ${values};`,
  ]);
}

/**
 * Inserts many/large rows directly through `node:sqlite` rather than the
 * `/usr/bin/sqlite3` CLI: the adversarial tests below need thousands of rows
 * or tens of megabytes of value text, which would blow past the OS's
 * single-argument command-line length limit if passed as one inline SQL
 * string to `execFileSync` the way the small fixtures above do.
 */
function insertManyRowsFast(database: string, rows: Array<{ key: string; value: string }>) {
  const db = new DatabaseSync(database);
  try {
    const insert = db.prepare("INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)");
    db.exec("BEGIN");
    for (const { key, value } of rows) {
      insert.run(key, value);
    }
    db.exec("COMMIT");
  } finally {
    db.close();
  }
}

/**
 * Inserts `count` rows with keys that never match `key LIKE 'composerData:%'`,
 * without ever materializing a giant `{ key, value }[]` array in JS memory
 * first (unlike `insertManyRowsFast`) — the adversarial responsiveness test
 * below needs a row count large enough to make SQLite's full-table scan
 * (see `cursorRecencySqlExpression`'s doc comment on why `ORDER BY` defeats
 * the `LIKE` prefix optimization here) take a non-trivial amount of time.
 */
function insertManyNonMatchingRowsFast(database: string, count: number) {
  const db = new DatabaseSync(database);
  try {
    const insert = db.prepare("INSERT INTO cursorDiskKV (key, value) VALUES (?, ?)");
    db.exec("BEGIN");
    for (let index = 0; index < count; index += 1) {
      insert.run(`otherKey:${index}`, "x");
    }
    db.exec("COMMIT");
  } finally {
    db.close();
  }
}

/** Simulates Cursor's real UPSERT-in-place behavior: same rowid, new value. */
function updateRowValueFast(database: string, key: string, value: string) {
  const db = new DatabaseSync(database);
  try {
    db.prepare("UPDATE cursorDiskKV SET value = ? WHERE key = ?").run(value, key);
  } finally {
    db.close();
  }
}

test("Cursor SQLite bounded query surfaces the newest active composer despite many stale/malformed rows", async () => {
  await withDatabase(async (database) => {
    const rows = Array.from({ length: 205 }, (_, index) => ({
      key: `composerData:a-${String(index).padStart(3, "0")}`,
      value: index % 2 === 0
        ? '{"status":'
        : '{"status":"completed","lastUpdatedAt":0}',
    }));
    rows.push({
      key: "composerData:z-active",
      value: `{"status":"generating","lastUpdatedAt":${now}}`,
    });
    insertRows(database, rows);

    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active.map(({ identity }) => identity), ["z-active"]);
  });

  // Migrated off the `/usr/bin/sqlite3` CLI (unbounded `spawn`-and-stream
  // design) onto `node:sqlite`'s bounded, parameterized query API, run
  // inside a terminable Worker — see `runCursorScanInWorker`.
  assert.doesNotMatch(detectorSource, /\bspawn\(/);
  assert.match(detectorSource, /DatabaseSync/);
  // Recency now comes from a validated JSON timestamp expression (see
  // `cursorRecencySqlExpression`), ordered newest-first with rowid only as
  // a deterministic tiebreaker — never bare `rowid` alone, which is only
  // ever insertion order and never moves when Cursor UPSERTs an existing
  // composer row in place.
  assert.match(detectorSource, /cursorRecencySqlExpression/);
  assert.match(detectorSource, /ORDER BY recencyMs DESC, rowid DESC/);
  assert.doesNotMatch(detectorSource, /ORDER BY rowid DESC(?! *,)/);
});

test("Cursor scan Worker source never spawns a descendant Worker", () => {
  // The assembled Worker source destructures `parentPort`/`workerData`
  // from `node:worker_threads` but must never reference `Worker` itself —
  // otherwise a scan could spawn further descendants of its own.
  assert.doesNotMatch(CURSOR_WORKER_SOURCE, /new Worker\(/);
  assert.match(CURSOR_WORKER_SOURCE, /parentPort/);
  assert.match(CURSOR_WORKER_SOURCE, /workerData/);
  // The malformed-row catch must never log the row's own key/value/record
  // content — only a bare notification (see the "isolates malformed
  // header rows" test below for the behavioral half of this guarantee).
  assert.match(
    CURSOR_WORKER_SOURCE,
    /try\s*\{[\s\S]*assessCursorComposerRecord[\s\S]*\}\s*catch\s*\{[\s\S]*malformedRow/,
  );
});

test("Cursor SQLite skips every malformed value independently", async () => {
  await withDatabase(async (database) => {
    insertRows(database, [
      { key: "composerData:broken", value: "{" },
      { key: "composerData:array", value: "[]" },
      { key: "composerData:scalar", value: '"generating"' },
      { key: "composerData:valid", value: `{"status":"generating","lastUpdatedAt":${now}}` },
    ]);

    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active.map(({ identity }) => identity), ["valid"]);
  });
});

test("Cursor SQLite isolates malformed header rows and still returns a later valid composer", async () => {
  await withDatabase(async (database) => {
    insertRows(database, [
      {
        key: "composerData:null-header",
        value: JSON.stringify({
          status: "completed",
          lastUpdatedAt: now,
          fullConversationHeadersOnly: [null],
        }),
      },
      {
        key: "composerData:primitive-header",
        value: JSON.stringify({
          status: "completed",
          lastUpdatedAt: now,
          fullConversationHeadersOnly: [42],
        }),
      },
      {
        key: "composerData:invalid-fields",
        value: JSON.stringify({
          status: "completed",
          fullConversationHeadersOnly: [{ type: "1", createdAt: now }],
        }),
      },
      {
        key: "composerData:valid",
        value: JSON.stringify({ status: "generating", lastUpdatedAt: now }),
      },
    ]);

    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active.map(({ identity }) => identity), ["valid"]);
  });

  assert.match(
    detectorSource,
    /try\s*\{[\s\S]*assessCursorComposerRecord[\s\S]*\}\s*catch\s*\{[\s\S]*Skipped malformed Cursor composer row/,
  );
  assert.doesNotMatch(detectorSource, /Skipped malformed Cursor composer row[\s\S]{0,120}\b(?:key|value|record)\b/);
});

// MARK: - Cursor: realistic bubble-row tool status (issue B)

test("Cursor bubbleId row toolFormerData.status=inProgress makes the referencing composer active", async () => {
  await withDatabase(async (database) => {
    insertRows(database, [
      {
        key: "composerData:realistic-active",
        value: JSON.stringify({
          status: "completed",
          lastUpdatedAt: now - 65_000,
          fullConversationHeadersOnly: [
            { type: 1, createdAt: now - 65_000 },
            { type: 2, createdAt: now - 60_000, bubbleId: "bubble-tool-1" },
          ],
        }),
      },
      {
        key: "bubbleId:realistic-active:bubble-tool-1",
        value: JSON.stringify({ toolFormerData: { status: "inProgress" } }),
      },
    ]);

    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active.map(({ identity }) => identity), ["realistic-active"]);
    assert.equal(active[0]?.reason, "tool_call in progress");
  });
});

test("Cursor composer referencing a bubble row that was never written stays inactive", async () => {
  await withDatabase(async (database) => {
    insertRows(database, [
      {
        key: "composerData:dangling-bubble",
        value: JSON.stringify({
          status: "completed",
          lastUpdatedAt: now - 65_000,
          fullConversationHeadersOnly: [
            { type: 1, createdAt: now - 65_000 },
            { type: 2, createdAt: now - 60_000, bubbleId: "bubble-never-written" },
          ],
        }),
      },
      // Deliberately no "bubbleId:dangling-bubble:bubble-never-written" row.
    ]);

    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active, []);
  });
});

test("Cursor legacy embedded toolFormerStatus is still detected active through the real SQLite path", async () => {
  await withDatabase(async (database) => {
    insertRows(database, [
      {
        key: "composerData:legacy-active",
        value: JSON.stringify({
          status: "completed",
          lastUpdatedAt: now - 5_000,
          fullConversationHeadersOnly: [
            { type: 2, createdAt: now - 5_000, grouping: { toolFormerStatus: "inProgress" } },
          ],
        }),
      },
    ]);

    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active.map(({ identity }) => identity), ["legacy-active"]);
    assert.equal(active[0]?.reason, "tool_call in progress");
  });
});

test("Cursor duplicate bubble references within one composer cost exactly one lookup", async () => {
  await withDatabase(async (database) => {
    insertRows(database, [
      {
        key: "composerData:duplicate-refs",
        value: JSON.stringify({
          status: "completed",
          lastUpdatedAt: now - 65_000,
          fullConversationHeadersOnly: [
            { type: 1, createdAt: now - 65_000 },
            { type: 2, createdAt: now - 64_000, bubbleId: "bubble-dup" },
            { type: 2, createdAt: now - 63_000, bubbleId: "bubble-dup" },
            { type: 2, createdAt: now - 60_000, bubbleId: "bubble-dup" },
          ],
        }),
      },
      {
        key: "bubbleId:duplicate-refs:bubble-dup",
        value: JSON.stringify({ toolFormerData: { status: "inProgress" } }),
      },
    ]);

    let bubbleLookups = 0;
    const active = await detectCursorComposerActivity(now, database, {
      onBubbleLookup: () => {
        bubbleLookups += 1;
      },
    });

    assert.deepEqual(active.map(({ identity }) => identity), ["duplicate-refs"]);
    assert.equal(bubbleLookups, 1, "three references to the same bubble id must cost exactly one lookup");
  });
});

// MARK: - Cursor: bounded scan adversarial tests (issue A)

test("Cursor row limit recovers when thousands of old rows exist beyond the newest candidates", async () => {
  await withDatabase(async (database) => {
    // Comfortably more than CURSOR_MAX_INSPECTED_ROWS (2000), all sharing
    // the same old (epoch-zero) recency, plus one genuinely active
    // composer. Every "old" row is provably no newer than the row-limit
    // sentinel, so hitting the row cap here must not permanently fail the
    // scan (issue: "throwing whenever >2000 composers permanently freezes
    // retained state").
    const totalRows = CURSOR_MAX_INSPECTED_ROWS + 50;
    const rows = Array.from({ length: totalRows }, (_, index) => ({
      key: `composerData:row-${String(index).padStart(5, "0")}`,
      value: '{"status":"completed","lastUpdatedAt":0}',
    }));
    rows.push({
      key: "composerData:z-active",
      value: `{"status":"generating","lastUpdatedAt":${now}}`,
    });
    insertManyRowsFast(database, rows);

    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active.map(({ identity }) => identity), ["z-active"]);
  });
});

test("Cursor row limit still throws when the cut-off candidate could plausibly still be active", async () => {
  await withDatabase(async (database) => {
    // CURSOR_MAX_INSPECTED_ROWS + 50 rows, each with its OWN recent (but
    // non-active — "completed") timestamp a few seconds apart. Ordered
    // newest-first, the (cap + 1)-th row (the sentinel) is still only a
    // couple of seconds older than `now` — comfortably inside
    // SESSION_CANDIDATE_WINDOW_MS — so the scan cannot prove every omitted
    // row is too old to matter, and must still reject rather than risk
    // silently dropping a real active composer.
    const totalRows = CURSOR_MAX_INSPECTED_ROWS + 50;
    const rows = Array.from({ length: totalRows }, (_, index) => ({
      key: `composerData:recent-${String(index).padStart(5, "0")}`,
      value: `{"status":"completed","lastUpdatedAt":${now - index}}`,
    }));
    // The (cap + 1)-th row (0-indexed: CURSOR_MAX_INSPECTED_ROWS) is the
    // sentinel; confirm it really is inside the candidate window so the
    // scan's rejection below is a genuine truncation risk, not a fixture bug.
    assert.ok(CURSOR_MAX_INSPECTED_ROWS < SESSION_CANDIDATE_WINDOW_MS);
    insertManyRowsFast(database, rows);

    let inspectedRows = 0;
    await assert.rejects(
      () =>
        detectCursorComposerActivity(now, database, {
          onRowInspected: () => {
            inspectedRows += 1;
          },
        }),
      (error: unknown) => {
        assert.ok(error instanceof CursorSessionScanError);
        assert.equal(error.reason, "rowLimit");
        return true;
      },
    );

    assert.ok(inspectedRows > 0);
    assert.ok(inspectedRows <= CURSOR_MAX_INSPECTED_ROWS);
    assert.ok(inspectedRows < totalRows, "must never step through the entire table once bounded");
  });
});

// MARK: - Cursor row limit: overflow-safe lower-bound comparison
// (`isDefinitelyOlderThanWindowLowerBound`), not `isRecentTimestamp`.
//
// `isRecentTimestamp` reports a far-future timestamp as "not recent" too
// (its future-skew tolerance rejects anything more than a few seconds
// ahead of `now`), which is a completely different claim from "this
// candidate is definitively older than the window's lower bound". Treating
// "not recent" as "safe to truncate" is exactly the bug: a corrupt or
// adversarial far-future recency value ranks *ahead* of a genuinely active,
// present-day composer (SQL `ORDER BY recencyMs DESC` puts the larger,
// future value first), pushing the real composer past
// `CURSOR_MAX_INSPECTED_ROWS` — and then the future-dated sentinel would
// wrongly bless the truncation as safe, permanently and silently dropping
// the only genuinely active row in the whole table.

test("Cursor row limit still throws (never silently drops a hidden active composer) when 2000+ rows carry a far-future recency", async () => {
  await withDatabase(async (database) => {
    // Comfortably more than CURSOR_MAX_INSPECTED_ROWS, every one a
    // "completed" (never itself active) composer with its own unique
    // far-future timestamp — about a year ahead of `now`, well beyond both
    // TIMESTAMP_FUTURE_SKEW_MS and SESSION_CANDIDATE_WINDOW_MS in the
    // future direction. Ordered newest-first by recency, every one of
    // these ranks ahead of a real "now"-timestamped composer.
    const farFutureMs = now + 365 * 24 * 60 * 60 * 1000;
    const totalRows = CURSOR_MAX_INSPECTED_ROWS + 50;
    const rows = Array.from({ length: totalRows }, (_, index) => ({
      key: `composerData:future-${String(index).padStart(5, "0")}`,
      value: `{"status":"completed","lastUpdatedAt":${farFutureMs + index}}`,
    }));
    // A hidden, genuinely active composer: a real, current "now" timestamp.
    // Its recency is strictly smaller than every future-dated filler row
    // above, so it necessarily sorts behind all of them and falls beyond
    // CURSOR_MAX_INSPECTED_ROWS — exactly the scenario a truncation-safety
    // check must never wave through as safe.
    rows.push({
      key: "composerData:hidden-active",
      value: `{"status":"generating","lastUpdatedAt":${now}}`,
    });
    insertManyRowsFast(database, rows);

    await assert.rejects(
      () => detectCursorComposerActivity(now, database),
      (error: unknown) => {
        assert.ok(error instanceof CursorSessionScanError);
        assert.equal(error.reason, "rowLimit");
        return true;
      },
    );
  });
});

test("Cursor recency ordering ranks an updated old-rowid composer above stale high-rowid composers", async () => {
  await withDatabase(async (database) => {
    // "target" gets the lowest rowid (inserted first) with an old value.
    insertRows(database, [
      { key: "composerData:target", value: '{"status":"completed","lastUpdatedAt":0}' },
    ]);
    // CURSOR_MAX_INSPECTED_ROWS filler rows, every one with a strictly
    // higher rowid than "target" (inserted after it) but an equally old
    // (non-active) timestamp.
    const filler = Array.from({ length: CURSOR_MAX_INSPECTED_ROWS }, (_, index) => ({
      key: `composerData:filler-${String(index).padStart(5, "0")}`,
      value: '{"status":"completed","lastUpdatedAt":0}',
    }));
    insertManyRowsFast(database, filler);

    // Cursor UPSERTs an existing composer row in place: "target"'s rowid
    // does not change, only its value does.
    updateRowValueFast(database, "composerData:target", `{"status":"generating","lastUpdatedAt":${now}}`);

    // Under `ORDER BY rowid DESC` alone, "target" (the lowest rowid) would
    // sort dead last — behind all CURSOR_MAX_INSPECTED_ROWS filler rows —
    // and would never be reached within the row cap. Validated JSON
    // recency must rank it first instead, since it is now the newest
    // activity by actual timestamp.
    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active.map(({ identity }) => identity), ["target"]);
    assert.equal(active[0]?.reason, "generating");
  });
});

// MARK: - Cursor row limit + extended recency shapes (header-only / string
// timestamps): proves `cursorRecencySqlExpression` covering every
// assessor-active timestamp shape (not just numeric root fields) is load
// bearing for the row-limit sentinel's safety, not merely cosmetic.

test("Cursor row limit recovers and detects a lower-rowid active composer whose only recency signal is a conversation header timestamp, despite 2000+ older numeric rows", async () => {
  await withDatabase(async (database) => {
    // No root-level lastUpdatedAt/createdAt/conversationCheckpointLastUpdatedAt
    // at all — this composer's ONLY recency signal is a
    // fullConversationHeadersOnly[*].createdAt. Before
    // cursorRecencySqlExpression covered headers, this row's SQL recency
    // was NULL (unrankable): it sorted dead last under
    // `ORDER BY recencyMs DESC` no matter how recent its header actually
    // was, so thousands of "old but numerically rankable" rows could push
    // it beyond CURSOR_MAX_INSPECTED_ROWS and silently drop it. Inserted
    // first so it also has the lowest rowid, ruling out the rowid
    // tiebreaker from accidentally saving it.
    insertRows(database, [
      {
        key: "composerData:header-only-active",
        value: JSON.stringify({
          fullConversationHeadersOnly: [{ type: 1, createdAt: now }],
        }),
      },
    ]);

    // Comfortably more than CURSOR_MAX_INSPECTED_ROWS, every one an old
    // (epoch-zero), purely-numeric, inactive composer with a strictly
    // higher rowid than the header-only composer above.
    const totalRows = CURSOR_MAX_INSPECTED_ROWS + 50;
    const filler = Array.from({ length: totalRows }, (_, index) => ({
      key: `composerData:old-${String(index).padStart(5, "0")}`,
      value: '{"status":"completed","lastUpdatedAt":0}',
    }));
    insertManyRowsFast(database, filler);

    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active.map(({ identity }) => identity), ["header-only-active"]);
  });
});

test("Cursor row limit recovers and detects a lower-rowid active composer with an ISO-8601 string root timestamp, despite 2000+ older numeric rows", async () => {
  await withDatabase(async (database) => {
    // The only recency signal is lastUpdatedAt as an ISO-8601 string
    // (Date.prototype.toISOString()'s own canonical shape) instead of a
    // JSON number — before cursorRecencySqlExpression accepted string
    // timestamps, `json_type(...) IN ('integer', 'real')` excluded it
    // entirely, so this row's SQL recency was also NULL.
    insertRows(database, [
      {
        key: "composerData:string-timestamp-active",
        value: JSON.stringify({ status: "generating", lastUpdatedAt: new Date(now).toISOString() }),
      },
    ]);

    const totalRows = CURSOR_MAX_INSPECTED_ROWS + 50;
    const filler = Array.from({ length: totalRows }, (_, index) => ({
      key: `composerData:old-${String(index).padStart(5, "0")}`,
      value: '{"status":"completed","lastUpdatedAt":0}',
    }));
    insertManyRowsFast(database, filler);

    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active.map(({ identity }) => identity), ["string-timestamp-active"]);
  });
});

test("Cursor row limit still throws when the cut-off candidate's header-derived timestamp could plausibly still be active", async () => {
  await withDatabase(async (database) => {
    // Mirrors "Cursor row limit still throws when the cut-off candidate
    // could plausibly still be active" above, but every row's ONLY
    // recency signal is a conversation header's createdAt rather than a
    // root field — proving the new header-recency contribution
    // participates in the exact same fail-safe "ambiguous sentinel" check
    // instead of quietly bypassing it (e.g. by mis-ranking a genuinely
    // recent header-only row as unrankable/old).
    const totalRows = CURSOR_MAX_INSPECTED_ROWS + 50;
    const rows = Array.from({ length: totalRows }, (_, index) => ({
      key: `composerData:recent-header-${String(index).padStart(5, "0")}`,
      value: JSON.stringify({
        status: "completed",
        fullConversationHeadersOnly: [{ type: 2, createdAt: now - index }],
      }),
    }));
    // The (cap + 1)-th row (0-indexed: CURSOR_MAX_INSPECTED_ROWS) is the
    // sentinel; confirm it really is inside the candidate window so the
    // scan's rejection below is a genuine truncation risk, not a fixture bug.
    assert.ok(CURSOR_MAX_INSPECTED_ROWS < SESSION_CANDIDATE_WINDOW_MS);
    insertManyRowsFast(database, rows);

    await assert.rejects(
      () => detectCursorComposerActivity(now, database),
      (error: unknown) => {
        assert.ok(error instanceof CursorSessionScanError);
        assert.equal(error.reason, "rowLimit");
        return true;
      },
    );
  });
});

test("Cursor row limit recovers when thousands of old rows carry only header-derived or string recency", async () => {
  await withDatabase(async (database) => {
    // Same shape as "Cursor row limit recovers when thousands of old rows
    // exist beyond the newest candidates" above, but exercising the new
    // header/string recency paths for the *old* history itself: every
    // filler row's own recency is unambiguously old (epoch-zero-ish) via a
    // header createdAt or a string createdAt, not a numeric root field —
    // proving old header/string-derived rows are correctly recognized as
    // old (not accidentally left unrankable-NULL, which would still be
    // "safe" but would defeat the point of ranking them at all) and so
    // hitting the row cap here must not permanently fail the scan.
    const totalRows = CURSOR_MAX_INSPECTED_ROWS + 50;
    const rows: Array<{ key: string; value: string }> = [];
    for (let index = 0; index < totalRows; index += 1) {
      rows.push(
        index % 2 === 0
          ? {
              key: `composerData:old-header-${String(index).padStart(5, "0")}`,
              value: JSON.stringify({
                status: "completed",
                fullConversationHeadersOnly: [{ type: 2, createdAt: 0 }],
              }),
            }
          : {
              key: `composerData:old-string-${String(index).padStart(5, "0")}`,
              value: JSON.stringify({
                status: "completed",
                lastUpdatedAt: new Date(0).toISOString(),
              }),
            },
      );
    }
    rows.push({
      key: "composerData:z-active",
      value: `{"status":"generating","lastUpdatedAt":${now}}`,
    });
    insertManyRowsFast(database, rows);

    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active.map(({ identity }) => identity), ["z-active"]);
  });
});

// MARK: - Cursor row limit + canonical ISO-8601 grammar: previously-lenient
// string timestamp shapes (issue: `parseCursorTimestamp` used unrestricted
// `Date.parse`, so a lower-case `t`/`z`, date-only, space-separated, or
// no-seconds string could make the TS assessor call a composer "active"
// even though `cursorRecencySqlExpression`'s SQL shape guard (and Swift's
// `Date.ISO8601FormatStyle`) already rejected the exact same value as
// unrankable) must never surface as an active composer, while a genuinely
// canonical ISO string timestamp remains detected in the very same scan.

test("Cursor row limit: previously-lenient ISO string timestamps never surface as an active composer, and a canonical ISO string root timestamp is still detected among 2000+ older rows", async () => {
  await withDatabase(async (database) => {
    const isoNow = new Date(now).toISOString();
    assert.match(isoNow, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);

    // Every one of these previously parsed successfully (to exactly `now`)
    // under an unrestricted `Date.parse`-backed `parseCursorTimestamp` — an
    // old, over-lenient parser would have called each of these composers
    // "active". `isCanonicalCursorIsoTimestamp` now rejects all of them, so
    // `validateCursorRecordFields` rejects the whole record as malformed
    // before "generating" status is ever consulted. Inserted first (lowest
    // rowid) so rowid ordering cannot accidentally save any of them either.
    insertRows(database, [
      {
        key: "composerData:lenient-lowercase-z",
        value: JSON.stringify({ status: "generating", lastUpdatedAt: isoNow.replace("Z", "z") }),
      },
      {
        key: "composerData:lenient-lowercase-t",
        value: JSON.stringify({ status: "generating", lastUpdatedAt: isoNow.replace("T", "t") }),
      },
      {
        key: "composerData:lenient-space-separated",
        value: JSON.stringify({ status: "generating", lastUpdatedAt: isoNow.replace("T", " ") }),
      },
      {
        key: "composerData:lenient-date-only",
        value: JSON.stringify({ status: "generating", lastUpdatedAt: isoNow.slice(0, 10) }),
      },
      {
        key: "composerData:lenient-no-seconds",
        value: JSON.stringify({ status: "generating", lastUpdatedAt: `${isoNow.slice(0, 16)}Z` }),
      },
      // A genuinely canonical ISO string root timestamp — the one shape
      // this grammar DOES accept — must still be found despite sharing the
      // same scan with the rejected shapes above and 2000+ older rows below.
      {
        key: "composerData:canonical-string-active",
        value: JSON.stringify({ status: "generating", lastUpdatedAt: isoNow }),
      },
    ]);

    const totalRows = CURSOR_MAX_INSPECTED_ROWS + 50;
    const filler = Array.from({ length: totalRows }, (_, index) => ({
      key: `composerData:old-${String(index).padStart(5, "0")}`,
      value: '{"status":"completed","lastUpdatedAt":0}',
    }));
    insertManyRowsFast(database, filler);

    const active = await detectCursorComposerActivity(now, database);

    assert.deepEqual(active.map(({ identity }) => identity), ["canonical-string-active"]);
  });
});

// MARK: - Cursor row limit + no-COALESCE-default recency sentinel (issue:
// `cursorRecencySqlExpression`'s `rootRecency` used to default an entirely
// absent set of root timestamp fields to `COALESCE(..., 0)`, so a composer
// with no root timestamp AND no valid header timestamp got a definite,
// rankable SQL recency of exactly `0` instead of the correct `NULL`
// ("unrankable"). `isDefinitelyOlderThanWindowLowerBound(0, ...)` reports
// literal epoch-zero as definitively old, so the row-limit sentinel wrongly
// treated hitting the cap on such a row as "safe to truncate" — the same
// class of false-safe verdict the far-future-sentinel regression test
// above already guards against for the opposite (too-new) direction.

test("Cursor row limit stays inconclusive, never definitively old, when the cut-off candidate has no root or header timestamp at all despite 2000+ such composers", async () => {
  await withDatabase(async (database) => {
    // Every row is valid JSON with a `status` field but NO root
    // `lastUpdatedAt`/`createdAt`/`conversationCheckpointLastUpdatedAt` and
    // no `fullConversationHeadersOnly` at all — the composer's SQL recency
    // must be NULL (unrankable), never the old `COALESCE(..., 0)` default.
    const totalRows = CURSOR_MAX_INSPECTED_ROWS + 50;
    const rows = Array.from({ length: totalRows }, (_, index) => ({
      key: `composerData:no-timestamp-${String(index).padStart(5, "0")}`,
      value: '{"status":"completed"}',
    }));
    insertManyRowsFast(database, rows);

    await assert.rejects(
      () => detectCursorComposerActivity(now, database),
      (error: unknown) => {
        assert.ok(error instanceof CursorSessionScanError);
        assert.equal(
          error.reason,
          "rowLimit",
          "an unrankable (NULL) cut-off sentinel must stay inconclusive, never be treated as definitively old",
        );
        return true;
      },
    );
  });
});

test("Cursor scan Worker byte-count thresholds are bound named parameters, never interpolated SQL", () => {
  // The composer/bubble CASE projections' byte threshold must be a bound
  // named parameter ($maxValueBytes) resolved at `.get`/`.iterate` call
  // time, never a string-interpolated numeric literal baked into the SQL
  // text — otherwise the "threshold" reads as an untrusted-SQL-injection
  // shape during review, even though today's value happens to be a fixed
  // constant. Same for the composer key-prefix filter, row limit, and the
  // bubble lookup's key equality: every value that varies per call is a
  // named parameter, never string concatenation into SQL.
  assert.match(detectorSource, /octet_length\(value\) <= \$maxValueBytes/);
  assert.match(detectorSource, /maxValueBytes: workerData\.maxValueBytes/);
  assert.match(detectorSource, /key LIKE \$keyPattern/);
  assert.match(detectorSource, /LIMIT \$rowLimit/);
  assert.match(detectorSource, /key = \$bubbleKey/);
  assert.doesNotMatch(detectorSource, /octet_length\(value\) <= "\s*\+/);
  assert.doesNotMatch(detectorSource, /<=\s*\$\{/);
  // Selects a bounded projection plus its own byte-count column — never
  // raw `value` — for both the composer and bubble queries.
  assert.match(detectorSource, /AS boundedValue, octet_length\(value\) AS valueByteCount/);
});

test("Cursor cumulative decoded byte limit exceeded throws scanIncomplete", async () => {
  await withDatabase(async (database) => {
    const padding = "x".repeat(3_500_000);
    const rows = Array.from({ length: 20 }, (_, index) => ({
      key: `composerData:big-${String(index).padStart(2, "0")}`,
      value: `{"status":"completed","lastUpdatedAt":0,"padding":"${padding}"}`,
    }));
    // 20 * 3.5MB = 70MB, comfortably over CURSOR_MAX_TOTAL_DECODED_VALUE_BYTES
    // (64MB) while each row stays under the per-row CURSOR_MAX_VALUE_BYTES cap.
    assert.ok(rows.length * 3_500_000 > CURSOR_MAX_TOTAL_DECODED_VALUE_BYTES);
    insertManyRowsFast(database, rows);

    await assert.rejects(
      () => detectCursorComposerActivity(now, database),
      (error: unknown) => {
        assert.ok(error instanceof CursorSessionScanError);
        assert.equal(error.reason, "decodedByteLimit");
        return true;
      },
    );
  });
});

test("Cursor bubble lookup limit exceeded throws scanIncomplete", async () => {
  await withDatabase(async (database) => {
    // 55 * 8 = 440 distinct bubble references > CURSOR_MAX_BUBBLE_LOOKUPS (400).
    const composerCount = 55;
    const rows = Array.from({ length: composerCount }, (_, composerIndex) => {
      const headers = Array.from({ length: CURSOR_MAX_RECENT_HEADERS_PER_COMPOSER }, (_, bubbleIndex) => ({
        type: 2,
        createdAt: now - 60_000 + bubbleIndex,
        bubbleId: `tool-${composerIndex}-${bubbleIndex}`,
      }));
      return {
        key: `composerData:many-bubbles-${composerIndex}`,
        value: JSON.stringify({
          status: "completed",
          lastUpdatedAt: now - 61_000,
          fullConversationHeadersOnly: headers,
        }),
      };
    });
    assert.ok(composerCount * CURSOR_MAX_RECENT_HEADERS_PER_COMPOSER > CURSOR_MAX_BUBBLE_LOOKUPS);
    insertManyRowsFast(database, rows);

    let bubbleLookups = 0;
    await assert.rejects(
      () =>
        detectCursorComposerActivity(now, database, {
          onBubbleLookup: () => {
            bubbleLookups += 1;
          },
        }),
      (error: unknown) => {
        assert.ok(error instanceof CursorSessionScanError);
        assert.equal(error.reason, "bubbleLookupLimit");
        return true;
      },
    );

    assert.ok(bubbleLookups > 0);
    assert.ok(bubbleLookups <= CURSOR_MAX_BUBBLE_LOOKUPS);
  });
});

test("Cursor deadline exhaustion throws scanIncomplete before inspecting all rows", async () => {
  await withDatabase(async (database) => {
    const totalRows = 40;
    const rows = Array.from({ length: totalRows }, (_, index) => ({
      key: `composerData:slow-${String(index).padStart(2, "0")}`,
      value: '{"status":"completed","lastUpdatedAt":0}',
    }));
    insertManyRowsFast(database, rows);

    let inspectedRows = 0;
    await assert.rejects(
      () =>
        detectCursorComposerActivity(now, database, {
          onRowInspected: () => {
            inspectedRows += 1;
          },
          // The row loop now runs inside a Worker, so `onRowInspected`
          // cannot busy-wait the worker thread itself (a live callback
          // cannot cross the thread boundary at all) — this plain-data
          // seam crosses via `workerData` and busy-waits *inside* the
          // worker instead: 5ms per row, so a handful of rows blows a
          // 20ms deadline.
          simulateRowProcessingDelayMs: 5,
          deadlineMillisecondsOverride: 20,
        }),
      (error: unknown) => {
        assert.ok(error instanceof CursorSessionScanError);
        assert.equal(error.reason, "deadline");
        return true;
      },
    );

    assert.ok(inspectedRows > 0);
    assert.ok(inspectedRows < totalRows, "must stop before exhausting all rows once the deadline passes");
  });
});

test("Cursor scan keeps the main event loop responsive while SQLite scans many non-matching rows", async () => {
  await withDatabase(async (database) => {
    // A large number of rows that never match `key LIKE 'composerData:%'`
    // still cost SQLite a full table scan under the recency ORDER BY (see
    // `cursorRecencySqlExpression`'s own doc comment) — this must run
    // entirely off the main thread, in the scan Worker, so it can never
    // block this process's event loop regardless of table size.
    insertManyNonMatchingRowsFast(database, 1_000_000);

    let ticks = 0;
    const timer = setInterval(() => {
      ticks += 1;
    }, 2);
    let active: Awaited<ReturnType<typeof detectCursorComposerActivity>>;
    try {
      active = await detectCursorComposerActivity(now, database);
    } finally {
      clearInterval(timer);
    }

    assert.deepEqual(active, []);
    assert.ok(
      ticks > 0,
      "the main event loop must keep processing timers while the Cursor SQLite scan runs in its Worker",
    );
  });
});

test("session traversal bounds all entries in a huge directory while retaining recent candidates", async () => {
  await withScratch(async (root) => {
    const timestamp = new Date(now);
    for (let index = 0; index < 600; index += 1) {
      const candidate = join(root, `active-${String(index).padStart(5, "0")}.jsonl`);
      writeFileSync(candidate, "{}");
      utimesSync(candidate, timestamp, timestamp);
    }
    for (let index = 0; index < MAX_SESSION_INSPECTED_ENTRIES_PER_ROOT - 100; index += 1) {
      writeFileSync(join(root, `unrelated-${String(index).padStart(5, "0")}.txt`), "ignored");
    }

    const result = await walkRecentSessionsWithStats(root, [".jsonl"], now);

    assert.equal(result.inspectedEntries, MAX_SESSION_INSPECTED_ENTRIES_PER_ROOT);
    assert.equal(result.inspectedDirectories, 1);
    assert.ok(result.candidates.length > 0);
    assert.ok(result.candidates.length <= 400);
  });
});

test("session traversal independently bounds directories and never follows symlinks", async () => {
  await withScratch(async (root) => {
    const outside = mkdtempSync(join(repoRoot, "build", "session-walk-outside-"));
    try {
      const poison = join(outside, "poison.jsonl");
      writeFileSync(poison, "{}");
      utimesSync(poison, new Date(now), new Date(now));
      symlinkSync(outside, join(root, "linked"));
      for (let index = 0; index < MAX_SESSION_INSPECTED_DIRECTORIES_PER_ROOT + 50; index += 1) {
        mkdirSync(join(root, `directory-${String(index).padStart(5, "0")}`));
      }

      const result = await walkRecentSessionsWithStats(root, [".jsonl"], now);

      assert.equal(result.inspectedDirectories, MAX_SESSION_INSPECTED_DIRECTORIES_PER_ROOT);
      assert.ok(result.inspectedEntries <= MAX_SESSION_INSPECTED_ENTRIES_PER_ROOT);
      assert.ok(!result.candidates.some(({ filePath }) => filePath === poison));
    } finally {
      rmSync(outside, { recursive: true, force: true });
    }
  });
});
