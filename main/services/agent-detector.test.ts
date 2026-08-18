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
