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
 * for the lifetime of the window.
 */
function syncDarkMode(): void {
  const media = window.matchMedia("(prefers-color-scheme: dark)");
  const apply = (matches: boolean) => {
    document.documentElement.classList.toggle("dark", matches);
  };
  apply(media.matches);
  media.addEventListener("change", (event) => apply(event.matches));
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
 */
export function mountApp(rootElement: HTMLElement, bridge: RendererBridge): ReactDOM.Root {
  syncDarkMode();

  const root = ReactDOM.createRoot(rootElement);
  root.render(
    <React.StrictMode>
      <App bridge={bridge} />
    </React.StrictMode>,
  );
  return root;
}
