import assert from "node:assert/strict";
import test from "node:test";
import { setImmediate } from "node:timers";

import {
  CHECK_INTERVAL_MS,
  UPDATE_REQUEST_TIMEOUT_MS,
  UpdateService,
  compareSemanticVersions,
  parseSemanticVersion,
  type UpdateSettings,
} from "./update-check";

type FetchCall = { url: string; init?: NonNullable<Parameters<typeof fetch>[1]> };

function release(
  tag = "v1.2.0",
  url = "https://github.com/OpenCoven/seer/releases/tag/v1.2.0",
  draft = false,
  prerelease = false,
) {
  return { tag_name: tag, html_url: url, draft, prerelease };
}

function makeHarness(options: {
  includePrereleaseUpdates?: boolean;
  responses?: Response[];
  currentVersion?: string;
} = {}) {
  let now = 1_700_000_000_000;
  const calls: FetchCall[] = [];
  const responses = [...(options.responses ?? [])];
  const opened: string[] = [];
  const persisted: boolean[] = [];
  let settings: UpdateSettings = {
    includePrereleaseUpdates: options.includePrereleaseUpdates ?? false,
  };
  // Mirrors SettingsStore's transactional contract: the in-memory value is
  // only ever committed once the (simulated) write actually succeeds, so a
  // scripted failure here exercises the same "old value survives a failed
  // persist" guarantee the real store provides.
  let persistError: Error | null = null;

  const service = new UpdateService({
    currentVersion: options.currentVersion ?? "1.0.0",
    now: () => now,
    fetchImpl: async (input, init) => {
      calls.push({ url: String(input), init });
      const response = responses.shift();
      if (!response) throw new Error("no scripted response");
      return response;
    },
    settings: {
      get: () => settings,
      setIncludePrereleaseUpdates: async (value) => {
        persisted.push(value);
        if (persistError) throw persistError;
        settings = { includePrereleaseUpdates: value };
        return settings;
      },
    },
    openExternal: async (url) => {
      opened.push(url);
    },
  });

  return {
    service,
    calls,
    opened,
    persisted,
    advance(milliseconds: number) {
      now += milliseconds;
    },
    failNextPersist(error: Error) {
      persistError = error;
    },
    clearPersistFailure() {
      persistError = null;
    },
  };
}

/// A harness whose `fetchImpl` never resolves on its own — each call's
/// `Response` (or thrown error) is supplied later, explicitly, by the
/// test, in whatever order it chooses. Used to deterministically
/// reproduce two (or more) `check()` calls genuinely overlapping in
/// flight, with full control over which one's network response lands
/// first, second, etc. — something `makeHarness`'s immediately-resolving
/// `fetchImpl` cannot express.
function makeDeferredHarness(options: {
  includePrereleaseUpdates?: boolean;
  suspendPersistence?: boolean;
} = {}) {
  let now = 1_700_000_000_000;
  const calls: FetchCall[] = [];
  const deferred: Array<{ resolve: (response: Response) => void; reject: (error: unknown) => void }> = [];
  const persistence: Array<{
    value: boolean;
    resolve: () => void;
    reject: (error: unknown) => void;
  }> = [];
  let settings: UpdateSettings = {
    includePrereleaseUpdates: options.includePrereleaseUpdates ?? false,
  };

  const service = new UpdateService({
    currentVersion: "1.0.0",
    now: () => now,
    fetchImpl: (input, init) =>
      new Promise<Response>((resolve, reject) => {
        calls.push({ url: String(input), init });
        deferred.push({ resolve, reject });
      }),
    settings: {
      get: () => settings,
      setIncludePrereleaseUpdates: async (value) => {
        if (options.suspendPersistence) {
          await new Promise<void>((resolve, reject) => {
            persistence.push({
              value,
              resolve: () => {
                settings = { includePrereleaseUpdates: value };
                resolve();
              },
              reject,
            });
          });
          return settings;
        }
        settings = { includePrereleaseUpdates: value };
        return settings;
      },
    },
    openExternal: async () => undefined,
  });

  return {
    service,
    calls,
    settings: () => settings,
    setIncludePrerelease(value: boolean) {
      settings = { includePrereleaseUpdates: value };
    },
    resolve(callIndex: number, response: Response) {
      deferred[callIndex]!.resolve(response);
    },
    reject(callIndex: number, error: unknown) {
      deferred[callIndex]!.reject(error);
    },
    persistence,
    resolvePersistence(callIndex: number) {
      persistence[callIndex]!.resolve();
    },
    rejectPersistence(callIndex: number, error: unknown) {
      persistence[callIndex]!.reject(error);
    },
    advance(milliseconds: number) {
      now += milliseconds;
    },
  };
}

