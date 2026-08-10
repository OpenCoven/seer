import assert from "node:assert/strict";
import process from "node:process";
import test from "node:test";

import { createGlazeRendererBridge, type GlazeIpcFacade } from "./glaze-renderer-bridge";
import type { AgentMonitorState, HistoryStats } from "./types";

function makeMonitor(overrides: Partial<AgentMonitorState> = {}): AgentMonitorState {
  return {
    active: false,
    keepingAwake: false,
    keepAwakeMode: "system",
    agents: [],
    lastScanAt: 0,
    ...overrides,
  };
}

function makeHistory(overrides: Partial<HistoryStats> = {}): HistoryStats {
  return {
    totalAwakeMs: 0,
    todayAwakeMs: 0,
    sessionCount: 0,
    perAgent: [],
    currentSession: null,
    recentSessions: [],
    ...overrides,
  };
}

type FakeIpcOptions = {
  monitor?: AgentMonitorState;
  history?: HistoryStats;
  version?: string;
};

function createFakeIpc(options: FakeIpcOptions = {}) {
  const invokedChannels: string[] = [];
  const notificationCallbacks = new Map<string, (params: unknown) => void>();
  const invokeArgs: Record<string, unknown[]> = {};

  const monitor = options.monitor ?? makeMonitor();
  const history = options.history ?? makeHistory();
  const version = options.version ?? "1.0.0";

  let disconnectCalls = 0;

  const ipc: GlazeIpcFacade = {
    async invoke<T>(channel: string, ...args: unknown[]): Promise<T> {
      invokedChannels.push(channel);
      invokeArgs[channel] = args;

      switch (channel) {
        case "agents:getState":
          return monitor as unknown as T;
        case "history:getStats":
          return history as unknown as T;
        case "app:getInfo":
          return { name: "Seer", version, environment: "test" } as unknown as T;
        case "agents:setKeepAwakeMode":
          return { ...monitor, keepAwakeMode: (args[0] as { mode: string }).mode } as unknown as T;
        case "history:clear":
          return makeHistory() as unknown as T;
        case "app:quit":
          return undefined as unknown as T;
        case "window:hidePanel":
          return undefined as unknown as T;
        default:
          throw new Error(`Unexpected channel: ${channel}`);
      }
    },
    onNotification(channel: string, callback: (params: unknown) => void): () => void {
      notificationCallbacks.set(channel, callback);
      return () => {
        notificationCallbacks.delete(channel);
      };
    },
    disconnect(): void {
      disconnectCalls += 1;
    },
  };

  return {
    ipc,
    invokedChannels,
    invokeArgs,
    fireNotification(channel: string, params: unknown): void {
      notificationCallbacks.get(channel)?.(params);
    },
    get disconnectCalls() {
      return disconnectCalls;
    },
  };
}

test("getSnapshot returns appVersion 1.0.0 and invokes channels in exact order", async () => {
  const fake = createFakeIpc({ version: "1.0.0" });
  const bridge = createGlazeRendererBridge(fake.ipc);

  const snapshot = await bridge.getSnapshot();

  assert.equal(snapshot.appVersion, "1.0.0");
  assert.deepEqual(fake.invokedChannels, ["agents:getState", "history:getStats", "app:getInfo"]);
  assert.deepEqual(snapshot.update, {
    checking: false,
    availableVersion: null,
    releaseURL: null,
    lastCheckedAt: null,
  });
  assert.deepEqual(snapshot.diagnostics, []);
});

test("setKeepAwakeMode preserves a full snapshot and returns an immutable clone", async () => {
  const fake = createFakeIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);

  const initial = await bridge.getSnapshot();
  const updated = await bridge.setKeepAwakeMode("display");

  assert.equal(updated.monitor.keepAwakeMode, "display");
  assert.equal(updated.appVersion, initial.appVersion);
  assert.deepEqual(updated.history, initial.history);

  // Mutating the returned snapshot must not affect internal state.
  updated.monitor.agents.push({
    id: "mutated",
    name: "mutated",
    detail: "mutated",
    source: "process",
    lastActivityAt: 0,
  });
  const again = await bridge.setKeepAwakeMode("system");
  assert.deepEqual(again.monitor.agents, []);
});

