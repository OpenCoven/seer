import assert from "node:assert/strict";
import test from "node:test";

import {
  createDomRelayPort,
  DOM_RELAY_ATTRIBUTE,
  DOM_RELAY_EVENT_NAME,
  DOM_RELAY_MAX_BYTES,
  DomRelayPayloadTooLargeError,
  type DomRelayTarget,
} from "./dom-relay-port";
import { BRIDGE_VERSION } from "./types";

/**
 * A minimal fake `DomRelayTarget`. Records every `setAttribute`/
 * `removeAttribute`/`dispatchEvent` call in order, and lets a test attach
 * a listener that runs synchronously during `dispatchEvent` — exactly like
 * a real DOM node's event dispatch, and exactly like
 * `BridgeRelayUserScript`'s own listener behaves in production (reading
 * and removing the attribute before `dispatchEvent` returns).
 */
class FakeDomRelayTarget implements DomRelayTarget {
  private attributes = new Map<string, string>();
  readonly calls: Array<
    | { kind: "setAttribute"; name: string; value: string }
    | { kind: "removeAttribute"; name: string }
    | { kind: "dispatchEvent"; type: string; bubbles: boolean }
  > = [];

  /** Set by a test to simulate the isolated-world relay script's listener. */
  onDispatch: ((target: FakeDomRelayTarget, event: Event) => void) | null = null;

  setAttribute(qualifiedName: string, value: string): void {
    this.attributes.set(qualifiedName, value);
    this.calls.push({ kind: "setAttribute", name: qualifiedName, value });
  }

  removeAttribute(qualifiedName: string): void {
    this.attributes.delete(qualifiedName);
    this.calls.push({ kind: "removeAttribute", name: qualifiedName });
  }

  dispatchEvent(event: Event): boolean {
    this.calls.push({ kind: "dispatchEvent", type: event.type, bubbles: event.bubbles });
    this.onDispatch?.(this, event);
    return true;
  }

  getAttribute(qualifiedName: string): string | null {
    return this.attributes.get(qualifiedName) ?? null;
  }

  hasAttribute(qualifiedName: string): boolean {
    return this.attributes.has(qualifiedName);
  }
}

function makeRequest() {
  return {
    id: "550e8400-e29b-41d4-a716-446655440000",
    version: BRIDGE_VERSION,
    method: "snapshot.get" as const,
    payload: {},
  };
}

test("createDomRelayPort sets the exact fixed attribute with the JSON-encoded request", () => {
  const target = new FakeDomRelayTarget();
  const port = createDomRelayPort(target);
  const request = makeRequest();

  port.postMessage(request);

  const setCall = target.calls.find((call) => call.kind === "setAttribute");
  assert.ok(setCall && setCall.kind === "setAttribute");
  assert.equal(setCall.name, DOM_RELAY_ATTRIBUTE);
  assert.deepEqual(JSON.parse(setCall.value), request);
});

test("createDomRelayPort dispatches exactly one non-bubbling event with the fixed name and no detail", () => {
  const target = new FakeDomRelayTarget();
  const port = createDomRelayPort(target);

  port.postMessage(makeRequest());

  const dispatchCalls = target.calls.filter((call) => call.kind === "dispatchEvent");
  assert.equal(dispatchCalls.length, 1);
  assert.equal(dispatchCalls[0]?.kind, "dispatchEvent");
  if (dispatchCalls[0]?.kind === "dispatchEvent") {
    assert.equal(dispatchCalls[0].type, DOM_RELAY_EVENT_NAME);
    assert.equal(dispatchCalls[0].bubbles, false);
  }
});

test("createDomRelayPort dispatches a plain Event, never a CustomEvent carrying a detail payload", () => {
  const target = new FakeDomRelayTarget();
  let observedEvent: Event | undefined;
  target.onDispatch = (_target, event) => {
    observedEvent = event;
  };
  const port = createDomRelayPort(target);

  port.postMessage(makeRequest());

  assert.ok(observedEvent);
  assert.equal((observedEvent as CustomEvent).detail, undefined);
});

test("createDomRelayPort sets the attribute before dispatching and it is still readable synchronously during dispatch", () => {
  const target = new FakeDomRelayTarget();
  let valueDuringDispatch: string | null = null;
  target.onDispatch = (t) => {
    valueDuringDispatch = t.getAttribute(DOM_RELAY_ATTRIBUTE);
  };
  const port = createDomRelayPort(target);
  const request = makeRequest();

  port.postMessage(request);

  assert.ok(valueDuringDispatch);
  assert.deepEqual(JSON.parse(valueDuringDispatch as string), request);
});