test("semantic versions use numeric ordering, prerelease precedence, and optional v", () => {
  assert.equal(compareSemanticVersions(parseSemanticVersion("1.2.9")!, parseSemanticVersion("1.10.0")!), -1);
  assert.equal(compareSemanticVersions(parseSemanticVersion("2.0.0-beta.1")!, parseSemanticVersion("2.0.0")!), -1);
  assert.deepEqual(parseSemanticVersion("v1.2.3"), parseSemanticVersion("1.2.3"));
  for (const malformed of ["1.2", "1.two.3", "1.2.3-", "1.2.3-alpha..1", "01.2.3", "1.2.3+"]) {
    assert.equal(parseSemanticVersion(malformed), null, malformed);
  }
});

test("very large numeric identifiers parse and compare without overflowing Number.MAX_SAFE_INTEGER", () => {
  // One digit longer than `2^63 - 1` (the largest signed 64-bit integer),
  // let alone `Number.MAX_SAFE_INTEGER` (2^53 - 1) — SemVer places no
  // upper bound on a numeric identifier's magnitude, so this must still
  // parse successfully rather than being rejected as malformed.
  const hugeMajor = "123456789012345678901234567890";

  const huge = parseSemanticVersion(`${hugeMajor}.0.0`);
  assert.notEqual(huge, null);
  const ordinary = parseSemanticVersion("999999999.0.0")!;
  assert.equal(compareSemanticVersions(ordinary, huge!), -1);
  assert.equal(compareSemanticVersions(huge!, ordinary), 1);

  // Same leading digits, but one has an extra trailing digit — proves
  // comparison is not truncating/coercing either value through `Number`
  // (which could otherwise misorder or silently equate these).
  const longer = parseSemanticVersion(`${hugeMajor}9.0.0`)!;
  assert.equal(compareSemanticVersions(huge!, longer), -1);

  const hugeAgain = parseSemanticVersion(`${hugeMajor}.0.0`)!;
  assert.equal(compareSemanticVersions(huge!, hugeAgain), 0);
  assert.deepEqual(huge, hugeAgain);

  // A leading zero is still rejected regardless of the identifier's
  // magnitude.
  assert.equal(parseSemanticVersion(`0${hugeMajor}.0.0`), null);

  // Numeric pre-release identifiers get the same overflow-independent
  // treatment, and still always sort before any alphanumeric identifier.
  const smallerPrerelease = parseSemanticVersion("1.0.0-alpha.999999999999999999999")!;
  const largerPrerelease = parseSemanticVersion("1.0.0-alpha.1000000000000000000000")!;
  assert.equal(compareSemanticVersions(smallerPrerelease, largerPrerelease), -1);
  const hugeNumericPrerelease = parseSemanticVersion("1.0.0-123456789012345678901234567890")!;
  const alphanumericPrerelease = parseSemanticVersion("1.0.0-alpha")!;
  assert.equal(compareSemanticVersions(hugeNumericPrerelease, alphanumericPrerelease), -1);
  assert.equal(parseSemanticVersion("1.0.0-0123456789012345678901234567890"), null);

  // A build-metadata identifier that merely *looks* numeric and has a
  // leading zero must still parse — build metadata is opaque and never
  // participates in precedence, so it has no leading-zero restriction at
  // all, unlike the version core/pre-release identifiers above.
  assert.notEqual(parseSemanticVersion(`1.0.0+00${hugeMajor}`), null);
});