test("clearHistory preserves a full snapshot and returns an immutable clone", async () => {
  const fake = createFakeIpc({
    history: makeHistory({ totalAwakeMs: 5000, perAgent: [{ id: "a", name: "Agent", durationMs: 5000 }] }),
  });
  const bridge = createGlazeRendererBridge(fake.ipc);

  const initial = await bridge.getSnapshot();
  assert.equal(initial.history.totalAwakeMs, 5000);

  const cleared = await bridge.clearHistory();
  assert.equal(cleared.history.totalAwakeMs, 0);
  assert.equal(cleared.appVersion, initial.appVersion);
  assert.deepEqual(cleared.monitor, initial.monitor);
});

test("agents:state-changed and history:changed notifications merge into complete cloned snapshots", async () => {
  const fake = createFakeIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);
  const received: Array<Awaited<ReturnType<typeof bridge.getSnapshot>>> = [];

  const unsubscribe = bridge.subscribe((snapshot) => {
    received.push(snapshot);
  });

  await bridge.getSnapshot();

  const nextMonitor = makeMonitor({ active: true, keepingAwake: true });
  fake.fireNotification("agents:state-changed", nextMonitor);

  assert.equal(received.length, 1);
  assert.equal(received[0].monitor.active, true);
  assert.equal(received[0].monitor.keepingAwake, true);
  // Full snapshot preserved alongside the merged monitor field.
  assert.ok(received[0].history);
  assert.equal(received[0].appVersion, "1.0.0");

  const nextHistory = makeHistory({ totalAwakeMs: 9999 });
  fake.fireNotification("history:changed", nextHistory);

  assert.equal(received.length, 2);
  assert.equal(received[1].history.totalAwakeMs, 9999);
  assert.equal(received[1].monitor.active, true); // preserved from prior merge

  // Clones: mutating a delivered snapshot must not affect future notifications.
  received[1].monitor.agents.push({
    id: "x",
    name: "x",
    detail: "x",
    source: "process",
    lastActivityAt: 0,
  });
  fake.fireNotification("history:changed", makeHistory({ totalAwakeMs: 1 }));
  assert.deepEqual(received[2].monitor.agents, []);

  unsubscribe();
  fake.fireNotification("history:changed", makeHistory({ totalAwakeMs: 2 }));
  assert.equal(received.length, 3);
});

test("disconnect invokes ipc disconnect", () => {
  const fake = createFakeIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);

  bridge.disconnect();

  assert.equal(fake.disconnectCalls, 1);
});

test("hidePanel invokes window:hidePanel exactly once with no arguments", async () => {
  const fake = createFakeIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);

  await bridge.hidePanel();

  assert.deepEqual(fake.invokedChannels, ["window:hidePanel"]);
  assert.deepEqual(fake.invokeArgs["window:hidePanel"], []);
});

// --- Finding 4: initial getSnapshot cannot clobber newer notifications/mutations. ---

/** A deferred promise: resolve/reject can be called from outside the executor. */
function createDeferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

/**
 * An IPC facade whose `invoke` calls never resolve on their own — each call
 * is queued per channel and must be resolved explicitly via `resolveCall`,
 * by channel name and 0-indexed call order. This lets tests control the
 * exact completion order of overlapping `getSnapshot`/mutation calls.
 */
function createControllableIpc() {
  const queues = new Map<string, Array<{ resolve: (value: unknown) => void; reject: (error: unknown) => void }>>();
  const notificationCallbacks = new Map<string, (params: unknown) => void>();
  const invokedChannels: string[] = [];

  const ipc: GlazeIpcFacade = {
    invoke<T>(channel: string): Promise<T> {
      invokedChannels.push(channel);
      const deferred = createDeferred<unknown>();
      const queue = queues.get(channel) ?? [];
      queue.push({ resolve: deferred.resolve, reject: deferred.reject });
      queues.set(channel, queue);
      return deferred.promise as Promise<T>;
    },
    onNotification(channel: string, callback: (params: unknown) => void): () => void {
      notificationCallbacks.set(channel, callback);
      return () => {
        notificationCallbacks.delete(channel);
      };
    },
  };

  return {
    ipc,
    invokedChannels,
    fireNotification(channel: string, params: unknown): void {
      notificationCallbacks.get(channel)?.(params);
    },
    resolveCall(channel: string, index: number, value: unknown): void {
      const queue = queues.get(channel);
      const call = queue?.[index];
      if (!call) {
        throw new Error(`No pending call #${index} for channel "${channel}"`);
      }
      call.resolve(value);
    },
    rejectCall(channel: string, index: number, error: unknown): void {
      const queue = queues.get(channel);
      const call = queue?.[index];
      if (!call) {
        throw new Error(`No pending call #${index} for channel "${channel}"`);
      }
      call.reject(error);
    },
  };
}

