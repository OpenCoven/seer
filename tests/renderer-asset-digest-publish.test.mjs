import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import {
  publishRendererAssetDigestHelperCandidate,
  rendererAssetDigestHelperCandidateRejectionReason,
  verifyRendererAssetDigestHelperCandidateOrNull,
} from "../scripts/renderer-build-identity.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = dirname(here);
const workerPath = join(here, "helpers", "renderer-asset-digest-publish-worker.mjs");

/**
 * A disposable scratch directory under `build/` (already gitignored, and
 * the same convention `tests/renderer-build-identity.test.mjs` uses for its
 * own fixture copies) so these tests never touch the real repository tree
 * or the real digest-helper cache, and always clean up after themselves,
 * pass or fail.
 */
function withScratchDir(run) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-asset-digest-publish-"));
  try {
    return run(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

/** Async counterpart of {@link withScratchDir}: awaits `run` before cleanup. */
async function withAsyncScratchDir(run) {
  mkdirSync(join(repoRoot, "build"), { recursive: true });
  const scratch = mkdtempSync(join(repoRoot, "build", "renderer-asset-digest-publish-"));
  try {
    return await run(scratch);
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

function writeExecutableFile(path, content) {
  writeFileSync(path, content);
  chmodSync(path, 0o755);
}

function uniqueStagingPath(scratch, label) {
  return join(scratch, `.staging-${label}-${randomBytes(6).toString("hex")}`);
}

/**
 * A minimal `fs.Stats`-shaped stand-in for
 * {@link rendererAssetDigestHelperCandidateRejectionReason}'s unit tests.
 * Defaults describe a plausible, accepted candidate; each test overrides
 * exactly the one property it means to violate.
 */
function fakeStats(overrides = {}) {
  return {
    isFile: () => true,
    uid: process.getuid(),
    mode: 0o100755,
    size: 42,
    ...overrides,
  };
}

// --- rendererAssetDigestHelperCandidateRejectionReason: pure predicate ---
//
// "Owned by a different user" is tested here, against a fabricated Stats
// object, rather than against a real on-disk file: actually creating a
// file owned by a different uid would require root/multi-user privileges
// no test environment can assume.

test("rendererAssetDigestHelperCandidateRejectionReason accepts a plausible owned, executable, non-empty regular file", () => {
  assert.equal(rendererAssetDigestHelperCandidateRejectionReason(fakeStats()), null);
});

test("rendererAssetDigestHelperCandidateRejectionReason rejects a non-regular file", () => {
  assert.equal(
    rendererAssetDigestHelperCandidateRejectionReason(fakeStats({ isFile: () => false })),
    "must be a regular file",
  );
});

test("rendererAssetDigestHelperCandidateRejectionReason rejects a file owned by a different user", () => {
  assert.equal(
    rendererAssetDigestHelperCandidateRejectionReason(fakeStats({ uid: process.getuid() + 1 })),
    "is not owned by the current user",
  );
});

test("rendererAssetDigestHelperCandidateRejectionReason rejects a non-executable file", () => {
  assert.equal(
    rendererAssetDigestHelperCandidateRejectionReason(fakeStats({ mode: 0o100644 })),
    "is not executable",
  );
});

test("rendererAssetDigestHelperCandidateRejectionReason rejects an empty file", () => {
  assert.equal(rendererAssetDigestHelperCandidateRejectionReason(fakeStats({ size: 0 })), "is empty");
});

// --- verifyRendererAssetDigestHelperCandidateOrNull: on-disk fixtures ---

test("verifyRendererAssetDigestHelperCandidateOrNull returns null when nothing exists at the path", () => {
  withScratchDir((scratch) => {
    assert.equal(
      verifyRendererAssetDigestHelperCandidateOrNull(join(scratch, "nope"), "test candidate"),
      null,
    );
  });
});

test("verifyRendererAssetDigestHelperCandidateOrNull accepts a plausible regular, owned, executable, non-empty file", () => {
  withScratchDir((scratch) => {
    const candidate = join(scratch, "candidate");
    writeExecutableFile(candidate, "plausible");

    const stats = verifyRendererAssetDigestHelperCandidateOrNull(candidate, "test candidate");
    assert.ok(stats);
    assert.equal(stats.isFile(), true);
  });
});

test("verifyRendererAssetDigestHelperCandidateOrNull rejects a preexisting symlink without following or deleting it", () => {
  withScratchDir((scratch) => {
    const target = join(scratch, "elsewhere");
    writeExecutableFile(target, "elsewhere");
    const candidate = join(scratch, "candidate");
    symlinkSync(target, candidate);

    assert.throws(
      () => verifyRendererAssetDigestHelperCandidateOrNull(candidate, "test candidate"),
      /test candidate must not be a symlink/,
    );

    assert.equal(lstatSync(candidate).isSymbolicLink(), true);
    assert.equal(existsSync(target), true);
  });
});

test("verifyRendererAssetDigestHelperCandidateOrNull rejects a preexisting non-regular entry (a directory)", () => {
  withScratchDir((scratch) => {
    const candidate = join(scratch, "candidate");
    mkdirSync(candidate);

    assert.throws(
      () => verifyRendererAssetDigestHelperCandidateOrNull(candidate, "test candidate"),
      /test candidate must be a regular file/,
    );

    assert.equal(lstatSync(candidate).isDirectory(), true);
  });
});

test("verifyRendererAssetDigestHelperCandidateOrNull rejects a preexisting non-executable regular file", () => {
  withScratchDir((scratch) => {
    const candidate = join(scratch, "candidate");
    writeFileSync(candidate, "not executable");
    chmodSync(candidate, 0o600);

    assert.throws(
      () => verifyRendererAssetDigestHelperCandidateOrNull(candidate, "test candidate"),
      /test candidate is not executable/,
    );

    assert.equal(readFileSync(candidate, "utf8"), "not executable");
  });
});

test("verifyRendererAssetDigestHelperCandidateOrNull rejects a preexisting empty file", () => {
  withScratchDir((scratch) => {
    const candidate = join(scratch, "candidate");
    writeExecutableFile(candidate, "");

    assert.throws(
      () => verifyRendererAssetDigestHelperCandidateOrNull(candidate, "test candidate"),
      /test candidate is empty/,
    );
  });
});

// --- publishRendererAssetDigestHelperCandidate ---

test("publishing valid staging to a fresh canonical path succeeds, and the winner's own staging cleanup never removes the hardlinked canonical file", () => {
  withScratchDir((scratch) => {
    const canonical = join(scratch, "helper");
    const staging = uniqueStagingPath(scratch, "winner");
    writeExecutableFile(staging, "WINNER-CONTENT");

    const published = publishRendererAssetDigestHelperCandidate(staging, canonical);
    assert.ok(published);

    assert.equal(existsSync(staging), false); // this call's own staging is cleaned up ...
    assert.equal(existsSync(canonical), true); // ... but the canonical hardlink survives it.
    assert.equal(readFileSync(canonical, "utf8"), "WINNER-CONTENT");
  });
});

test("a losing publisher resolves the concurrent winner's content, never overwrites or deletes it, and still cleans up its own staging file", () => {
  withScratchDir((scratch) => {
    const canonical = join(scratch, "helper");

    const winnerStaging = uniqueStagingPath(scratch, "winner");
    writeExecutableFile(winnerStaging, "WINNER");
    const winnerResult = publishRendererAssetDigestHelperCandidate(winnerStaging, canonical);

    const loserStaging = uniqueStagingPath(scratch, "loser");
    writeExecutableFile(loserStaging, "LOSER");
    const loserResult = publishRendererAssetDigestHelperCandidate(loserStaging, canonical);

    // Resolves to the exact same winner file - never throws, never its own
    // content - and the loser's own staging is still cleaned up.
    assert.equal(loserResult.ino, winnerResult.ino);
    assert.equal(existsSync(loserStaging), false);
    assert.equal(readFileSync(canonical, "utf8"), "WINNER");
  });
});

test("a preexisting invalid (symlinked) canonical path blocks publication entirely, while the caller's own staging is still cleaned up and the symlink itself is never modified", () => {
  withScratchDir((scratch) => {
    const elsewhere = join(scratch, "elsewhere");
    writeExecutableFile(elsewhere, "elsewhere");
    const canonical = join(scratch, "helper");
    symlinkSync(elsewhere, canonical);

    const staging = uniqueStagingPath(scratch, "attempt");
    writeExecutableFile(staging, "ATTEMPT");

    assert.throws(
      () => publishRendererAssetDigestHelperCandidate(staging, canonical),
      /renderer asset digest helper must not be a symlink/,
    );

    assert.equal(existsSync(staging), false); // own staging still cleaned up ...
    assert.equal(lstatSync(canonical).isSymbolicLink(), true); // ... symlink left untouched.
    assert.equal(existsSync(elsewhere), true);
  });
});

test("a publish attempt whose staging file was never produced (simulated compiler failure) leaves the canonical path untouched and cannot block a later, independent publish", () => {
  withScratchDir((scratch) => {
    const canonical = join(scratch, "helper");
    const neverCreatedStaging = uniqueStagingPath(scratch, "never-created");

    assert.throws(
      () => publishRendererAssetDigestHelperCandidate(neverCreatedStaging, canonical),
      /freshly compiled renderer asset digest helper is missing/,
    );
    assert.equal(existsSync(canonical), false);

    // A completely independent, later attempt is unaffected by the earlier
    // failure - nothing about this design can wedge future publication.
    const staging = uniqueStagingPath(scratch, "recovered");
    writeExecutableFile(staging, "RECOVERED");
    publishRendererAssetDigestHelperCandidate(staging, canonical);
    assert.equal(readFileSync(canonical, "utf8"), "RECOVERED");
  });
});

test("an abandoned unique staging file left by a crashed process (compiled but never published) cannot wedge, and is never touched by, a later independent publish to the same canonical path", () => {
  withScratchDir((scratch) => {
    const canonical = join(scratch, "helper");
    const abandonedStaging = uniqueStagingPath(scratch, "abandoned");
    writeExecutableFile(abandonedStaging, "ABANDONED"); // "crashed" before ever calling publish.

    const staging = uniqueStagingPath(scratch, "fresh");
    writeExecutableFile(staging, "PUBLISHED");
    publishRendererAssetDigestHelperCandidate(staging, canonical);

    assert.equal(readFileSync(canonical, "utf8"), "PUBLISHED");
    // Inert leftover this call never enumerated, waited on, or touched.
    assert.equal(existsSync(abandonedStaging), true);
    assert.equal(readFileSync(abandonedStaging, "utf8"), "ABANDONED");
  });
});

// --- Real concurrent OS processes: the design's core claim, end to end ---

test("many concurrent publishers racing to publish different content resolve to exactly one canonical winner, every participant resolves to it, and no staging artifacts remain", async () => {
  await withAsyncScratchDir(async (scratch) => {
    const canonical = join(scratch, "helper");
    const workerCount = 24;
    const children = Array.from({ length: workerCount }, (_, index) =>
      spawn(process.execPath, [workerPath, canonical, String(index)], {
        cwd: repoRoot,
        stdio: ["ignore", "pipe", "pipe"],
      }),
    );

    const results = await Promise.all(
      children.map(
        (child) =>
          new Promise((finish, reject) => {
            let stdout = "";
            let stderr = "";
            child.stdout.setEncoding("utf8");
            child.stderr.setEncoding("utf8");
            child.stdout.on("data", (chunk) => {
              stdout += chunk;
            });
            child.stderr.on("data", (chunk) => {
              stderr += chunk;
            });
            child.on("error", reject);
            child.on("close", (code) => finish({ code, stdout, stderr }));
          }),
      ),
    );

    for (const result of results) {
      assert.equal(result.code, 0, result.stderr);
    }

    const parsed = results.map((result) => JSON.parse(result.stdout.trim()));
    const actualContent = readFileSync(canonical, "utf8");

    for (const worker of parsed) {
      // Every participant - winner and losers alike - independently
      // resolves to the exact same published content.
      assert.equal(worker.resolvedContent, actualContent);
      assert.equal(worker.stagingRemains, false);
    }

    const winners = parsed.filter((worker) => worker.ownContent === actualContent);
    assert.equal(winners.length, 1, `expected exactly one winner, saw: ${JSON.stringify(parsed)}`);

    // No leftover staging/lock artifacts of any kind: only the published
    // canonical file itself remains in the scratch directory.
    assert.deepEqual(readdirSync(scratch), [basename(canonical)]);
  });
});
