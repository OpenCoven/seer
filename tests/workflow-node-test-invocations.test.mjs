import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import {
  extractNodeTestInvocations,
  invocationHasTestFile,
  invocationPinsConcurrency1,
  tokenizeShellCommands,
} from "./helpers/workflow-node-test-invocations.mjs";

// Unit tests for the shared workflow `node --test` invocation parser used by
// tests/identity.test.mjs and tests/standalone-build-gate-serialization.test.mjs
// to guard which test files each CI workflow's explicit test-file lists
// actually register. A prior implementation matched a raw substring against
// each invocation's *reconstituted line text*, which meant a test path
// appearing anywhere in the same or a joined continuation line - including a
// `#` comment, an unrelated earlier/later shell command, or a similarly
// named file - would incorrectly satisfy the guard. These tests prove the
// replacement tokenizer/extractor rejects all of those cases and only
// accepts the literal path as its own exact `node --test` argument.

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);

const TARGET = "tests/standalone-build-gate-serialization.test.mjs";

function workflow(runScript) {
  return [
    "on: push",
    "jobs:",
    "  example:",
    "    runs-on: ubuntu-latest",
    "    steps:",
    "      - name: run tests",
    "        run: |",
    ...runScript.split("\n").map((line) => `          ${line}`),
  ].join("\n");
}

function registersTarget(source) {
  return extractNodeTestInvocations(source).some((invocation) =>
    invocationHasTestFile(invocation, TARGET),
  );
}

test("a target path mentioned only in a `#` comment does not satisfy registration", () => {
  const source = workflow(
    [
      `# node --test ${TARGET}`,
      "node --test --test-concurrency=1 tests/identity.test.mjs",
    ].join("\n"),
  );
  assert.equal(registersTarget(source), false);
});

test("a target path mentioned only as a trailing comment on the invocation line does not satisfy registration", () => {
  const source = workflow(
    `node --test --test-concurrency=1 tests/identity.test.mjs # was ${TARGET}`,
  );
  assert.equal(registersTarget(source), false);
});

test("a trailing backslash inside a comment does not continue the comment onto the next (real) command", () => {
  // Real shells do not treat a `\` at the end of a comment as a line
  // continuation - the comment simply ends at the newline like any other,
  // and the following physical line is parsed as its own command. This
  // proves the parser matches that behavior rather than naively swallowing
  // the next line into the comment (which would also incorrectly hide a
  // real, subsequent node --test invocation from the extractor).
  const source = workflow(
    [
      `# a note about ${TARGET} \\`,
      "node --test --test-concurrency=1 tests/identity.test.mjs",
    ].join("\n"),
  );
  const invocations = extractNodeTestInvocations(source);
  assert.equal(invocations.length, 1);
  assert.equal(invocationHasTestFile(invocations[0], TARGET), false);
  assert.equal(
    invocationHasTestFile(invocations[0], "tests/identity.test.mjs"),
    true,
  );
});

test("a target path mentioned only in an earlier command in the same run script does not satisfy registration", () => {
  const source = workflow(
    [
      `echo "about to run: ${TARGET}"`,
      "node --test --test-concurrency=1 tests/identity.test.mjs",
    ].join("\n"),
  );
  assert.equal(registersTarget(source), false);
});

test("a target path mentioned only in a later command in the same run script does not satisfy registration", () => {
  const source = workflow(
    [
      "node --test --test-concurrency=1 tests/identity.test.mjs",
      `cat ${TARGET}`,
    ].join("\n"),
  );
  assert.equal(registersTarget(source), false);
});

test("a target path quoted inside an echo whose text merely looks like a comment does not satisfy registration", () => {
  const source = workflow(
    [
      `echo "# ${TARGET}"`,
      "node --test --test-concurrency=1 tests/identity.test.mjs",
    ].join("\n"),
  );
  // The `#` here is inside double quotes on an unrelated `echo` command, so
  // it must not be parsed as a comment (it's real, quoted argument text to
  // `echo`) - but it must also not be mistaken for a node --test argument.
  assert.equal(registersTarget(source), false);
  const invocations = extractNodeTestInvocations(source);
  assert.equal(invocations.length, 1);
  assert.equal(invocations[0].tokens[0], "node");
});