test("an agents:state-changed notification arriving while the initial getSnapshot fetch is in flight is buffered and merged in after it resolves", async () => {
  const fake = createControllableIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);

  const snapshotPromise = bridge.getSnapshot();

  // The notification arrives before any of the initial fetch's underlying
  // IPC calls have resolved — `current` is still null at this point.
  const freshMonitor = makeMonitor({ active: true, keepingAwake: true });
  fake.fireNotification("agents:state-changed", freshMonitor);

  // Now let the initial fetch resolve with *stale* monitor data (as if it
  // had been read from the native host before the notification's change).
  fake.resolveCall("agents:getState", 0, makeMonitor({ active: false, keepingAwake: false }));
  fake.resolveCall("history:getStats", 0, makeHistory());
  fake.resolveCall("app:getInfo", 0, { name: "Seer", version: "1.0.0", environment: "test" });

  const snapshot = await snapshotPromise;

  // The buffered notification (received while the fetch was in flight) must
  // win over the fetch's own now-stale monitor result.
  assert.equal(snapshot.monitor.active, true);
  assert.equal(snapshot.monitor.keepingAwake, true);
});

test("a history:changed notification arriving while the initial getSnapshot fetch is in flight is buffered and merged in after it resolves", async () => {
  const fake = createControllableIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);

  const snapshotPromise = bridge.getSnapshot();

  const freshHistory = makeHistory({ totalAwakeMs: 12345 });
  fake.fireNotification("history:changed", freshHistory);

  fake.resolveCall("agents:getState", 0, makeMonitor());
  fake.resolveCall("history:getStats", 0, makeHistory({ totalAwakeMs: 1 }));
  fake.resolveCall("app:getInfo", 0, { name: "Seer", version: "1.0.0", environment: "test" });

  const snapshot = await snapshotPromise;

  assert.equal(snapshot.history.totalAwakeMs, 12345);
});

test("an older concurrent getSnapshot completion cannot overwrite a newer completed mutation", async () => {
  const fake = createControllableIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);

  // Establish an initial known-good snapshot first.
  const initialPromise = bridge.getSnapshot();
  fake.resolveCall("agents:getState", 0, makeMonitor({ keepAwakeMode: "system" }));
  fake.resolveCall("history:getStats", 0, makeHistory());
  fake.resolveCall("app:getInfo", 0, { name: "Seer", version: "1.0.0", environment: "test" });
  await initialPromise;

  // Start a *second* getSnapshot() (the older concurrent operation) whose
  // underlying IPC calls will be left pending/unresolved for now.
  const staleSnapshotPromise = bridge.getSnapshot();

  // A setKeepAwakeMode() mutation starts after it, but completes first.
  const setModePromise = bridge.setKeepAwakeMode("display");
  fake.resolveCall("agents:setKeepAwakeMode", 0, makeMonitor({ keepAwakeMode: "display" }));
  const updatedSnapshot = await setModePromise;
  assert.equal(updatedSnapshot.monitor.keepAwakeMode, "display");

  // Only now does the older, stale getSnapshot's fetch finally resolve —
  // with data that predates the mutation above.
  fake.resolveCall("agents:getState", 1, makeMonitor({ keepAwakeMode: "system" }));
  fake.resolveCall("history:getStats", 1, makeHistory());
  fake.resolveCall("app:getInfo", 1, { name: "Seer", version: "1.0.0", environment: "test" });
  const staleSnapshot = await staleSnapshotPromise;

  // The stale getSnapshot's own resolved value must reflect the newer
  // mutation, not clobber it with the fetch's outdated data.
  assert.equal(staleSnapshot.monitor.keepAwakeMode, "display");
});

