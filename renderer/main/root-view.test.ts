import assert from "node:assert/strict";
import test from "node:test";

import { QueryClient } from "@tanstack/react-query";

import type { RendererBridge } from "../bridge/renderer-bridge";
import type { AppSnapshot } from "../bridge/types";
import { APP_SNAPSHOT_QUERY_KEY, isPanelHideKeydown, selectDiagnostics, writeAppSnapshot } from "./root-view";

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

/** A minimal fake bridge whose `subscribe` can be driven manually from tests. */
function createFakeBridge(): RendererBridge & { emit: (snapshot: AppSnapshot) => void } {
  const listeners = new Set<(snapshot: AppSnapshot) => void>();

  return {
    async getSnapshot() {
      return makeSnapshot();
    },
    async setKeepAwakeMode() {
      return makeSnapshot();
    },
    async clearHistory() {
      return makeSnapshot();
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    async requestUpdateCheck() {
      return makeSnapshot();
    },
    async openCurrentRelease() {},
    async quit() {},
    async hidePanel() {},
    disconnect() {
      listeners.clear();
    },
    emit(snapshot: AppSnapshot) {
      for (const listener of listeners) listener(snapshot);
    },
  };
}

test("isPanelHideKeydown is true only for an un-prevented Escape keydown", () => {
  assert.equal(isPanelHideKeydown({ key: "Escape", defaultPrevented: false }), true);
  assert.equal(isPanelHideKeydown({ key: "Escape", defaultPrevented: true }), false);
  assert.equal(isPanelHideKeydown({ key: "Enter", defaultPrevented: false }), false);
  assert.equal(isPanelHideKeydown({ key: "a", defaultPrevented: false }), false);
});

test("selectDiagnostics returns [] while the snapshot has not loaded yet", () => {
  assert.deepEqual(selectDiagnostics(undefined), []);
});

test("selectDiagnostics surfaces every diagnostic on a loaded snapshot", () => {
  const snapshot = makeSnapshot({
    diagnostics: [{ id: "d1", message: "Agent detector crashed", occurredAt: 1 }],
  });
  assert.deepEqual(selectDiagnostics(snapshot), [
    { id: "d1", message: "Agent detector crashed", occurredAt: 1 },
  ]);
});

test("writeAppSnapshot is the single place mutations funnel their result through", () => {
  const queryClient = new QueryClient();
  const snapshot = makeSnapshot({ appVersion: "9.9.9" });

  writeAppSnapshot(queryClient, snapshot);

  assert.deepEqual(queryClient.getQueryData(APP_SNAPSHOT_QUERY_KEY), snapshot);
});

test("bridge.subscribe pushes complete snapshots straight into the appSnapshot query cache", () => {
  const queryClient = new QueryClient();
  const bridge = createFakeBridge();

  const unsubscribe = bridge.subscribe((next) => {
    queryClient.setQueryData(APP_SNAPSHOT_QUERY_KEY, next);
  });

  assert.equal(queryClient.getQueryData(APP_SNAPSHOT_QUERY_KEY), undefined);

  const pushed = makeSnapshot({ appVersion: "2.0.0" });
  bridge.emit(pushed);

  assert.deepEqual(queryClient.getQueryData(APP_SNAPSHOT_QUERY_KEY), pushed);

  unsubscribe();
  bridge.emit(makeSnapshot({ appVersion: "3.0.0" }));

  // Unsubscribed: the cache must not move past the last snapshot it saw.
  assert.equal(
    (queryClient.getQueryData(APP_SNAPSHOT_QUERY_KEY) as AppSnapshot).appVersion,
    "2.0.0",
  );
});

test("a subscription snapshot recovers a query whose initial getSnapshot failed", async () => {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  });
  const bridge = createFakeBridge();
  const unsubscribe = bridge.subscribe((next) => {
    writeAppSnapshot(queryClient, next);
  });

  await assert.rejects(
    queryClient.fetchQuery({
      queryKey: APP_SNAPSHOT_QUERY_KEY,
      queryFn: async () => {
        throw new Error("snapshot unavailable");
      },
    }),
  );
  assert.equal(queryClient.getQueryState(APP_SNAPSHOT_QUERY_KEY)?.status, "error");
  assert.equal(queryClient.getQueryData(APP_SNAPSHOT_QUERY_KEY), undefined);

  const recovered = makeSnapshot({ appVersion: "7.0.0" });
  bridge.emit(recovered);

  assert.equal(queryClient.getQueryState(APP_SNAPSHOT_QUERY_KEY)?.status, "success");
  assert.deepEqual(queryClient.getQueryData(APP_SNAPSHOT_QUERY_KEY), recovered);
  unsubscribe();
});
