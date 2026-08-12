import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { assessDetectionFixture } from "../main/services/agent-detection-policy.ts";

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

for (const testCase of oracle.cases) {
  test(`assessDetectionFixture: ${testCase.id}`, () => {
    const fixture = buildFixture(testCase);
    const result = assessDetectionFixture(fixture, now);
    assert.deepEqual(result, testCase.expected, testCase.id);
  });
}