// --- Finding 5: agent ticks must keep History live, not just the monitor. ---

test("an agents:state-changed notification emits an immediate merged snapshot, then asynchronously refreshes history and emits it as a second snapshot", async () => {
  const fake = createControllableIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);
  const received: Array<Awaited<ReturnType<typeof bridge.getSnapshot>>> = [];
  bridge.subscribe((snapshot) => received.push(snapshot));

  const snapshotPromise = bridge.getSnapshot();
  fake.resolveCall("agents:getState", 0, makeMonitor({ keepAwakeMode: "system" }));
  fake.resolveCall("history:getStats", 0, makeHistory({ totalAwakeMs: 1000 }));
  fake.resolveCall("app:getInfo", 0, { name: "Seer", version: "1.0.0", environment: "test" });
  await snapshotPromise;

  // An agent scan tick: the monitor changes (e.g. the in-progress awake
  // session's live duration ticked), which must both update immediately and
  // kick off a fresh `history:getStats` fetch in the background.
  const tickedMonitor = makeMonitor({ active: true, keepingAwake: true });
  fake.fireNotification("agents:state-changed", tickedMonitor);

  // The immediate merge with the new monitor must be delivered synchronously.
  assert.equal(received.length, 1);
  assert.equal(received[0].monitor.active, true);
  assert.equal(received[0].history.totalAwakeMs, 1000, "history unchanged until the refresh resolves");

  // The background `history:getStats` refresh resolves with fresher stats.
  fake.resolveCall("history:getStats", 1, makeHistory({ totalAwakeMs: 5000 }));
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(received.length, 2, "the async history refresh must emit a second snapshot");
  assert.equal(received[1].history.totalAwakeMs, 5000);
  assert.equal(received[1].monitor.active, true, "the ticked monitor must still be present");
});

test("a stale history refresh triggered by an agent tick cannot overwrite a newer clearHistory result", async () => {
  const fake = createControllableIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);
  const received: Array<Awaited<ReturnType<typeof bridge.getSnapshot>>> = [];
  bridge.subscribe((snapshot) => received.push(snapshot));

  const snapshotPromise = bridge.getSnapshot();
  fake.resolveCall("agents:getState", 0, makeMonitor());
  fake.resolveCall("history:getStats", 0, makeHistory({ totalAwakeMs: 1000 }));
  fake.resolveCall("app:getInfo", 0, { name: "Seer", version: "1.0.0", environment: "test" });
  await snapshotPromise;

  // The agent tick fires, kicking off a background history refresh whose
  // `history:getStats` call is left pending.
  fake.fireNotification("agents:state-changed", makeMonitor({ active: true }));

  // Before that refresh resolves, the user clears history — a newer
  // operation that must win regardless of completion order.
  const clearPromise = bridge.clearHistory();
  fake.resolveCall("history:clear", 0, makeHistory({ totalAwakeMs: 0 }));
  const cleared = await clearPromise;
  assert.equal(cleared.history.totalAwakeMs, 0);

  // Now the stale background refresh (from before the clear) finally
  // resolves with data that predates the clear.
  fake.resolveCall("history:getStats", 1, makeHistory({ totalAwakeMs: 9999 }));
  await Promise.resolve();
  await Promise.resolve();

  const finalSnapshot = received[received.length - 1];
  assert.equal(finalSnapshot.history.totalAwakeMs, 0, "the stale refresh must never have won");
});

