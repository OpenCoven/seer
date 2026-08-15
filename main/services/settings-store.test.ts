import assert from "node:assert/strict";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import test from "node:test";

import { SettingsStore } from "./settings-store.js";

// A repo-local (gitignored, per `tmp/` in `.gitignore`) scratch root — never
// `/tmp` — so each test gets its own isolated settings directory instead of
// touching the real Electron `userData` path (which would pollute whatever
// real Seer install happens to be on the machine running these tests).
const scratchRoot = path.join(process.cwd(), "tmp", "settings-store-tests");
let scratchCounter = 0;

async function makeStore(): Promise<{ store: SettingsStore; dir: string }> {
  const { store, dir } = await makeColdStore();
  await store.load();
  return { store, dir };
}

// Like `makeStore`, but deliberately does NOT call `store.load()` first —
// the store's cache is left cold so callers can exercise concurrent
// setters racing the very first (uncompleted) read.
async function makeColdStore(): Promise<{ store: SettingsStore; dir: string }> {
  scratchCounter += 1;
  const dir = path.join(
    scratchRoot,
    `case-${scratchCounter}-${process.hrtime.bigint()}`,
  );
  await fs.mkdir(dir, { recursive: true });
  const store = new SettingsStore(() => dir);
  return { store, dir };
}

async function readOnDisk(dir: string): Promise<unknown> {
  return JSON.parse(
    await fs.readFile(path.join(dir, "settings.json"), "utf-8"),
  );
}

test.after(async () => {
  await fs.rm(scratchRoot, { recursive: true, force: true });
});

// Regression test for setters deriving `next` from `this.cache` *before*
// entering `saveQueue`: two concurrent setters (`setKeepAwakeMode`/
// `setIncludePrereleaseUpdates`) would each read the same stale cache
// snapshot, so whichever call's transform ran last inside the queue would
// silently overwrite the other's change — the queue serialized *disk
// writes*, but not the read-derive step that decided what to write. The
// fix serializes the entire read-current -> derive-next -> persist ->
// cache-commit transaction as a single job inside `saveQueue`, so each
// job always reads the *latest* committed cache, not a snapshot captured
// at call time.
//
// Two concurrent calls are queued strictly in call order (each is
// synchronously chained onto `saveQueue` before either's actual write
// begins), so the *first*-called setter's own resolved value only ever
// reflects its own change (the second hasn't run yet at that point) —
// that's ordinary FIFO-queue behavior, not a bug. The *second*-called
// setter, however, is queued behind the first and only runs after the
// first has both persisted and committed, so its resolved value (and the
// store's final state once both have settled) must reflect BOTH changes.
test("racing setKeepAwakeMode and setIncludePrereleaseUpdates: the later-queued call sees both changes, and neither is lost from the final state", async () => {
  const { store, dir } = await makeStore();

  const [afterKeepAwake, afterPrerelease] = await Promise.all([
    store.setKeepAwakeMode("display"),
    store.setIncludePrereleaseUpdates(true),
  ]);

  // First-queued: only its own change has landed yet.
  assert.deepEqual(afterKeepAwake, {
    keepAwakeMode: "display",
    includePrereleaseUpdates: false,
  });
  // Second-queued: must see the first's already-committed change too —
  // this is what the buggy implementation got wrong (it derived `next`
  // from the stale pre-race cache instead of the first call's result).
  assert.deepEqual(afterPrerelease, {
    keepAwakeMode: "display",
    includePrereleaseUpdates: true,
  });

  // Neither change was lost from the final state: survives in memory...
  assert.deepEqual(store.get(), {
    keepAwakeMode: "display",
    includePrereleaseUpdates: true,
  });

  // ...and durably on disk.
  assert.deepEqual(await readOnDisk(dir), {
    keepAwakeMode: "display",
    includePrereleaseUpdates: true,
  });
});