test("stable checks latest with a bodyless privacy-bounded request", async () => {
  const harness = makeHarness({
    responses: [
      Response.json(release(), {
        headers: { ETag: '"stable-etag"' },
      }),
    ],
  });

  const state = await harness.service.check({ force: true });

  assert.equal(state.availableVersion, "v1.2.0");
  assert.equal(harness.calls.length, 1);
  assert.equal(harness.calls[0].url, "https://api.github.com/repos/OpenCoven/seer-releases/releases/latest");
  assert.equal(harness.calls[0].init?.method, "GET");
  assert.equal(harness.calls[0].init?.body, undefined);
  assert.deepEqual(harness.calls[0].init?.headers, {
    Accept: "application/vnd.github+json",
    "User-Agent": "Seer/1.0.0",
  });
});

test("prerelease checks a bounded list, ignores drafts, and picks highest semantic version", async () => {
  const harness = makeHarness({
    includePrereleaseUpdates: true,
    responses: [
      Response.json([
        release("v9.0.0", "https://github.com/OpenCoven/seer/releases/tag/v9.0.0", true),
        release("v1.10.0-beta.1", "https://github.com/OpenCoven/seer/releases/tag/v1.10.0-beta.1", false, true),
        release("v1.9.9", "https://github.com/OpenCoven/seer/releases/tag/v1.9.9"),
      ]),
    ],
  });

  const state = await harness.service.check({ force: true });

  assert.equal(harness.calls[0].url, "https://api.github.com/repos/OpenCoven/seer-releases/releases?per_page=20");
  assert.equal(state.availableVersion, "v1.10.0-beta.1");
});

test("checks inside 24 hours use cache unless forced", async () => {
  const harness = makeHarness({
    responses: [Response.json(release()), new Response(null, { status: 304 })],
  });

  await harness.service.check({ force: true });
  harness.advance(CHECK_INTERVAL_MS - 1);
  await harness.service.check();
  assert.equal(harness.calls.length, 1);

  await harness.service.check({ force: true });
  assert.equal(harness.calls.length, 2);
});

test("ETag is conditional and 304 retains the previous release while advancing time", async () => {
  const harness = makeHarness({
    responses: [
      Response.json(release(), { headers: { ETag: '"etag-1"' } }),
      new Response(null, { status: 304 }),
    ],
  });
  const first = await harness.service.check({ force: true });
  harness.advance(CHECK_INTERVAL_MS);

  const second = await harness.service.check();

  assert.deepEqual(second.availableVersion, first.availableVersion);
  assert.deepEqual(second.releaseURL, first.releaseURL);
  assert.equal(second.lastCheckedAt, first.lastCheckedAt! + CHECK_INTERVAL_MS);
  assert.deepEqual(harness.calls[1].init?.headers, {
    Accept: "application/vnd.github+json",
    "User-Agent": "Seer/1.0.0",
    "If-None-Match": '"etag-1"',
  });
});

test("only HTTPS github.com release URLs are retained and an invalid higher release cannot hide a valid one", async () => {
  const harness = makeHarness({
    includePrereleaseUpdates: true,
    responses: [
      Response.json([
        release("v3.0.0", "https://github.com.evil.example/releases/tag/v3.0.0"),
        release("v2.0.0", "http://github.com/OpenCoven/seer/releases/tag/v2.0.0"),
        release("v1.5.0", "https://github.com/OpenCoven/seer/releases/tag/v1.5.0"),
      ]),
    ],
  });

  const state = await harness.service.check({ force: true });

  assert.equal(state.availableVersion, "v1.5.0");
  assert.equal(state.releaseURL, "https://github.com/OpenCoven/seer/releases/tag/v1.5.0");
});

test("openCurrentRelease accepts no URL and opens only the service-held validated release", async () => {
  const harness = makeHarness({ responses: [Response.json(release())] });
  await harness.service.check({ force: true });

  await harness.service.openCurrentRelease();

  assert.deepEqual(harness.opened, ["https://github.com/OpenCoven/seer/releases/tag/v1.2.0"]);
});

test("toggling prereleases persists, clears stream cache, and forces one check", async () => {
  const harness = makeHarness({
    responses: [
      Response.json(release(), { headers: { ETag: '"stable"' } }),
      Response.json([
        release("v2.0.0-beta.1", "https://github.com/OpenCoven/seer/releases/tag/v2.0.0-beta.1", false, true),
      ]),
    ],
  });
  await harness.service.check({ force: true });

  const state = await harness.service.setIncludePrereleaseUpdates(true);

  assert.deepEqual(harness.persisted, [true]);
  assert.equal(harness.calls.length, 2);
  assert.equal(harness.calls[1].url, "https://api.github.com/repos/OpenCoven/seer-releases/releases?per_page=20");
  assert.equal((harness.calls[1].init?.headers as Record<string, string>)["If-None-Match"], undefined);
  assert.equal(state.availableVersion, "v2.0.0-beta.1");
});