test("a stale history refresh triggered by an agent tick cannot overwrite a newer history:changed notification", async () => {
  const fake = createControllableIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);
  const received: Array<Awaited<ReturnType<typeof bridge.getSnapshot>>> = [];
  bridge.subscribe((snapshot) => received.push(snapshot));

  const snapshotPromise = bridge.getSnapshot();
  fake.resolveCall("agents:getState", 0, makeMonitor());
  fake.resolveCall("history:getStats", 0, makeHistory({ totalAwakeMs: 1000 }));
  fake.resolveCall("app:getInfo", 0, { name: "Seer", version: "1.0.0", environment: "test" });
  await snapshotPromise;

  // Agent tick kicks off a background history refresh (left pending).
  fake.fireNotification("agents:state-changed", makeMonitor({ active: true }));

  // A newer, independent history:changed notification arrives and is
  // applied immediately (e.g. the native host pushed a fresh stat set).
  fake.fireNotification("history:changed", makeHistory({ totalAwakeMs: 42 }));

  const lastReceivedBeforeStaleResolve = received[received.length - 1];
  assert.equal(lastReceivedBeforeStaleResolve.history.totalAwakeMs, 42);

  // The stale background refresh from the agent tick resolves last, with
  // now-outdated data.
  fake.resolveCall("history:getStats", 1, makeHistory({ totalAwakeMs: 9999 }));
  await Promise.resolve();
  await Promise.resolve();

  const finalSnapshot = received[received.length - 1];
  assert.equal(finalSnapshot.history.totalAwakeMs, 42, "the stale refresh must never have won");
});

test("unsubscribing before a pending agent-tick history refresh resolves prevents further emissions to that listener", async () => {
  const fake = createControllableIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);
  const received: Array<Awaited<ReturnType<typeof bridge.getSnapshot>>> = [];
  const unsubscribe = bridge.subscribe((snapshot) => received.push(snapshot));

  const snapshotPromise = bridge.getSnapshot();
  fake.resolveCall("agents:getState", 0, makeMonitor());
  fake.resolveCall("history:getStats", 0, makeHistory());
  fake.resolveCall("app:getInfo", 0, { name: "Seer", version: "1.0.0", environment: "test" });
  await snapshotPromise;

  fake.fireNotification("agents:state-changed", makeMonitor({ active: true }));
  assert.equal(received.length, 1);

  unsubscribe();

  fake.resolveCall("history:getStats", 1, makeHistory({ totalAwakeMs: 777 }));
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(received.length, 1, "no emissions must reach a listener after it unsubscribes");
});

test("an older concurrent getSnapshot completion does not clobber a newer completed getSnapshot", async () => {
  const fake = createControllableIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);

  // Two overlapping getSnapshot() calls — A started first, B started second.
  const snapshotAPromise = bridge.getSnapshot();
  const snapshotBPromise = bridge.getSnapshot();

  // B (started later) resolves *first*, with fresher data.
  fake.resolveCall("agents:getState", 1, makeMonitor({ active: true }));
  fake.resolveCall("history:getStats", 1, makeHistory());
  fake.resolveCall("app:getInfo", 1, { name: "Seer", version: "2.0.0", environment: "test" });
  const snapshotB = await snapshotBPromise;
  assert.equal(snapshotB.monitor.active, true);
  assert.equal(snapshotB.appVersion, "2.0.0");

  // A (started earlier) resolves *after* B, with stale data.
  fake.resolveCall("agents:getState", 0, makeMonitor({ active: false }));
  fake.resolveCall("history:getStats", 0, makeHistory());
  fake.resolveCall("app:getInfo", 0, { name: "Seer", version: "1.0.0", environment: "test" });
  const snapshotA = await snapshotAPromise;

  // A's own resolution must reflect B's already-applied, newer state.
  assert.equal(snapshotA.monitor.active, true);
  assert.equal(snapshotA.appVersion, "2.0.0");
});

// --- Additional Finding 5 coverage: independent history-refresh generations, ---
// --- error handling, and disconnect/unsubscribe guards.                     ---