test("createDomRelayPort removes the attribute after a listener already consumed it (success path, no replay residue)", () => {
  const target = new FakeDomRelayTarget();
  // Simulate BridgeRelayUserScript's own behavior: read then immediately
  // remove the attribute itself, before dispatchEvent returns.
  target.onDispatch = (t) => {
    t.getAttribute(DOM_RELAY_ATTRIBUTE);
    t.removeAttribute(DOM_RELAY_ATTRIBUTE);
  };
  const port = createDomRelayPort(target);

  port.postMessage(makeRequest());

  assert.equal(target.hasAttribute(DOM_RELAY_ATTRIBUTE), false);
});

test("createDomRelayPort removes the attribute itself even when no listener ever consumes it", () => {
  const target = new FakeDomRelayTarget();
  const port = createDomRelayPort(target);

  port.postMessage(makeRequest());

  assert.equal(target.hasAttribute(DOM_RELAY_ATTRIBUTE), false);
});

test("createDomRelayPort removes the attribute even when dispatchEvent throws", () => {
  const target = new FakeDomRelayTarget();
  target.onDispatch = () => {
    throw new Error("simulated dispatch failure");
  };
  const port = createDomRelayPort(target);

  assert.throws(() => port.postMessage(makeRequest()), /simulated dispatch failure/);
  assert.equal(target.hasAttribute(DOM_RELAY_ATTRIBUTE), false);
});

test("createDomRelayPort never reads window.webkit or requires it to exist", () => {
  const target = new FakeDomRelayTarget();
  const originalWebkit = (globalThis as { webkit?: unknown }).webkit;
  delete (globalThis as { webkit?: unknown }).webkit;
  try {
    const port = createDomRelayPort(target);
    assert.doesNotThrow(() => port.postMessage(makeRequest()));
  } finally {
    (globalThis as { webkit?: unknown }).webkit = originalWebkit;
  }
});

test("createDomRelayPort throws DomRelayPayloadTooLargeError locally for a request over the 64KiB bound, without touching the DOM", () => {
  const target = new FakeDomRelayTarget();
  const port = createDomRelayPort(target);
  const oversizedRequest = {
    id: "550e8400-e29b-41d4-a716-446655440000",
    version: BRIDGE_VERSION,
    method: "keepAwakeMode.set" as const,
    payload: { mode: "system" as const, padding: "x".repeat(DOM_RELAY_MAX_BYTES + 1) },
  };

  assert.throws(() => port.postMessage(oversizedRequest as never), DomRelayPayloadTooLargeError);
  assert.equal(target.calls.length, 0, "an oversized request must never reach setAttribute/dispatchEvent at all");
});

test("createDomRelayPort accepts a request exactly at the 64KiB bound", () => {
  const target = new FakeDomRelayTarget();
  const port = createDomRelayPort(target);

  // Build a payload string whose JSON encoding is exactly DOM_RELAY_MAX_BYTES.
  const base = { id: "550e8400-e29b-41d4-a716-446655440000", version: BRIDGE_VERSION, method: "keepAwakeMode.set" as const, payload: { mode: "system" as const, padding: "" } };
  const baseLength = new TextEncoder().encode(JSON.stringify(base)).length;
  const padding = "x".repeat(DOM_RELAY_MAX_BYTES - baseLength);
  const exactRequest = { ...base, payload: { ...base.payload, padding } };
  assert.equal(new TextEncoder().encode(JSON.stringify(exactRequest)).length, DOM_RELAY_MAX_BYTES);

  assert.doesNotThrow(() => port.postMessage(exactRequest as never));
  assert.equal(target.calls.filter((call) => call.kind === "setAttribute").length, 1);
});

test("createDomRelayPort propagates a JSON.stringify failure (e.g. a BigInt payload) without touching the DOM", () => {
  const target = new FakeDomRelayTarget();
  const port = createDomRelayPort(target);
  const unserializable = {
    id: "550e8400-e29b-41d4-a716-446655440000",
    version: BRIDGE_VERSION,
    method: "snapshot.get" as const,
    payload: { bad: 1n },
  };

  assert.throws(() => port.postMessage(unserializable as never), TypeError);
  assert.equal(target.calls.length, 0);
});

test("createDomRelayPort defaults to document.documentElement when no target is supplied", () => {
  // `document` does not exist in this Node test environment, so
  // `createDomRelayPort()` (default parameter evaluated eagerly) must
  // throw a ReferenceError rather than silently doing nothing — proving
  // the default really does wire to `document.documentElement` and not to
  // some other, quietly-inert fallback.
  assert.throws(() => createDomRelayPort(), ReferenceError);
});