test("a failed settings persistence restores stream state without starting a new check, and a later successful toggle still works", async () => {
  const harness = makeHarness({
    responses: [
      Response.json(release(), { headers: { ETag: '"stable"' } }),
      Response.json([
        release("v2.0.0-beta.1", "https://github.com/OpenCoven/seer/releases/tag/v2.0.0-beta.1", false, true),
      ]),
    ],
  });
  const before = await harness.service.check({ force: true });
  assert.equal(harness.calls.length, 1);

  harness.failNextPersist(new Error("disk full"));
  await assert.rejects(() => harness.service.setIncludePrereleaseUpdates(true), /disk full/);

  // The (simulated) SettingsStore never committed the new value, so the
  // service must keep reporting the old setting rather than a half-applied
  // toggle.
  assert.equal(harness.service.includesPrereleaseUpdates(), false);
  // A failed persist must never itself kick off a new check.
  assert.equal(harness.calls.length, 1);
  // The old stable state remains coherent with the setting that survived the
  // failed write, and its stream ETag is available to later stable checks.
  assert.deepEqual(harness.service.getState(), before);

  harness.clearPersistFailure();
  const state = await harness.service.setIncludePrereleaseUpdates(true);
  assert.equal(harness.service.includesPrereleaseUpdates(), true);
  assert.equal(harness.calls.length, 2);
  assert.equal(state.availableVersion, "v2.0.0-beta.1");
});

test("a check started during suspended persistence cannot fetch the old stream or revive it after the forced new-stream check fails", async () => {
  const harness = makeDeferredHarness({ suspendPersistence: true });

  const oldStableCheck = harness.service.check({ force: true });
  assert.equal(harness.calls.length, 1);

  const toggle = harness.service.setIncludePrereleaseUpdates(true);
  assert.equal(harness.persistence.length, 1, "the transition marker must be installed before persistence suspends");

  const duringTransition = await harness.service.check({ force: true });
  assert.equal(harness.calls.length, 1, "an external check must not fetch the old stream during persistence");
  assert.deepEqual(duringTransition, {
    checking: false,
    availableVersion: null,
    releaseURL: null,
    lastCheckedAt: null,
  });

  harness.resolvePersistence(0);
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(harness.settings().includePrereleaseUpdates, true);
  assert.equal(harness.calls.length, 2, "successful persistence must force exactly one new-stream check");
  assert.match(harness.calls[1]!.url, /releases\?per_page=20$/);
  harness.reject(1, new Error("prerelease feed unavailable"));
  await assert.rejects(() => toggle, /prerelease feed unavailable/);

  harness.resolve(
    0,
    Response.json(release("v1.2.0"), { headers: { ETag: '"stable-must-not-survive"' } }),
  );
  await oldStableCheck;

  assert.equal(harness.settings().includePrereleaseUpdates, true);
  assert.deepEqual(harness.service.getState(), {
    checking: false,
    availableVersion: null,
    releaseURL: null,
    lastCheckedAt: null,
  });

  const recovery = harness.service.check({ force: true });
  assert.equal(harness.calls.length, 3);
  assert.match(harness.calls[2]!.url, /releases\?per_page=20$/);
  assert.equal(
    (harness.calls[2]!.init?.headers as Record<string, string>)["If-None-Match"],
    undefined,
    "neither the stale stable ETag nor a failed prerelease request may survive",
  );
  harness.resolve(
    2,
    Response.json([
      release("v2.0.0-beta.2", "https://github.com/OpenCoven/seer/releases/tag/v2.0.0-beta.2", false, true),
    ]),
  );
  assert.equal((await recovery).availableVersion, "v2.0.0-beta.2");
});