test("a similarly named file does not satisfy registration via substring containment", () => {
  const source = workflow(
    [
      `node --test --test-concurrency=1 ${TARGET}.bak`,
      `node --test --test-concurrency=1 other/${TARGET}`,
      `node --test --test-concurrency=1 tests/standalone-build-gate-serialization.test.mjs2`,
    ].join("\n"),
  );
  assert.equal(registersTarget(source), false);
});

test("a target path after a shell operator (&&, ||, ;, |, &) in the same run script does not satisfy registration", () => {
  const operators = ["&&", "||", ";", "|", "&"];
  for (const op of operators) {
    const source = workflow(
      `node --test --test-concurrency=1 tests/identity.test.mjs ${op} echo ${TARGET}`,
    );
    assert.equal(
      registersTarget(source),
      false,
      `operator ${JSON.stringify(op)} must separate the echo from the node --test invocation`,
    );
    const invocations = extractNodeTestInvocations(source);
    assert.equal(invocations.length, 1, `operator ${JSON.stringify(op)}`);
    assert.equal(
      invocationHasTestFile(invocations[0], "tests/identity.test.mjs"),
      true,
      `operator ${JSON.stringify(op)}`,
    );
  }
});

test("a target path preceding a shell operator in a *different* node --test invocation does not leak into a later one", () => {
  const source = workflow(
    [
      `node --test --test-concurrency=1 ${TARGET} && node --test tests/identity.test.mjs`,
    ].join("\n"),
  );
  const invocations = extractNodeTestInvocations(source);
  assert.equal(invocations.length, 2);
  assert.equal(invocationHasTestFile(invocations[0], TARGET), true);
  assert.equal(invocationHasTestFile(invocations[1], TARGET), false);
});

test("a quoted (single- or double-quoted) exact target path still satisfies registration", () => {
  for (const quoted of [`"${TARGET}"`, `'${TARGET}'`]) {
    const source = workflow(
      `node --test --test-concurrency=1 tests/identity.test.mjs ${quoted}`,
    );
    assert.equal(
      registersTarget(source),
      true,
      `quoted form ${quoted} should still be recognized as the exact argument`,
    );
  }
});

test("a target path split across a backslash line continuation still satisfies registration", () => {
  const source = workflow(
    ["node --test --test-concurrency=1 \\", "  tests/identity.test.mjs \\", `  ${TARGET}`].join(
      "\n",
    ),
  );
  assert.equal(registersTarget(source), true);
});

test("real workflow explicit test-file lists register the target file as its own node --test invocation", () => {
  for (const relativePath of [
    ".github/workflows/standalone-ci.yml",
    ".github/workflows/release-macos.yml",
  ]) {
    const source = readFileSync(join(repoRoot, relativePath), "utf8");
    const invocations = extractNodeTestInvocations(source);
    assert.ok(
      invocations.length > 0,
      `expected at least one node --test invocation in ${relativePath}`,
    );
    assert.ok(
      invocations.some((invocation) => invocationHasTestFile(invocation, TARGET)),
      `expected ${relativePath} to register ${TARGET} as an exact node --test argument`,
    );
  }
});

test("real workflow renderer-lock invocations still pin --test-concurrency=1 (concurrency guard preserved)", () => {
  for (const relativePath of [
    ".github/workflows/standalone-ci.yml",
    ".github/workflows/release-macos.yml",
  ]) {
    const source = readFileSync(join(repoRoot, relativePath), "utf8");
    const invocations = extractNodeTestInvocations(source);
    const lockInvocations = invocations.filter((invocation) =>
      invocationHasTestFile(invocation, "tests/standalone-renderer-lock.test.mjs"),
    );
    assert.ok(lockInvocations.length > 0, relativePath);
    for (const invocation of lockInvocations) {
      assert.ok(invocationPinsConcurrency1(invocation), relativePath);
    }
  }
});

test("tokenizeShellCommands dequotes single- and double-quoted words and resolves backslash escapes", () => {
  const commands = tokenizeShellCommands(`echo "a b" 'c d' e\\ f`);
  assert.deepEqual(commands, [["echo", "a b", "c d", "e f"]]);
});

test("tokenizeShellCommands splits on control operators and newlines, and skips redirections", () => {
  const commands = tokenizeShellCommands(
    "node --test tests/a.mjs 2>&1 | tee out.log\nnode --test tests/b.mjs && echo done",
  );
  assert.deepEqual(commands, [
    ["node", "--test", "tests/a.mjs"],
    ["tee", "out.log"],
    ["node", "--test", "tests/b.mjs"],
    ["echo", "done"],
  ]);
});
