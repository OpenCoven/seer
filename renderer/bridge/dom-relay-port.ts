import type { BridgePort } from "./standalone-renderer-bridge";

/**
 * The standalone native host registers `BridgeMessageHandler` only in the
 * dedicated, isolated `com.seer.bridge` `WKContentWorld` (see
 * `BridgeContentWorld`/`BridgeMessageHandlerRegistration` in
 * `BridgeMessageHandler.swift`) — deliberately never `.page`. Registering
 * in `.page` would make `window.webkit.messageHandlers.seerBridge`
 * reachable by *any* script running in the page's own JavaScript world,
 * which defeats the whole point of the body-shape/content-world
 * mitigation. That means page-world code (this module included) has no
 * visibility of `window.webkit.messageHandlers.seerBridge` at all, and
 * must never attempt to read it.
 *
 * Instead, this module relays a request through the DOM to a trusted
 * `WKUserScript` (`BridgeRelayUserScript` in `BridgeMessageHandler.swift`)
 * that WebKit injects into that isolated world at document start: the
 * already-validated `BridgeRequest` is JSON-encoded to a plain string,
 * written into one fixed, private HTML attribute on
 * `document.documentElement`, and a fixed-name, non-bubbling `Event` (with
 * no `detail`/attacker-controlled payload) is dispatched to signal the
 * isolated-world script to read, remove, and forward that string —
 * unparsed — to the native handler. Because only an opaque JSON *string*
 * ever crosses into the isolated world (never a live object graph), the
 * native `BridgeMessageHandler`'s 64KiB/strict-JSON/allowlist validation
 * remains the sole authority over what that string actually means.
 *
 * `DOM_RELAY_ATTRIBUTE` and `DOM_RELAY_EVENT_NAME` are fixed, ASCII-only
 * tokens that MUST exactly match `BridgeRelayUserScript.attributeName`/
 * `.eventName` in `BridgeMessageHandler.swift`. Swift and TypeScript
 * cannot literally share source, so both sides hardcode the same literal
 * strings independently; tests on both sides lock down that exact
 * equality so they cannot silently drift apart.
 */
export const DOM_RELAY_ATTRIBUTE = "data-seer-bridge-payload";
export const DOM_RELAY_EVENT_NAME = "seer-bridge-relay";

/**
 * Local, defense-in-depth size bound matching the native host's own
 * authoritative `bridgeMaxMessageBytes` (`BridgeModels.swift`). The
 * native decoder rejects anything over this size regardless — this local
 * check exists only to fail fast, synchronously, at the call site instead
 * of always paying for the DOM round-trip first.
 */
export const DOM_RELAY_MAX_BYTES = 64 * 1024;

/** Minimal DOM surface this transport needs to write/dispatch through. */
export interface DomRelayTarget {
  setAttribute(qualifiedName: string, value: string): void;
  removeAttribute(qualifiedName: string): void;
  dispatchEvent(event: Event): boolean;
}

/** Thrown locally (never reaches the native host) for an oversized request. */
export class DomRelayPayloadTooLargeError extends Error {
  constructor(byteLength: number) {
    super(
      `Bridge request is ${byteLength} bytes, which exceeds the local ` +
        `${DOM_RELAY_MAX_BYTES}-byte defense bound (the native host's own ` +
        "limit is authoritative regardless)",
    );
    this.name = "DomRelayPayloadTooLargeError";
  }
}

/**
 * Best-effort UTF-8 byte length of `value`. `TextEncoder` is available in
 * every environment this transport actually runs in (WKWebView, and every
 * modern browser/Node used to test it), but a conservative fallback is
 * kept so a missing `TextEncoder` fails toward *rejecting* an
 * oversized-looking string rather than silently skipping the bound
 * entirely.
 */
function utf8ByteLength(value: string): number {
  if (typeof TextEncoder === "function") {
    return new TextEncoder().encode(value).length;
  }
  // UTF-8 encodes any UTF-16 code unit as at most 3 bytes (BMP) or, for a
  // surrogate pair (2 code units), 4 bytes total — i.e. never more than 3
  // bytes per UTF-16 code unit — so `value.length * 3` is always a safe
  // upper bound when the real encoder is unavailable.
  return value.length * 3;
}

/**
 * Builds the standalone renderer's `BridgePort`: every request is
 * JSON-encoded, size-checked, and handed off through the DOM to the
 * isolated-world relay script rather than ever touching
 * `window.webkit.messageHandlers` directly (which page-world script
 * cannot see in the first place — see the module doc comment above).
 *
 * `target` defaults to `document.documentElement`, which is both an
 * `Element` (for `setAttribute`/`removeAttribute`) and an `EventTarget`
 * (for `dispatchEvent`) — the same node `BridgeRelayUserScript` reads
 * from/dispatches to on the native side. Injectable purely for testing
 * without a real DOM.
 */
export function createDomRelayPort(
  target: DomRelayTarget = document.documentElement,
): BridgePort {
  return {
    postMessage(message): void {
      const serialized = JSON.stringify(message);
      const byteLength = utf8ByteLength(serialized);
      if (byteLength > DOM_RELAY_MAX_BYTES) {
        throw new DomRelayPayloadTooLargeError(byteLength);
      }

      target.setAttribute(DOM_RELAY_ATTRIBUTE, serialized);
      try {
        // A plain `Event`, deliberately not a `CustomEvent` — there is no
        // `detail` (or any other attacker-controlled object) carried on
        // the event itself. The payload travels exclusively through the
        // attribute above, which the isolated-world script reads back as
        // a string and nothing else.
        target.dispatchEvent(new Event(DOM_RELAY_EVENT_NAME, { bubbles: false }));
      } finally {
        // DOM event dispatch is synchronous, so by the time
        // `dispatchEvent` returns, `BridgeRelayUserScript`'s listener (if
        // registered) has already run and removed this attribute itself.
        // Removing it again here is a harmless no-op in that case, and is
        // the only cleanup at all if the isolated-world listener is not
        // present for any reason — either way, no payload is ever left
        // sitting on `target` for a later, unrelated event dispatch to
        // pick up and replay.
        target.removeAttribute(DOM_RELAY_ATTRIBUTE);
      }
    },
  };
}