test("a failed suspended persistence restores the prior coherent stream and permits recovery checks", async () => {
  const harness = makeDeferredHarness({ suspendPersistence: true });
  const initial = harness.service.check({ force: true });
  harness.resolve(
    0,
    Response.json(release("v1.2.0"), { headers: { ETag: '"stable-restored"' } }),
  );
  const priorState = await initial;

  const toggle = harness.service.setIncludePrereleaseUpdates(true);
  assert.deepEqual(harness.service.getState(), {
    checking: false,
    availableVersion: null,
    releaseURL: null,
    lastCheckedAt: null,
  });
  harness.rejectPersistence(0, new Error("disk full"));
  await assert.rejects(() => toggle, /disk full/);

  assert.equal(harness.settings().includePrereleaseUpdates, false);
  assert.deepEqual(harness.service.getState(), priorState);

  const recovery = harness.service.check({ force: true });
  assert.equal(harness.calls.length, 2);
  assert.match(harness.calls[1]!.url, /releases\/latest$/);
  assert.equal(
    (harness.calls[1]!.init?.headers as Record<string, string>)["If-None-Match"],
    '"stable-restored"',
  );
  harness.resolve(1, new Response(null, { status: 304 }));
  await recovery;
});

test("a scheduled check that fires during stream persistence is retried later without fetching the old stream", async () => {
  const harness = makeDeferredHarness({ suspendPersistence: true });
  const originalSetTimeout = globalThis.setTimeout;
  const originalClearTimeout = globalThis.clearTimeout;
  let scheduled: (() => void) | null = null;
  globalThis.setTimeout = ((callback: (...args: never[]) => void) => {
    scheduled = callback;
    return { unref() {} } as ReturnType<typeof setTimeout>;
  }) as typeof setTimeout;
  globalThis.clearTimeout = (() => undefined) as typeof clearTimeout;

  try {
    const started = harness.service.start();
    harness.resolve(0, Response.json(release("v1.2.0")));
    await started;
    assert.ok(scheduled);

    const toggle = harness.service.setIncludePrereleaseUpdates(true);
    const fired = scheduled as () => void;
    fired();
    await Promise.resolve();
    assert.equal(harness.calls.length, 1, "the scheduled callback must not fetch while persistence is active");

    harness.resolvePersistence(0);
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.equal(harness.calls.length, 2);
    harness.resolve(1, Response.json([]));
    await toggle;
    await Promise.resolve();

    assert.ok(scheduled, "the scheduler must remain armed after the skipped transition-time check");
  } finally {
    harness.service.stop();
    globalThis.setTimeout = originalSetTimeout;
    globalThis.clearTimeout = originalClearTimeout;
  }
});

test("network failures are typed and retain the last valid state", async () => {
  const harness = makeHarness({ responses: [Response.json(release())] });
  const before = await harness.service.check({ force: true });
  harness.advance(CHECK_INTERVAL_MS);

  await assert.rejects(() => harness.service.check(), { name: "UpdateCheckError" });

  assert.deepEqual(harness.service.getState(), before);
});

test("a stale in-flight stable check cannot regress state after a newer prerelease check has already completed", async () => {
  const harness = makeDeferredHarness();

  // Call A starts while stable checks are selected...
  const stableCheck = harness.service.check({ force: true });
  assert.equal(harness.calls.length, 1);
  assert.equal(harness.calls[0]!.url, "https://api.github.com/repos/OpenCoven/seer-releases/releases/latest");

  // ...then, before call A's request resolves, prereleases are enabled
  // and a second, genuinely newer call B starts (mirroring, e.g., a slow
  // startup check racing a user toggling the setting mid-flight).
  harness.setIncludePrerelease(true);
  const prereleaseCheck = harness.service.check({ force: true });
  assert.equal(harness.calls.length, 2);
  assert.equal(harness.calls[1]!.url, "https://api.github.com/repos/OpenCoven/seer-releases/releases?per_page=20");

  // Call B (the newer one) completes first...
  harness.resolve(
    1,
    Response.json(
      [release("v2.0.0-beta.1", "https://github.com/OpenCoven/seer/releases/tag/v2.0.0-beta.1", false, true)],
      { headers: { ETag: '"prerelease-etag"' } },
    ),
  );
  const prereleaseState = await prereleaseCheck;
  assert.equal(prereleaseState.availableVersion, "v2.0.0-beta.1");

  // ...and only afterward does call A's now-stale stable response land.
  // It must never be allowed to overwrite call B's newer result.
  harness.resolve(0, Response.json(release("v1.2.0"), { headers: { ETag: '"stable-etag"' } }));
  const staleStableState = await stableCheck;

  assert.equal(staleStableState.availableVersion, "v2.0.0-beta.1", "the stale call's own return value must reflect the current (newer) state, not its own stale result");
  const finalState = harness.service.getState();
  assert.equal(finalState.availableVersion, "v2.0.0-beta.1", "a stale completion must never regress the already-published newer state");
  assert.equal(finalState.checking, false, "a stale completion's finally block must not flip `checking` back off on a still-current call's behalf");

  // The stale stable completion must also not have clobbered the
  // *prerelease* stream's own ETag with the stable stream's ETag: the
  // very next prerelease check must still send the prerelease ETag.
  harness.advance(CHECK_INTERVAL_MS);
  const nextPrereleaseCheck = harness.service.check({ force: true });
  assert.equal(harness.calls.length, 3);
  assert.equal(
    (harness.calls[2]!.init?.headers as Record<string, string>)["If-None-Match"],
    '"prerelease-etag"',
    "the prerelease stream's own ETag must survive an unrelated stale stable completion",
  );
  harness.resolve(2, new Response(null, { status: 304 }));
  await nextPrereleaseCheck;
});