// The same race, but with the call order reversed, to rule out the fix
// only happening to work for one particular interleaving.
test("racing setIncludePrereleaseUpdates and setKeepAwakeMode (reversed call order): the later-queued call sees both changes", async () => {
  const { store, dir } = await makeStore();

  const [afterPrerelease, afterKeepAwake] = await Promise.all([
    store.setIncludePrereleaseUpdates(true),
    store.setKeepAwakeMode("display"),
  ]);

  // First-queued: only its own change has landed yet.
  assert.deepEqual(afterPrerelease, {
    keepAwakeMode: "system",
    includePrereleaseUpdates: true,
  });
  // Second-queued: must see the first's already-committed change too.
  assert.deepEqual(afterKeepAwake, {
    keepAwakeMode: "display",
    includePrereleaseUpdates: true,
  });

  assert.deepEqual(store.get(), {
    keepAwakeMode: "display",
    includePrereleaseUpdates: true,
  });
  assert.deepEqual(await readOnDisk(dir), {
    keepAwakeMode: "display",
    includePrereleaseUpdates: true,
  });
});

// A third setter racing the first two, to prove the fix generalizes past
// exactly two concurrent callers: each of the three calls is chained onto
// `saveQueue` strictly in call order, so the final state is exactly what
// applying all three transforms in that order would produce — the
// `includePrereleaseUpdates: true` change from the *middle* call must
// still be present even though the *last* call only ever touches
// `keepAwakeMode`.
test("three racing setters (two keepAwakeMode changes and one includePrereleaseUpdates change) apply in call order with none lost", async () => {
  const { store, dir } = await makeStore();

  const results = await Promise.all([
    store.setKeepAwakeMode("display"),
    store.setIncludePrereleaseUpdates(true),
    store.setKeepAwakeMode("system"),
  ]);

  assert.deepEqual(results[0], {
    keepAwakeMode: "display",
    includePrereleaseUpdates: false,
  });
  assert.deepEqual(results[1], {
    keepAwakeMode: "display",
    includePrereleaseUpdates: true,
  });
  // The third (last-queued) call only sets `keepAwakeMode` back to
  // "system", but must still carry forward the second call's
  // `includePrereleaseUpdates: true` — proving the middle call's change
  // was not lost underneath the third.
  assert.deepEqual(results[2], {
    keepAwakeMode: "system",
    includePrereleaseUpdates: true,
  });

  const final = {
    keepAwakeMode: "system" as const,
    includePrereleaseUpdates: true,
  };
  assert.deepEqual(store.get(), final);
  assert.deepEqual(await readOnDisk(dir), final);
});

// Regression test for a failed persist poisoning `saveQueue`: because the
// previous implementation still recovered from the rejection (`.catch(()
// => undefined)`), it happened not to poison the queue either — but the
// fix's whole read-derive-persist-commit job must preserve that same
// contract while ALSO fixing the lost-update race above, so this asserts
// it explicitly. A failed persist must (1) reject only its own caller,
// (2) leave the in-memory cache exactly as it was before the call
// (transactional failure semantics), and (3) leave `saveQueue` usable for
// every subsequent call.
test("a failed persist rejects only its own caller, leaves cache unchanged, and does not poison later writes", async () => {
  const { store, dir } = await makeStore();

  const baseline = await store.setKeepAwakeMode("display");
  assert.deepEqual(baseline, {
    keepAwakeMode: "display",
    includePrereleaseUpdates: false,
  });

  // Strip write permission from the settings directory so the next
  // persist's temp-file write fails.
  await fs.chmod(dir, 0o500);
  try {
    await assert.rejects(() => store.setIncludePrereleaseUpdates(true));

    // The failed persist must never have committed `next` to the cache —
    // still exactly the pre-call baseline.
    assert.deepEqual(store.get(), {
      keepAwakeMode: "display",
      includePrereleaseUpdates: false,
    });
  } finally {
    // Restore write access for the assertions/cleanup below regardless of
    // whether the rejection assertion itself passed.
    await fs.chmod(dir, 0o700);
  }

  // A later, unrelated call must still succeed — the one failure above
  // must not have left `saveQueue` permanently rejected.
  const recovered = await store.setKeepAwakeMode("system");
  assert.deepEqual(recovered, {
    keepAwakeMode: "system",
    includePrereleaseUpdates: false,
  });
  assert.deepEqual(store.get(), {
    keepAwakeMode: "system",
    includePrereleaseUpdates: false,
  });
  assert.deepEqual(await readOnDisk(dir), {
    keepAwakeMode: "system",
    includePrereleaseUpdates: false,
  });
});

