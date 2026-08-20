import assert from "node:assert/strict";
import test from "node:test";
import * as React from "react";
import { renderToStaticMarkup } from "react-dom/server";

import type { AppSnapshot } from "../bridge/types";
import { HistoryClearButton, HistorySnapshotContent } from "./history-view";

function makeSnapshot(): AppSnapshot {
  return {
    monitor: {
      active: false,
      keepingAwake: false,
      keepAwakeMode: "system",
      agents: [],
      lastScanAt: 1,
    },
    history: {
      totalAwakeMs: 2_000,
      todayAwakeMs: 2_000,
      sessionCount: 1,
      perAgent: [{ id: "codex", name: "Codex", durationMs: 2_000 }],
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
  };
}

test("HistorySnapshotContent distinguishes initial loading from unavailable", () => {
  const loading = renderToStaticMarkup(
    React.createElement(HistorySnapshotContent, {
      snapshot: undefined,
      isPending: true,
      isError: false,
    }),
  );
  const unavailable = renderToStaticMarkup(
    React.createElement(HistorySnapshotContent, {
      snapshot: undefined,
      isPending: false,
      isError: true,
    }),
  );

  assert.match(loading, /role="status"/);
  assert.match(loading, /Loading history/);
  assert.doesNotMatch(loading, /No activity yet/);
  assert.match(unavailable, /role="alert"/);
  assert.match(unavailable, /History unavailable/);
  assert.doesNotMatch(unavailable, /No activity yet/);
});

test("HistorySnapshotContent keeps prior history visible during an error", () => {
  const markup = renderToStaticMarkup(
    React.createElement(HistorySnapshotContent, {
      snapshot: makeSnapshot(),
      isPending: false,
      isError: true,
    }),
  );

  assert.match(markup, /All time/);
  assert.match(markup, /Showing last known history/);
});

test("History clear mutation is disabled during failure and re-enabled after recovery", () => {
  const disabled = renderToStaticMarkup(
    React.createElement(HistoryClearButton, {
      disabled: true,
      onClear: () => undefined,
    }),
  );
  const recovered = renderToStaticMarkup(
    React.createElement(HistoryClearButton, {
      disabled: false,
      onClear: () => undefined,
    }),
  );

  assert.match(disabled, /disabled=""/);
  assert.doesNotMatch(recovered, /disabled=""/);
});
