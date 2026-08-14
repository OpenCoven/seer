import assert from "node:assert/strict";
import test from "node:test";

import {
  CHECK_INTERVAL_MS,
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
  assert.equal(harness.calls[0].url, "https://api.github.com/repos/OpenCoven/seer/releases/latest");
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

  assert.equal(harness.calls[0].url, "https://api.github.com/repos/OpenCoven/seer/releases?per_page=20");
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
  assert.equal(harness.calls[1].url, "https://api.github.com/repos/OpenCoven/seer/releases?per_page=20");
  assert.equal((harness.calls[1].init?.headers as Record<string, string>)["If-None-Match"], undefined);
  assert.equal(state.availableVersion, "v2.0.0-beta.1");
});

test("network failures are typed and retain the last valid state", async () => {
  const harness = makeHarness({ responses: [Response.json(release())] });
  const before = await harness.service.check({ force: true });
  harness.advance(CHECK_INTERVAL_MS);

  await assert.rejects(() => harness.service.check(), { name: "UpdateCheckError" });

  assert.deepEqual(harness.service.getState(), before);
});
