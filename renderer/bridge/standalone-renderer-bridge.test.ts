import assert from "node:assert/strict";
import test from "node:test";

import {
  createStandaloneRendererBridge,
  NativeBridgeRequestError,
  type BridgePort,
  type BridgeScheduler,
} from "./standalone-renderer-bridge";
import { BRIDGE_VERSION, type AppSnapshot } from "./types";

function makeSnapshot(overrides: Partial<AppSnapshot> = {}): AppSnapshot {
  return {
    monitor: {
      active: false,
      keepingAwake: false,
      keepAwakeMode: "system",
      agents: [],
      lastScanAt: 0,
    },
    history: {
      totalAwakeMs: 0,
      todayAwakeMs: 0,
      sessionCount: 0,
      perAgent: [],
      currentSession: null,
      recentSessions: [],
    },
    update: {
      checking: false,
      availableVersion: null,
      releaseURL: null,
      lastCheckedAt: null,
    },
    diagnostics: [],
    appVersion: "1.0.0",
    ...overrides,
  };
}

function createFakePort() {
  const messages: Array<Record<string, unknown>> = [];
  const port: BridgePort = {
    postMessage(message: unknown): void {
      messages.push(message as Record<string, unknown>);
    },
  };
  return { port, messages };
}

function createFakeScheduler() {
  const timers = new Map<number, { handler: () => void; ms: number }>();
  let nextHandle = 1;

  const scheduler: BridgeScheduler = {
    setTimeout(handler: () => void, ms: number): unknown {
      const handle = nextHandle++;
      timers.set(handle, { handler, ms });
      return handle;
    },
    clearTimeout(handle: unknown): void {
      timers.delete(handle as number);
    },
  };

  return {
    scheduler,
    fireAll(): void {
      for (const { handler } of timers.values()) {
        handler();
      }
    },
    get scheduledDurations() {
      return [...timers.values()].map((t) => t.ms);
    },
  };
}

test("getSnapshot posts a request with BRIDGE_VERSION and method snapshot.get, correlates the response", async () => {
  const { port, messages } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const snapshot = makeSnapshot();
  const resultPromise = bridge.getSnapshot();

  assert.equal(messages.length, 1);
  const request = messages[0];
  assert.equal(request.version, BRIDGE_VERSION);
  assert.equal(request.method, "snapshot.get");
  assert.equal(typeof request.id, "string");
  assert.ok((request.id as string).length > 0);

  bridge.receive({
    id: request.id,
    version: BRIDGE_VERSION,
    kind: "response",
    ok: true,
    result: snapshot,
  });

  const result = await resultPromise;
  assert.deepEqual(result, snapshot);
});

test("a native typed error response rejects with NativeBridgeRequestError", async () => {
  const { port, messages } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const resultPromise = bridge.getSnapshot();
  const request = messages[0];

  bridge.receive({
    id: request.id,
    version: BRIDGE_VERSION,
    kind: "response",
    ok: false,
    error: { code: "NOT_READY", message: "Native host not ready" },
  });

  await assert.rejects(resultPromise, (error: unknown) => {
    assert.ok(error instanceof NativeBridgeRequestError);
    assert.equal(error.code, "NOT_READY");
    assert.equal(error.message, "Native host not ready");
    return true;
  });
});

test("unknown and duplicate response ids are ignored", async () => {
  const { port, messages } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const resultPromise = bridge.getSnapshot();
  const request = messages[0];
  const snapshot = makeSnapshot();

  // Unknown id — should be ignored, not throw.
  bridge.receive({
    id: "unknown-id",
    version: BRIDGE_VERSION,
    kind: "response",
    ok: true,
    result: snapshot,
  });

  // Correct id resolves the pending request.
  bridge.receive({
    id: request.id,
    version: BRIDGE_VERSION,
    kind: "response",
    ok: true,
    result: snapshot,
  });

  const result = await resultPromise;
  assert.deepEqual(result, snapshot);

  // Duplicate response for the same (already-resolved) id must be a no-op,
  // not throw or resolve anything twice.
  assert.doesNotThrow(() => {
    bridge.receive({
      id: request.id,
      version: BRIDGE_VERSION,
      kind: "response",
      ok: true,
      result: snapshot,
    });
  });
});

test("requests time out after ten seconds using the injected scheduler", async () => {
  const { port, messages } = createFakePort();
  // Do not destructure `scheduledDurations` early: it's a getter, and
  // destructuring would snapshot its value before any timer is scheduled.
  const fakeScheduler = createFakeScheduler();
  const bridge = createStandaloneRendererBridge(port, fakeScheduler.scheduler);

  const resultPromise = bridge.getSnapshot();
  assert.equal(messages.length, 1);
  assert.deepEqual(fakeScheduler.scheduledDurations, [10_000]);

  fakeScheduler.fireAll();

  await assert.rejects(resultPromise, /timed out/i);
});

test("snapshot.changed events reach subscribers and unsubscribe stops delivery", () => {
  const { port } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const received: AppSnapshot[] = [];
  const unsubscribe = bridge.subscribe((snapshot) => {
    received.push(snapshot);
  });

  const snapshot = makeSnapshot({ appVersion: "2.0.0" });
  bridge.receive({
    version: BRIDGE_VERSION,
    kind: "event",
    type: "snapshot.changed",
    snapshot,
  });

  assert.equal(received.length, 1);
  assert.equal(received[0].appVersion, "2.0.0");

  unsubscribe();

  bridge.receive({
    version: BRIDGE_VERSION,
    kind: "event",
    type: "snapshot.changed",
    snapshot: makeSnapshot({ appVersion: "3.0.0" }),
  });

  assert.equal(received.length, 1);
});