test("two quick agent ticks each trigger their own history refresh; the first refresh to resolve is not incorrectly treated as stale by the second tick's mere monitor merge", async () => {
  const fake = createControllableIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);
  const received: Array<Awaited<ReturnType<typeof bridge.getSnapshot>>> = [];
  bridge.subscribe((snapshot) => received.push(snapshot));

  const snapshotPromise = bridge.getSnapshot();
  fake.resolveCall("agents:getState", 0, makeMonitor());
  fake.resolveCall("history:getStats", 0, makeHistory({ totalAwakeMs: 1000 }));
  fake.resolveCall("app:getInfo", 0, { name: "Seer", version: "1.0.0", environment: "test" });
  await snapshotPromise;

  // Tick 1: monitor merge applied immediately, background history refresh #1
  // (history:getStats call index 1) kicked off and left pending.
  fake.fireNotification("agents:state-changed", makeMonitor({ active: true, lastScanAt: 1 }));
  assert.equal(received.length, 1);

  // Tick 2 fires quickly, before refresh #1 resolves: another monitor merge
  // applied immediately, and background history refresh #2 (call index 2)
  // kicked off and also left pending.
  fake.fireNotification("agents:state-changed", makeMonitor({ active: true, lastScanAt: 2 }));
  assert.equal(received.length, 2);

  // Refresh #1 (triggered by tick 1) resolves first, with fresher stats than
  // the initial fetch. Even though tick 2's plain monitor merge was sequenced
  // after refresh #1 was kicked off, it must not make refresh #1's result
  // look "stale" — no newer history data exists yet.
  fake.resolveCall("history:getStats", 1, makeHistory({ totalAwakeMs: 5000 }));
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(received.length, 3, "refresh #1 must emit a third snapshot");
  assert.equal(received[2].history.totalAwakeMs, 5000, "refresh #1's data must be applied, not dropped");
  assert.equal(received[2].monitor.lastScanAt, 2, "the latest monitor merge must still be present");

  // Refresh #2 (triggered by tick 2) resolves last, with even fresher stats,
  // and must supersede refresh #1's now-stale result.
  fake.resolveCall("history:getStats", 2, makeHistory({ totalAwakeMs: 9000 }));
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(received.length, 4, "refresh #2 must emit a fourth snapshot");
  assert.equal(received[3].history.totalAwakeMs, 9000, "refresh #2 must supersede refresh #1");
});

test("a rejected background history refresh triggered by an agent tick produces no unhandled promise rejection", async () => {
  const fake = createControllableIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);

  const snapshotPromise = bridge.getSnapshot();
  fake.resolveCall("agents:getState", 0, makeMonitor());
  fake.resolveCall("history:getStats", 0, makeHistory());
  fake.resolveCall("app:getInfo", 0, { name: "Seer", version: "1.0.0", environment: "test" });
  await snapshotPromise;

  const unhandledRejections: unknown[] = [];
  const onUnhandledRejection = (reason: unknown) => unhandledRejections.push(reason);
  process.on("unhandledRejection", onUnhandledRejection);

  try {
    fake.fireNotification("agents:state-changed", makeMonitor({ active: true }));
    fake.rejectCall("history:getStats", 1, new Error("history:getStats failed"));

    // Give the rejection a chance to surface as an unhandled rejection if it
    // were not caught internally (Node reports these on a later microtask
    // turn, sometimes requiring a macrotask tick to fully flush).
    await new Promise((resolve) => setTimeout(resolve, 10));
  } finally {
    process.off("unhandledRejection", onUnhandledRejection);
  }

  assert.deepEqual(unhandledRejections, [], "a failed background refresh must never be an unhandled rejection");
});

test("disconnect prevents a pending agent-tick history refresh from emitting anything once it resolves", async () => {
  const fake = createControllableIpc();
  const bridge = createGlazeRendererBridge(fake.ipc);
  const received: Array<Awaited<ReturnType<typeof bridge.getSnapshot>>> = [];
  bridge.subscribe((snapshot) => received.push(snapshot));

  const snapshotPromise = bridge.getSnapshot();
  fake.resolveCall("agents:getState", 0, makeMonitor());
  fake.resolveCall("history:getStats", 0, makeHistory());
  fake.resolveCall("app:getInfo", 0, { name: "Seer", version: "1.0.0", environment: "test" });
  await snapshotPromise;

  fake.fireNotification("agents:state-changed", makeMonitor({ active: true }));
  assert.equal(received.length, 1);

  bridge.disconnect();

  fake.resolveCall("history:getStats", 1, makeHistory({ totalAwakeMs: 555 }));
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(received.length, 1, "no emissions must reach any listener after disconnect");
});
