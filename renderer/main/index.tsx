import "../styles.css";

import { createGlazeRendererBridge } from "../bridge/glaze-renderer-bridge";
import { mountApp } from "./app";

declare const __APP_DISPLAY_NAME__: string | undefined;

document.title = __APP_DISPLAY_NAME__ || document.title;

// Get the root element
const rootElement = document.getElementById("root");
if (!rootElement) {
  throw new Error("Root element not found");
}

const bridge = createGlazeRendererBridge(window.glazeAPI.glaze.ipc);

mountApp(rootElement, bridge);

// Hot Module Replacement (HMR) support
if (import.meta.hot) {
  import.meta.hot.accept();
}
