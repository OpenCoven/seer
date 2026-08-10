import assert from "node:assert/strict";
import test from "node:test";

import {
  createStandaloneRendererBridge,
  NativeBridgeDisconnectedError,
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
    { method: "panel.hide", invoke: (bridge) => bridge.hidePanel(), result: null },
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

// --- Finding 3: subscribers get independent deep-cloned snapshots, never a shared object. ---

test("each listener receives its own deep-cloned snapshot: mutating listener A's copy cannot affect listener B", () => {
  const { port } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const receivedByA: AppSnapshot[] = [];
  const receivedByB: AppSnapshot[] = [];
  bridge.subscribe((snapshot) => receivedByA.push(snapshot));
  bridge.subscribe((snapshot) => receivedByB.push(snapshot));

  const snapshot = makeFullSnapshot();
  bridge.receive({
    version: BRIDGE_VERSION,
    kind: "event",
    type: "snapshot.changed",
    snapshot,
  });

  assert.equal(receivedByA.length, 1);
  assert.equal(receivedByB.length, 1);

  // Not the same object reference as each other, nor as the original input.
  assert.notEqual(receivedByA[0], receivedByB[0]);
  assert.notEqual(receivedByA[0], snapshot);
  assert.notEqual(receivedByA[0].monitor, receivedByB[0].monitor);
  assert.notEqual(receivedByA[0].monitor.agents, receivedByB[0].monitor.agents);

  // Mutating A's delivered snapshot (including nested arrays/objects) must
  // not be visible to B's copy or to the original input snapshot.
  receivedByA[0].appVersion = "mutated";
  receivedByA[0].monitor.agents.push({
    id: "injected",
    name: "Injected",
    detail: "should not appear elsewhere",
    source: "process",
    lastActivityAt: 0,
  });
  receivedByA[0].history.recentSessions.push({
    id: "injected-session",
    startedAt: 0,
    endedAt: null,
    durationMs: 0,
    mode: "system",
    agents: [],
  });

  assert.equal(receivedByB[0].appVersion, "1.0.0");
  assert.equal(receivedByB[0].monitor.agents.length, snapshot.monitor.agents.length);
  assert.equal(receivedByB[0].history.recentSessions.length, snapshot.history.recentSessions.length);
  assert.equal(snapshot.monitor.agents.length, 2);
  assert.equal(snapshot.history.recentSessions.length, 1);
});

test("a listener mutating its delivered snapshot cannot affect a later notification's snapshot", () => {
  const { port } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const received: AppSnapshot[] = [];
  // Capture the agent count *at delivery time*, before this same listener
  // invocation mutates its own copy — this proves the delivered snapshot
  // was independently cloned from the input, not contaminated by whatever
  // a previous delivery's listener mutation left behind.
  const agentCountsAtDelivery: number[] = [];
  bridge.subscribe((snapshot) => {
    received.push(snapshot);
    agentCountsAtDelivery.push(snapshot.monitor.agents.length);
    snapshot.monitor.agents.push({
      id: "mutated-in-listener",
      name: "x",
      detail: "x",
      source: "process",
      lastActivityAt: 0,
    });
  });

  const firstSnapshot = makeFullSnapshot();
  bridge.receive({
    version: BRIDGE_VERSION,
    kind: "event",
    type: "snapshot.changed",
    snapshot: firstSnapshot,
  });

  const secondSnapshot = makeFullSnapshot();
  bridge.receive({
    version: BRIDGE_VERSION,
    kind: "event",
    type: "snapshot.changed",
    snapshot: secondSnapshot,
  });

  assert.equal(received.length, 2);
  // First delivery starts from the first input's own agent count.
  assert.equal(agentCountsAtDelivery[0], firstSnapshot.monitor.agents.length);
  // Second delivery must reflect the fresh second input's own agent count,
  // not the count left behind by the first delivery's listener mutation.
  assert.equal(agentCountsAtDelivery[1], secondSnapshot.monitor.agents.length);
  // Each delivered snapshot ends up with exactly one listener-added agent.
  assert.equal(received[0].monitor.agents.length, firstSnapshot.monitor.agents.length + 1);
  assert.equal(received[1].monitor.agents.length, secondSnapshot.monitor.agents.length + 1);
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

test("hidePanel posts method panel.hide with exact closed payload {} and resolves only on result: null", async () => {
  const { port, messages } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const resultPromise = bridge.hidePanel();

  assert.equal(messages.length, 1);
  const request = messages[0];
  assert.equal(request.method, "panel.hide");
  assert.deepEqual(request.payload, {});
  assert.deepEqual(Object.keys(request.payload as Record<string, unknown>), []);

  bridge.receive({
    id: request.id,
    version: BRIDGE_VERSION,
    kind: "response",
    ok: true,
    result: null,
  });

  assert.equal(await resultPromise, undefined);
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

// --- Finding 1: disconnect() rejects pending requests; sync postMessage failures don't leak. ---

test("disconnect rejects every pending request with NativeBridgeDisconnectedError and clears their timers", async () => {
  const { port } = createFakePort();
  const fakeScheduler = createFakeScheduler();
  const bridge = createStandaloneRendererBridge(port, fakeScheduler.scheduler);

  const snapshotPromise = bridge.getSnapshot();
  const historyPromise = bridge.clearHistory();

  assert.equal(fakeScheduler.scheduledDurations.length, 2);

  bridge.disconnect();

  await assert.rejects(snapshotPromise, (error: unknown) => {
    assert.ok(error instanceof NativeBridgeDisconnectedError);
    return true;
  });
  await assert.rejects(historyPromise, (error: unknown) => {
    assert.ok(error instanceof NativeBridgeDisconnectedError);
    return true;
  });

  // Both pending timers must have been cleared, not merely abandoned.
  assert.equal(fakeScheduler.scheduledDurations.length, 0);
});

test("disconnect with no pending requests does not throw and still clears listeners", () => {
  const { port } = createFakePort();
  const bridge = createStandaloneRendererBridge(port);

  const received: AppSnapshot[] = [];
  bridge.subscribe((snapshot) => received.push(snapshot));

  assert.doesNotThrow(() => bridge.disconnect());

  bridge.receive({
    version: BRIDGE_VERSION,
    kind: "event",
    type: "snapshot.changed",
    snapshot: makeSnapshot(),
  });
  assert.equal(received.length, 0);
});

test("after disconnect, a late response for a formerly-pending id is ignored rather than throwing", async () => {
  const { port, messages } = createFakePort();
  const fakeScheduler = createFakeScheduler();
  const bridge = createStandaloneRendererBridge(port, fakeScheduler.scheduler);

  const resultPromise = bridge.getSnapshot();
  const request = messages[0];
  resultPromise.catch(() => {
    // Expected: disconnect() rejects this below.
  });

  bridge.disconnect();

  assert.doesNotThrow(() => {
    bridge.receive({
      id: request.id,
      version: BRIDGE_VERSION,
      kind: "response",
      ok: true,
      result: makeSnapshot(),
    });
  });
});

test("a synchronous postMessage throw removes the pending request, clears its timer, and rejects with a protocol error", async () => {
  const sentMessages: Array<Record<string, unknown>> = [];
  const throwingPort: BridgePort = {
    postMessage(message): void {
      sentMessages.push(message as unknown as Record<string, unknown>);
      throw new Error("channel closed");
    },
  };
  const fakeScheduler = createFakeScheduler();
  const bridge = createStandaloneRendererBridge(throwingPort, fakeScheduler.scheduler);

  const resultPromise = bridge.getSnapshot();

  await assert.rejects(resultPromise, (error: unknown) => {
    assert.ok(error instanceof NativeBridgeProtocolError);
    return true;
  });

  // No dangling timer for the failed send.
  assert.equal(fakeScheduler.scheduledDurations.length, 0);

  // The pending entry must have been removed: a late response for that id
  // (if the native host somehow still delivered one) is a no-op, not a
  // second settlement attempt.
  const sentId = sentMessages[0].id as string;
  assert.doesNotThrow(() => {
    bridge.receive({
      id: sentId,
      version: BRIDGE_VERSION,
      kind: "response",
      ok: true,
      result: makeSnapshot(),
    });
  });
});

// --- Finding 2: malformed correlated responses reject immediately instead of timing out. ---

test("a malformed response envelope (missing ok) for a known pending id rejects immediately with NativeBridgeProtocolError", async () => {
  const { port, messages } = createFakePort();
  const fakeScheduler = createFakeScheduler();
  const bridge = createStandaloneRendererBridge(port, fakeScheduler.scheduler);

  const resultPromise = bridge.getSnapshot();
  const request = messages[0];

  bridge.receive({
    id: request.id,
    version: BRIDGE_VERSION,
    kind: "response",
    // `ok` is missing entirely — malformed envelope for a *known* id.
    result: makeSnapshot(),
  });

  await assert.rejects(resultPromise, (error: unknown) => {
    assert.ok(error instanceof NativeBridgeProtocolError);
    return true;
  });

  // Rejected immediately, not via the timeout path — no timer should remain.
  assert.equal(fakeScheduler.scheduledDurations.length, 0);
});

test("a response for a known pending id with the wrong protocol version rejects immediately with NativeBridgeProtocolError", async () => {
  const { port, messages } = createFakePort();
  const fakeScheduler = createFakeScheduler();
  const bridge = createStandaloneRendererBridge(port, fakeScheduler.scheduler);

  const resultPromise = bridge.getSnapshot();
  const request = messages[0];

  bridge.receive({
    id: request.id,
    version: "not-the-real-version",
    kind: "response",
    ok: true,
    result: makeSnapshot(),
  });

  await assert.rejects(resultPromise, (error: unknown) => {
    assert.ok(error instanceof NativeBridgeProtocolError);
    return true;
  });
  assert.equal(fakeScheduler.scheduledDurations.length, 0);
});

test("a malformed error envelope (ok: false but missing error payload) for a known pending id rejects immediately with NativeBridgeProtocolError", async () => {
  const { port, messages } = createFakePort();
  const fakeScheduler = createFakeScheduler();
  const bridge = createStandaloneRendererBridge(port, fakeScheduler.scheduler);

  const resultPromise = bridge.getSnapshot();
  const request = messages[0];

  bridge.receive({
    id: request.id,
    version: BRIDGE_VERSION,
    kind: "response",
    ok: false,
    // `error` is missing entirely.
  });

  await assert.rejects(resultPromise, (error: unknown) => {
    assert.ok(error instanceof NativeBridgeProtocolError);
    return true;
  });
  assert.equal(fakeScheduler.scheduledDurations.length, 0);
});

test("an unknown id with a malformed envelope is still ignored, not treated as a match", () => {
  const { port, messages } = createFakePort();
  const fakeScheduler = createFakeScheduler();
  const bridge = createStandaloneRendererBridge(port, fakeScheduler.scheduler);

  const resultPromise = bridge.getSnapshot();
  resultPromise.catch(() => {
    // Ignore: intentionally left unresolved by this test.
  });
  assert.equal(messages.length, 1);

  assert.doesNotThrow(() => {
    bridge.receive({
      id: "totally-unrelated-id",
      version: BRIDGE_VERSION,
      kind: "response",
      // Malformed: missing `ok`.
    });
  });

  // The real pending request's timer must still be scheduled — it was
  // untouched by the unrelated malformed message.
  assert.equal(fakeScheduler.scheduledDurations.length, 1);
});