test("prerelease requests never send the stable stream's ETag, and vice versa", async () => {
  const harness = makeDeferredHarness();

  const stableCheck = harness.service.check({ force: true });
  assert.equal((harness.calls[0]!.init?.headers as Record<string, string>)["If-None-Match"], undefined);
  harness.resolve(0, Response.json(release("v1.2.0"), { headers: { ETag: '"stable-etag"' } }));
  await stableCheck;

  // Switching streams (without going through `setIncludePrereleaseUpdates`,
  // which would itself clear the cache) must never send the stable
  // stream's freshly-cached ETag on the prerelease stream's first-ever
  // request — the two streams' caches are entirely independent.
  harness.setIncludePrerelease(true);
  harness.advance(CHECK_INTERVAL_MS);
  const prereleaseCheck = harness.service.check({ force: true });
  assert.equal(
    (harness.calls[1]!.init?.headers as Record<string, string>)["If-None-Match"],
    undefined,
    "the prerelease stream must never send the stable stream's cached ETag",
  );
  harness.resolve(
    1,
    Response.json(
      [release("v1.5.0-beta.1", "https://github.com/OpenCoven/seer/releases/tag/v1.5.0-beta.1", false, true)],
      { headers: { ETag: '"prerelease-etag"' } },
    ),
  );
  await prereleaseCheck;

  // Switching back to stable must likewise still send the *stable*
  // stream's own previously-cached ETag, not the prerelease one.
  harness.setIncludePrerelease(false);
  harness.advance(CHECK_INTERVAL_MS);
  const secondStableCheck = harness.service.check({ force: true });
  assert.equal(
    (harness.calls[2]!.init?.headers as Record<string, string>)["If-None-Match"],
    '"stable-etag"',
    "switching back to stable must reuse the stable stream's own cached ETag",
  );
  harness.resolve(2, new Response(null, { status: 304 }));
  await secondStableCheck;
});

test("each update request is bounded by a 10 second timeout via an injectable, abortable signal", async () => {
  const now = 1_700_000_000_000;
  const observedTimeouts: number[] = [];
  const controller = new AbortController();

  const service = new UpdateService({
    currentVersion: "1.0.0",
    now: () => now,
    fetchImpl: (_input, init) =>
      new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          reject(new DOMException("The operation was aborted.", "AbortError"));
        });
      }),
    createTimeoutSignal: (timeoutMs) => {
      observedTimeouts.push(timeoutMs);
      return controller.signal;
    },
    settings: {
      get: () => ({ includePrereleaseUpdates: false }),
      setIncludePrereleaseUpdates: async (value) => ({ includePrereleaseUpdates: value }),
    },
    openExternal: async () => undefined,
  });

  const pending = service.check({ force: true });
  controller.abort();

  await assert.rejects(() => pending, { name: "UpdateCheckError" });
  assert.deepEqual(observedTimeouts, [UPDATE_REQUEST_TIMEOUT_MS]);
  assert.equal(UPDATE_REQUEST_TIMEOUT_MS, 10_000);
});
