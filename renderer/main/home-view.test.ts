import assert from "node:assert/strict";
import test from "node:test";
import * as React from "react";
import { renderToStaticMarkup } from "react-dom/server";

import type { AppSnapshot } from "../bridge/types";
import { HomeSnapshotContent, snapshotBadgeLabel, sourceLabel, UpdateNotice } from "./home-view";

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
  };
}

const actions = {
  onModeChange: () => undefined,
  onViewRelease: () => undefined,
  onCheckForUpdates: () => undefined,
};

test("sourceLabel maps each ActiveAgent source to its display label", () => {
  assert.equal(sourceLabel("both"), "Process + session");
  assert.equal(sourceLabel("process"), "Process");
  assert.equal(sourceLabel("session"), "Session");
});

test("UpdateNotice is compact notify-only release copy with view and recheck actions", () => {
  const markup = renderToStaticMarkup(
    React.createElement(UpdateNotice, {
      availableVersion: "v1.2.0",
      checking: false,
      onView: () => undefined,
      onCheck: () => undefined,
    }),
  );

  assert.match(markup, /Seer v1\.2\.0 is available/);
  assert.match(markup, /View release/);
  assert.match(markup, /Check again/);
  assert.doesNotMatch(markup, /download|install/i);
});

test("HomeSnapshotContent renders initial loading without fabricating Idle or Sleep OK", () => {
  const markup = renderToStaticMarkup(
    React.createElement(HomeSnapshotContent, {
      snapshot: undefined,
      isPending: true,
      isError: false,
      modeMutationPending: false,
      updateMutationPending: false,
      ...actions,
    }),
  );

  assert.match(markup, /role="status"/);
  assert.match(markup, /Loading Seer status/);
  assert.doesNotMatch(markup, />Idle</);
  assert.doesNotMatch(markup, /Sleep OK/);
  assert.equal(snapshotBadgeLabel(undefined, true), "Loading");
});

test("HomeSnapshotContent renders an accessible unavailable state after a never-loaded failure", () => {
  const markup = renderToStaticMarkup(
    React.createElement(HomeSnapshotContent, {
      snapshot: undefined,
      isPending: false,
      isError: true,
      modeMutationPending: false,
      updateMutationPending: false,
      ...actions,
    }),
  );

  assert.match(markup, /role="alert"/);
  assert.match(markup, /Status unavailable/);
  assert.doesNotMatch(markup, />Idle</);
  assert.doesNotMatch(markup, /Sleep OK/);
  assert.equal(snapshotBadgeLabel(undefined, false), "Unavailable");
});

test("HomeSnapshotContent keeps prior data but disables mutations while refresh is unavailable", () => {
  const markup = renderToStaticMarkup(
    React.createElement(HomeSnapshotContent, {
      snapshot: makeSnapshot(),
      isPending: false,
      isError: true,
      modeMutationPending: false,
      updateMutationPending: false,
      ...actions,
    }),
  );

  assert.match(markup, />Idle</);
  assert.match(markup, /Showing last known status/);
  assert.equal((markup.match(/disabled=""/g) ?? []).length, 2);
});

test("HomeSnapshotContent recovery clears the error and re-enables mutations", () => {
  const markup = renderToStaticMarkup(
    React.createElement(HomeSnapshotContent, {
      snapshot: makeSnapshot(),
      isPending: false,
      isError: false,
      modeMutationPending: false,
      updateMutationPending: false,
      ...actions,
    }),
  );

  assert.doesNotMatch(markup, /Status unavailable|Showing last known status/);
  assert.doesNotMatch(markup, /disabled=""/);
});