// A second failure immediately after the first, still with no successful
// write in between, must behave identically — the queue's recovery isn't
// a one-shot fluke tied to exactly one prior rejection.
test("consecutive failed persists each reject independently without poisoning the queue for the eventual recovery", async () => {
  const { store, dir } = await makeStore();

  await fs.chmod(dir, 0o500);
  await assert.rejects(() => store.setKeepAwakeMode("display"));
  await assert.rejects(() => store.setIncludePrereleaseUpdates(true));
  assert.deepEqual(store.get(), {
    keepAwakeMode: "system",
    includePrereleaseUpdates: false,
  });

  await fs.chmod(dir, 0o700);
  const recovered = await store.setKeepAwakeMode("display");
  assert.deepEqual(recovered, {
    keepAwakeMode: "display",
    includePrereleaseUpdates: false,
  });
  assert.deepEqual(await readOnDisk(dir), {
    keepAwakeMode: "display",
    includePrereleaseUpdates: false,
  });
});

// Regression tests for `mutate()` calling `load()` *before* joining
// `saveQueue`: with a cold (never-loaded) cache, every concurrent setter
// call independently sees `this.loaded === false`, so each one performs
// its own `load()` work and joins `saveQueue` only once that settles —
// whichever call's `load()` happens to resolve last decides both the
// join order (regardless of actual call order) and the cache contents
// (resetting `this.cache` to whatever it just read from disk, even after
// another call has already derived-and-persisted a newer value on top of
// it). The fix must make initialization a single shared/serialized
// operation and fix each caller's queue position *before* any `await` —
// including before `load()` — so cold-start races behave identically to
// already-warm races.
test("cold start: two different-field setters both survive with no prior load() call", async () => {
  const { store, dir } = await makeColdStore();

  const [afterKeepAwake, afterPrerelease] = await Promise.all([
    store.setKeepAwakeMode("display"),
    store.setIncludePrereleaseUpdates(true),
  ]);

  assert.deepEqual(afterKeepAwake, {
    keepAwakeMode: "display",
    includePrereleaseUpdates: false,
  });
  assert.deepEqual(afterPrerelease, {
    keepAwakeMode: "display",
    includePrereleaseUpdates: true,
  });
  assert.deepEqual(store.get(), {
    keepAwakeMode: "display",
    includePrereleaseUpdates: true,
  });
  assert.deepEqual(await readOnDisk(dir), {
    keepAwakeMode: "display",
    includePrereleaseUpdates: true,
  });
});

test("cold start: same-field setter calls preserve invocation order — the last invocation wins", async () => {
  const { store, dir } = await makeColdStore();

  // All three race the same cold cache. Under the bug, whichever call's
  // own independent `load()` resolves last wins — an ordering unrelated
  // to which `setKeepAwakeMode` call was actually invoked last. The fix
  // must make the *third* call ("system") win, because it was invoked
  // last, regardless of read timing.
  const results = await Promise.all([
    store.setKeepAwakeMode("display"),
    store.setKeepAwakeMode("system"),
    store.setKeepAwakeMode("display"),
  ]);

  assert.deepEqual(results[2], {
    keepAwakeMode: "display",
    includePrereleaseUpdates: false,
  });
  assert.deepEqual(store.get(), {
    keepAwakeMode: "display",
    includePrereleaseUpdates: false,
  });
  assert.deepEqual(await readOnDisk(dir), {
    keepAwakeMode: "display",
    includePrereleaseUpdates: false,
  });
});

