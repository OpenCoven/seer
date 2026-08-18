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
} from "./agent-detection-policy";
import {
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

  assert.doesNotMatch(detectorSource, /json_extract|json_array_length/);
  // Migrated off the `/usr/bin/sqlite3` CLI (unbounded `spawn`-and-stream
  // design) onto `node:sqlite`'s bounded, parameterized query API — see
  // `queryCursorComposers`/`runCursorScan`.
  assert.doesNotMatch(detectorSource, /\bspawn\(/);
  assert.match(detectorSource, /DatabaseSync/);
  assert.match(detectorSource, /ORDER BY rowid DESC/);
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

test("Cursor row limit exceeded throws CursorSessionScanError and bounds inspected rows", async () => {
  await withDatabase(async (database) => {
    const totalRows = CURSOR_MAX_INSPECTED_ROWS + 50;
    const rows = Array.from({ length: totalRows }, (_, index) => ({
      key: `composerData:row-${String(index).padStart(5, "0")}`,
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
        }),
      (error: unknown) => {
        assert.ok(error instanceof CursorSessionScanError);
        assert.equal(error.reason, "rowLimit");
        return true;
      },
    );

    assert.ok(inspectedRows > 0);
    assert.ok(inspectedRows <= CURSOR_MAX_INSPECTED_ROWS + 1);
    assert.ok(inspectedRows < totalRows, "must never step through the entire table once bounded");
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
            // 5ms synchronous busy-wait per row: a handful of rows blows a
            // 20ms deadline. The scan itself is fully synchronous, so this
            // must busy-wait rather than use a timer.
            const until = performance.now() + 5;
            while (performance.now() < until) {
              // busy-wait
            }
          },
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
