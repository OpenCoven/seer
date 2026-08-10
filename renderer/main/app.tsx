import * as React from "react";
import ReactDOM from "react-dom/client";
import { QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider } from "@tanstack/react-router";

import { RendererBridgeProvider } from "../bridge/renderer-bridge-context";
import type { RendererBridge } from "../bridge/renderer-bridge";
import { queryClient, router } from "./router";

/**
 * Keeps `html.dark` synchronized with the OS appearance. Applied
 * synchronously (not inside a React effect) so the very first paint already
 * reflects the current appearance instead of flashing light-then-dark.
 * Registers a `change` listener so later OS appearance switches keep working
 * for the lifetime of the window, and returns a cleanup function that
 * removes that exact listener (not a new closure) so the caller can tear it
 * down deterministically without leaking it for the life of the page.
 */
export function syncDarkMode(): () => void {
  const media = window.matchMedia("(prefers-color-scheme: dark)");
  const apply = (matches: boolean) => {
    document.documentElement.classList.toggle("dark", matches);
  };
  const onChange = (event: MediaQueryListEvent) => apply(event.matches);

  apply(media.matches);
  media.addEventListener("change", onChange);

  return () => {
    media.removeEventListener("change", onChange);
  };
}

function App({ bridge }: { bridge: RendererBridge }) {
  return (
    <RendererBridgeProvider bridge={bridge}>
      <QueryClientProvider client={queryClient}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    </RendererBridgeProvider>
  );
}

/**
 * Shared mount entry point for both the Glaze panel and the standalone macOS
 * window. Each entry point is responsible for creating the `RendererBridge`
 * that matches its host (Glaze IPC or the standalone native `postMessage`
 * transport) and passing it in here — this function and everything it
 * renders is host-agnostic.
 *
 * Returns an explicit `dispose()` function rather than disconnecting the
 * bridge from a component's effect cleanup: React (particularly
 * `StrictMode`, which mounts/unmounts every component twice in development
 * to surface effect-cleanup bugs) can invoke effect cleanups without this
 * being a real, final teardown, and a bridge disconnected that way would
 * reject every in-flight/future request and drop live subscriptions out
 * from under a component that is about to remount. `dispose()` unmounts the
 * React root and then disconnects the bridge exactly once — callers must
 * only invoke it on real teardown (e.g. `pagehide`, or a module's HMR
 * `dispose` callback), never from component lifecycle.
 */
export function mountApp(rootElement: HTMLElement, bridge: RendererBridge): () => void {
  const stopSyncingDarkMode = syncDarkMode();

  const root = ReactDOM.createRoot(rootElement);
  root.render(
    <React.StrictMode>
      <App bridge={bridge} />
    </React.StrictMode>,
  );

  let disposed = false;
  return function dispose(): void {
    if (disposed) {
      return;
    }
    disposed = true;
    stopSyncingDarkMode();
    root.unmount();
    bridge.disconnect();
  };
}
