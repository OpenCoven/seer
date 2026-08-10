import "./styles.css";

import type { BridgePort } from "../bridge/standalone-renderer-bridge";
import { createStandaloneRendererBridge } from "../bridge/standalone-renderer-bridge";
import { BRIDGE_VERSION } from "../bridge/types";
import { mountApp } from "../main/app";

/**
 * The standalone native host is a WKWebView. It exposes a `postMessage`-only
 * script message handler (no generic `invoke`/IPC surface) — this is the
 * only global the standalone entry point may read.
 */
declare global {
  interface Window {
    webkit?: {
      messageHandlers?: {
        seerBridge?: {
          postMessage(message: unknown): void;
        };
      };
    };
    seerNative?: {
      version: typeof BRIDGE_VERSION;
      receive(message: unknown): void;
    };
  }
}

const handler = window.webkit?.messageHandlers?.seerBridge;
if (!handler) {
  throw new Error("window.webkit.messageHandlers.seerBridge is not available");
}

const port: BridgePort = {
  postMessage: (message) => handler.postMessage(message),
};

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

mountApp(rootElement, bridge);
