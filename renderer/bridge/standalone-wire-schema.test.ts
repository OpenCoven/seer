import assert from "node:assert/strict";
import test from "node:test";

import { isAppSnapshot } from "./standalone-wire-schema";
import type { AppSnapshot } from "./types";

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
      ],
      lastScanAt: 3000,
    },
    history: {
      totalAwakeMs: 5000,
      todayAwakeMs: 1000,
      sessionCount: 2,
      perAgent: [{ id: "agent-1", name: "Agent One", durationMs: 500 }],
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

test("a well-formed plain-object AppSnapshot (own properties, Object.prototype) is accepted", () => {
  assert.equal(isAppSnapshot(makeFullSnapshot()), true);
});

test("an AppSnapshot built with Object.create(null) (no prototype) is accepted", () => {
  const snapshot = makeFullSnapshot();
  const nullProtoMonitor = Object.assign(Object.create(null), snapshot.monitor);
  const nullProtoAgent = Object.assign(Object.create(null), snapshot.monitor.agents[0]);
  nullProtoMonitor.agents = [nullProtoAgent];
  const nullProtoSnapshot = Object.assign(Object.create(null), snapshot, {
    monitor: nullProtoMonitor,
  });

  assert.equal(isAppSnapshot(nullProtoSnapshot), true);
});

test("a class instance (custom prototype) is rejected even with all fields present as own properties", () => {
  class FakeMonitor {
    active = true;
    keepingAwake = true;
    keepAwakeMode = "display" as const;
    agents: unknown[] = [];
    lastScanAt = 3000;
  }

  const snapshot = { ...makeFullSnapshot(), monitor: new FakeMonitor() };
  assert.equal(isAppSnapshot(snapshot), false);
});

test("a class instance at the top level is rejected", () => {
  class FakeSnapshot {
    monitor = makeFullSnapshot().monitor;
    history = makeFullSnapshot().history;
    update = makeFullSnapshot().update;
    diagnostics: unknown[] = [];
    appVersion = "1.0.0";
  }

  assert.equal(isAppSnapshot(new FakeSnapshot()), false);
});

test("a required field present only via prototype pollution (not own) is rejected", () => {
  // A custom `Object.create(proto)` prototype is already rejected by the
  // plain-object guard itself before any field is inspected, so the only
  // way an *accepted* plain object (prototype === Object.prototype) can
  // have an "inherited, not own" field is via pollution of
  // `Object.prototype` directly. Pollute with a *valid*-typed value: a
  // naive `in`/direct-property-access implementation would incorrectly
  // accept this object (it would read the inherited valid string), while a
  // correct `Object.hasOwn`-based implementation rejects it because `id` is
  // not the object's own property.
  const originalHasOwn = Object.hasOwn(Object.prototype, "id");
  assert.equal(originalHasOwn, false);
  Object.defineProperty(Object.prototype, "id", {
    value: "polluted-id",
    enumerable: true,
    configurable: true,
  });
  try {
    const snapshot = makeFullSnapshot();
    const agentMissingOwnId: Record<string, unknown> = {
      name: "Agent One",
      detail: "running",
      source: "both",
      lastActivityAt: 1000,
    };
    // `id` is only reachable through the prototype chain, never as an own property.
    assert.equal(Object.hasOwn(agentMissingOwnId, "id"), false);
    assert.equal("id" in agentMissingOwnId, true);

    const malformed = {
      ...snapshot,
      monitor: { ...snapshot.monitor, agents: [agentMissingOwnId] },
    };

    assert.equal(isAppSnapshot(malformed), false);
  } finally {
    delete (Object.prototype as Record<string, unknown>).id;
  }
});

test("an optional field present only via prototype pollution (not own) is treated as absent, not rejected", () => {
  // Pollute `Object.prototype.pid` with a value that would fail
  // `isFiniteNumber` if it were (incorrectly) read as the agent's own
  // `pid`. A correct `Object.hasOwn`-based optional check never reads it at
  // all — it treats the field as absent, so the snapshot is still accepted.
  Object.defineProperty(Object.prototype, "pid", {
    value: "not-a-number-and-would-fail-isFiniteNumber",
    enumerable: true,
    configurable: true,
  });
  try {
    const snapshot = makeFullSnapshot();
    const agentWithoutOwnPid: Record<string, unknown> = {
      id: "agent-1",
      name: "Agent One",
      detail: "running",
      source: "both",
      lastActivityAt: 1000,
    };
    assert.equal(Object.hasOwn(agentWithoutOwnPid, "pid"), false);
    assert.equal("pid" in agentWithoutOwnPid, true);

    const withInheritedField = {
      ...snapshot,
      monitor: { ...snapshot.monitor, agents: [agentWithoutOwnPid] },
    };

    assert.equal(isAppSnapshot(withInheritedField), true);
  } finally {
    delete (Object.prototype as Record<string, unknown>).pid;
  }
});

test("an optional field present as an own property with an invalid type is still rejected", () => {
  const snapshot = makeFullSnapshot();
  const agentWithBadOwnPid = {
    id: "agent-1",
    name: "Agent One",
    detail: "running",
    source: "both" as const,
    pid: "not-a-number",
    lastActivityAt: 1000,
  };

  const malformed = {
    ...snapshot,
    monitor: { ...snapshot.monitor, agents: [agentWithBadOwnPid] },
  };

  assert.equal(isAppSnapshot(malformed), false);
});
