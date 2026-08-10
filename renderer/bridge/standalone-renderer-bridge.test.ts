import assert from "node:assert/strict";
import test from "node:test";

import {
  createStandaloneRendererBridge,
  NativeBridgeProtocolError,
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

test("every parameterless method posts payload: {} rather than undefined", async () => {
  const cases: Array<{
    method: string;
    invoke: (bridge: ReturnType<typeof createStandaloneRendererBridge>) => Promise<unknown>;
    result: unknown;
  }> = [
    { method: "snapshot.get", invoke: (bridge) => bridge.getSnapshot(), result: makeSnapshot() },
    { method: "history.clear", invoke: (bridge) => bridge.clearHistory(), result: makeSnapshot() },
    {
      method: "updates.check",
      invoke: (bridge) => bridge.requestUpdateCheck(),
      result: makeSnapshot(),
    },
    {
      method: "updates.open",
      invoke: (bridge) => bridge.openCurrentRelease(),
      result: null,
    },
    { method: "app.quit", invoke: (bridge) => bridge.quit(), result: null },
  ];

  for (const { method, invoke, result } of cases) {
    const { port, messages } = createFakePort();
    const bridge = createStandaloneRendererBridge(port);

    const resultPromise = invoke(bridge);
    assert.equal(messages.length, 1, `expected exactly one request for ${method}`);
    const request = messages[0];
    assert.equal(request.method, method);
    assert.deepEqual(request.payload, {}, `expected payload: {} for ${method}`);

    bridge.receive({
      id: request.id,
      version: BRIDGE_VERSION,
      kind: "response",
      ok: true,
      result,
    });

    await resultPromise;
  }
});

test("setKeepAwakeMode posts payload: { mode } exactly", async () => {
  const { port, messages } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const snapshot = makeSnapshot();
  const resultPromise = bridge.setKeepAwakeMode("display");

  assert.equal(messages.length, 1);
  const request = messages[0];
  assert.equal(request.method, "keepAwakeMode.set");
  assert.deepEqual(request.payload, { mode: "display" });

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

test("receive defensively ignores malformed or unknown messages without throwing", () => {
  const { port } = createFakePort();
  const fakeScheduler = createFakeScheduler();
  const bridge = createStandaloneRendererBridge(port, fakeScheduler.scheduler);

  const received: AppSnapshot[] = [];
  bridge.subscribe((snapshot) => {
    received.push(snapshot);
  });

  const resultPromise = bridge.getSnapshot();
  resultPromise.catch(() => {
    // Ignore: this promise is intentionally left unresolved by this test.
  });

  const malformedMessages: unknown[] = [
    null,
    undefined,
    "not an object",
    42,
    {},
    { version: BRIDGE_VERSION }, // missing kind
    { kind: "response", ok: true, id: "x", result: {} }, // wrong/missing version
    { version: BRIDGE_VERSION, kind: "bogus" }, // unknown kind
    { version: BRIDGE_VERSION, kind: "event", type: "bogus.event" }, // unknown event type
    { version: BRIDGE_VERSION, kind: "response", id: "x" }, // missing ok
    { version: BRIDGE_VERSION, kind: "event", type: "snapshot.changed" }, // missing snapshot
  ];

  for (const message of malformedMessages) {
    assert.doesNotThrow(() => bridge.receive(message));
  }

  assert.equal(received.length, 0);
  fakeScheduler.fireAll();
});

function makeFullSnapshot(): AppSnapshot {
  return {
    monitor: {
      active: true,
      keepingAwake: true,
      keepAwakeMode: "display",
      agents: [
        {
          id: "agent-1",
          name: "Agent One",
          detail: "running",
          source: "both",
          pid: 1234,
          cpuPercent: 12.5,
          lastActivityAt: 1000,
        },
        {
          // pid/cpuPercent are optional and may be legitimately absent.
          id: "agent-2",
          name: "Agent Two",
          detail: "idle",
          source: "session",
          lastActivityAt: 2000,
        },
      ],
      lastScanAt: 3000,
    },
    history: {
      totalAwakeMs: 5000,
      todayAwakeMs: 1000,
      sessionCount: 2,
      perAgent: [{ id: "agent-1", name: "Agent One", durationMs: 500 }],
      currentSession: {
        id: "session-1",
        startedAt: 100,
        endedAt: null,
        durationMs: 900,
        mode: "system",
        agents: [{ id: "agent-1", name: "Agent One", durationMs: 900 }],
      },
      recentSessions: [
        {
          id: "session-0",
          startedAt: 0,
          endedAt: 50,
          durationMs: 50,
          mode: "display",
          agents: [],
        },
      ],
    },
    update: {
      checking: false,
      availableVersion: "1.2.3",
      releaseURL: "https://example.com/release",
      lastCheckedAt: 4000,
    },
    diagnostics: [{ id: "diag-1", message: "ok", occurredAt: 10 }],
    appVersion: "1.0.0",
  };
}

test("a valid, fully-populated AppSnapshot (including optional pid/cpuPercent) is still accepted", async () => {
  const { port, messages } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const resultPromise = bridge.getSnapshot();
  const request = messages[0];
  const snapshot = makeFullSnapshot();

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

test("a malformed {} result never resolves an AppSnapshot request; it rejects with NativeBridgeProtocolError", async () => {
  const { port, messages } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const resultPromise = bridge.getSnapshot();
  const request = messages[0];

  bridge.receive({
    id: request.id,
    version: BRIDGE_VERSION,
    kind: "response",
    ok: true,
    result: {},
  });

  await assert.rejects(resultPromise, (error: unknown) => {
    assert.ok(error instanceof NativeBridgeProtocolError);
    return true;
  });
});

test("malformed nested monitor/history/update/diagnostics fields reject the pending request", async () => {
  const invalidSnapshots: Array<{ label: string; snapshot: unknown }> = [
    {
      label: "monitor.agents is not an array",
      snapshot: { ...makeFullSnapshot(), monitor: { ...makeFullSnapshot().monitor, agents: {} } },
    },
    {
      label: "monitor.lastScanAt is NaN",
      snapshot: {
        ...makeFullSnapshot(),
        monitor: { ...makeFullSnapshot().monitor, lastScanAt: Number.NaN },
      },
    },
    {
      label: "history.currentSession is an array instead of object/null",
      snapshot: {
        ...makeFullSnapshot(),
        history: { ...makeFullSnapshot().history, currentSession: [] },
      },
    },
    {
      label: "history.perAgent contains a malformed AgentUsage (missing durationMs)",
      snapshot: {
        ...makeFullSnapshot(),
        history: {
          ...makeFullSnapshot().history,
          perAgent: [{ id: "a", name: "A" }],
        },
      },
    },
    {
      label: "update.lastCheckedAt is Infinity",
      snapshot: {
        ...makeFullSnapshot(),
        update: { ...makeFullSnapshot().update, lastCheckedAt: Number.POSITIVE_INFINITY },
      },
    },
    {
      label: "diagnostics is an object instead of an array",
      snapshot: { ...makeFullSnapshot(), diagnostics: {} },
    },
    {
      label: "diagnostics entry missing message",
      snapshot: { ...makeFullSnapshot(), diagnostics: [{ id: "d1", occurredAt: 1 }] },
    },
  ];

  for (const { label, snapshot } of invalidSnapshots) {
    const { port, messages } = createFakePort();
    const bridge = createStandaloneRendererBridge(port);

    const resultPromise = bridge.getSnapshot();
    const request = messages[0];

    bridge.receive({
      id: request.id,
      version: BRIDGE_VERSION,
      kind: "response",
      ok: true,
      result: snapshot,
    });

    await assert.rejects(
      resultPromise,
      (error: unknown) => error instanceof NativeBridgeProtocolError,
      `expected rejection for: ${label}`,
    );
  }
});

test("invalid enum values (keepAwakeMode, source, mode) reject the pending request", async () => {
  const invalidSnapshots: Array<{ label: string; snapshot: unknown }> = [
    {
      label: "monitor.keepAwakeMode has an unknown value",
      snapshot: {
        ...makeFullSnapshot(),
        monitor: { ...makeFullSnapshot().monitor, keepAwakeMode: "bogus" },
      },
    },
    {
      label: "an agent's source has an unknown value",
      snapshot: {
        ...makeFullSnapshot(),
        monitor: {
          ...makeFullSnapshot().monitor,
          agents: [
            {
              id: "agent-1",
              name: "Agent One",
              detail: "running",
              source: "bogus",
              lastActivityAt: 1,
            },
          ],
        },
      },
    },
    {
      label: "a recent session's mode has an unknown value",
      snapshot: {
        ...makeFullSnapshot(),
        history: {
          ...makeFullSnapshot().history,
          recentSessions: [
            {
              id: "s",
              startedAt: 0,
              endedAt: null,
              durationMs: 0,
              mode: "bogus",
              agents: [],
            },
          ],
        },
      },
    },
  ];

  for (const { label, snapshot } of invalidSnapshots) {
    const { port, messages } = createFakePort();
    const bridge = createStandaloneRendererBridge(port);

    const resultPromise = bridge.getSnapshot();
    const request = messages[0];

    bridge.receive({
      id: request.id,
      version: BRIDGE_VERSION,
      kind: "response",
      ok: true,
      result: snapshot,
    });

    await assert.rejects(
      resultPromise,
      (error: unknown) => error instanceof NativeBridgeProtocolError,
      `expected rejection for: ${label}`,
    );
  }
});

test("invalid optional fields (pid/cpuPercent) reject the pending request", async () => {
  const invalidSnapshots: Array<{ label: string; snapshot: unknown }> = [
    {
      label: "pid is a string instead of a number",
      snapshot: {
        ...makeFullSnapshot(),
        monitor: {
          ...makeFullSnapshot().monitor,
          agents: [
            {
              id: "agent-1",
              name: "Agent One",
              detail: "running",
              source: "process",
              pid: "1234",
              lastActivityAt: 1,
            },
          ],
        },
      },
    },
    {
      label: "cpuPercent is NaN",
      snapshot: {
        ...makeFullSnapshot(),
        monitor: {
          ...makeFullSnapshot().monitor,
          agents: [
            {
              id: "agent-1",
              name: "Agent One",
              detail: "running",
              source: "process",
              cpuPercent: Number.NaN,
              lastActivityAt: 1,
            },
          ],
        },
      },
    },
  ];

  for (const { label, snapshot } of invalidSnapshots) {
    const { port, messages } = createFakePort();
    const bridge = createStandaloneRendererBridge(port);

    const resultPromise = bridge.getSnapshot();
    const request = messages[0];

    bridge.receive({
      id: request.id,
      version: BRIDGE_VERSION,
      kind: "response",
      ok: true,
      result: snapshot,
    });

    await assert.rejects(
      resultPromise,
      (error: unknown) => error instanceof NativeBridgeProtocolError,
      `expected rejection for: ${label}`,
    );
  }
});

test("void methods accept only result: null as success; undefined/absent/object are rejected", async () => {
  const { port: nullPort, messages: nullMessages } = createFakePort();
  const nullBridge = createStandaloneRendererBridge(nullPort);
  const nullResultPromise = nullBridge.quit();
  const nullRequest = nullMessages[0];

  nullBridge.receive({
    id: nullRequest.id,
    version: BRIDGE_VERSION,
    kind: "response",
    ok: true,
    result: null,
  });

  assert.equal(await nullResultPromise, undefined);

  const { port: objPort, messages: objMessages } = createFakePort();
  const objBridge = createStandaloneRendererBridge(objPort);
  const objResultPromise = objBridge.quit();
  const objRequest = objMessages[0];

  objBridge.receive({
    id: objRequest.id,
    version: BRIDGE_VERSION,
    kind: "response",
    ok: true,
    result: {},
  });

  await assert.rejects(
    objResultPromise,
    (error: unknown) => error instanceof NativeBridgeProtocolError,
  );
});

test("a malformed snapshot.changed event is ignored: no subscriber is notified", () => {
  const { port } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const received: AppSnapshot[] = [];
  bridge.subscribe((snapshot) => {
    received.push(snapshot);
  });

  bridge.receive({
    version: BRIDGE_VERSION,
    kind: "event",
    type: "snapshot.changed",
    snapshot: { ...makeFullSnapshot(), monitor: {} },
  });

  bridge.receive({
    version: BRIDGE_VERSION,
    kind: "event",
    type: "snapshot.changed",
    snapshot: { ...makeFullSnapshot(), diagnostics: [{ id: "d1" }] },
  });

  assert.equal(received.length, 0);

  const validSnapshot = makeFullSnapshot();
  bridge.receive({
    version: BRIDGE_VERSION,
    kind: "event",
    type: "snapshot.changed",
    snapshot: validSnapshot,
  });

  assert.equal(received.length, 1);
  assert.deepEqual(received[0], validSnapshot);
});