test("cold start: a delayed initial filesystem read cannot reorder mutations, and only ever happens once", async () => {
  scratchCounter += 1;
  const dir = path.join(
    scratchRoot,
    `case-${scratchCounter}-${process.hrtime.bigint()}`,
  );
  await fs.mkdir(dir, { recursive: true });

  // Seed real on-disk content so a read actually has stale data it could
  // wrongly reassert if the fix let a second, later-resolving read reset
  // `this.cache` after a setter already persisted a newer value on top
  // of it.
  await fs.writeFile(
    path.join(dir, "settings.json"),
    JSON.stringify({
      keepAwakeMode: "display",
      includePrereleaseUpdates: false,
    }),
    "utf-8",
  );

  let readCalls = 0;
  // Injected read seam (rather than patching the global `fs` module,
  // which tsx/esbuild's per-file ESM transpilation does not reliably
  // let a test module intercept) that counts calls and delays every
  // read, so any setter racing the very first (still-unresolved) read
  // would, under the bug, have already kicked off its own independent
  // read attempt by the time this one finally completes.
  const store = new SettingsStore(
    () => dir,
    async (filePath) => {
      readCalls += 1;
      await new Promise((resolve) => setTimeout(resolve, 30));
      return fs.readFile(filePath, "utf-8");
    },
  );

  const [afterKeepAwake, afterPrerelease] = await Promise.all([
    store.setKeepAwakeMode("system"),
    store.setIncludePrereleaseUpdates(true),
  ]);

  assert.deepEqual(afterKeepAwake, {
    keepAwakeMode: "system",
    includePrereleaseUpdates: false,
  });
  assert.deepEqual(afterPrerelease, {
    keepAwakeMode: "system",
    includePrereleaseUpdates: true,
  });
  assert.deepEqual(store.get(), {
    keepAwakeMode: "system",
    includePrereleaseUpdates: true,
  });
  assert.deepEqual(await readOnDisk(dir), {
    keepAwakeMode: "system",
    includePrereleaseUpdates: true,
  });
  // Exactly one on-disk read for both concurrent cold-start callers —
  // proof initialization was coalesced into a single shared operation
  // rather than each caller performing its own independent read.
  assert.equal(readCalls, 1);
});

test("cold start: a failed initial read does not permanently poison later loads or writes", async () => {
  const { store, dir } = await makeColdStore();

  // A directory in place of the settings file makes `fs.readFile` fail
  // with `EISDIR` — a genuine (non-ENOENT) read failure, distinct from
  // the ordinary missing-file case that legitimately falls back to
  // defaults.
  const settingsPath = path.join(dir, "settings.json");
  await fs.mkdir(settingsPath);

  await assert.rejects(() => store.load());
  await assert.rejects(() => store.setKeepAwakeMode("display"));

  // Clear the obstruction and confirm the store recovers fully — the
  // earlier failures must not have left it wedged behind a poisoned
  // shared load operation or a permanently rejected save queue.
  await fs.rmdir(settingsPath);

  const loaded = await store.load();
  assert.deepEqual(loaded, {
    keepAwakeMode: "system",
    includePrereleaseUpdates: false,
  });

  const recovered = await store.setIncludePrereleaseUpdates(true);
  assert.deepEqual(recovered, {
    keepAwakeMode: "system",
    includePrereleaseUpdates: true,
  });
  assert.deepEqual(await readOnDisk(dir), {
    keepAwakeMode: "system",
    includePrereleaseUpdates: true,
  });
});

test("cold start: concurrent calls racing a failing initial read each reject without poisoning later recovery", async () => {
  const { store, dir } = await makeColdStore();

  const settingsPath = path.join(dir, "settings.json");
  await fs.mkdir(settingsPath);

  // Both calls race the same cold, failing initial read.
  await Promise.all([
    assert.rejects(() => store.setKeepAwakeMode("display")),
    assert.rejects(() => store.setIncludePrereleaseUpdates(true)),
  ]);

  await fs.rmdir(settingsPath);

  const recovered = await store.setKeepAwakeMode("display");
  assert.deepEqual(recovered, {
    keepAwakeMode: "display",
    includePrereleaseUpdates: false,
  });
  assert.deepEqual(await readOnDisk(dir), {
    keepAwakeMode: "display",
    includePrereleaseUpdates: false,
  });
});
