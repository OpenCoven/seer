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
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
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
  return `'${value.replaceAll("'", "''")}'`;
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

test("Cursor SQLite streams raw rows so stale and malformed prefixes do not hide active state", async () => {
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
  assert.match(detectorSource, /\bspawn\(/);
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
