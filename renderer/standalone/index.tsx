import "./styles.css";

import { createDomRelayPort } from "../bridge/dom-relay-port";
import { createStandaloneRendererBridge } from "../bridge/standalone-renderer-bridge";
import { BRIDGE_VERSION } from "../bridge/types";
import { mountApp } from "../main/app";

/**
 * The native host delivers responses/events by calling
 * `window.seerNative.receive` directly. This is the only global the
 * standalone entry point reads or writes on `Window` — there is
 * deliberately no `window.webkit`/`messageHandlers` access here:
 * `BridgeMessageHandler` is registered only in an isolated `WKContentWorld`
 * (see `BridgeContentWorld`/`BridgeMessageHandlerRegistration` in
 * `BridgeMessageHandler.swift`), so `window.webkit.messageHandlers
 * .seerBridge` is not visible to page-world script at all. Outbound
 * requests instead go through `createDomRelayPort`, which hands a
 * JSON-encoded string to a trusted isolated-world relay script via the DOM
 * (see `renderer/bridge/dom-relay-port.ts`).
 */
declare global {
  interface Window {
    seerNative?: {
      version: typeof BRIDGE_VERSION;
      receive(message: unknown): void;
    };
  }
}

const port = createDomRelayPort();

const bridge = createStandaloneRendererBridge(port);

// The native host delivers responses/events by calling this global directly
// (there is no generic invoke/IPC channel in the standalone build). Frozen
// so page code cannot be tricked into replacing it with something else.
window.seerNative = Object.freeze({
  version: BRIDGE_VERSION,
  receive(message: unknown) {
    bridge.receive(message);
  },
});

const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Root element not found");
}

const dispose = mountApp(rootElement, bridge);

// `pagehide` is real window teardown (not a React effect cleanup, which
// StrictMode can invoke without the window actually going away) — the only
// point where unmounting and disconnecting the bridge exactly once is
// correct for the standalone build.
window.addEventListener("pagehide", dispose);

