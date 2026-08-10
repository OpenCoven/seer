import { createContext, useContext, type ReactNode } from "react";

import type { RendererBridge } from "./renderer-bridge";

const RendererBridgeContext = createContext<RendererBridge | null>(null);

export function RendererBridgeProvider({
  bridge,
  children,
}: {
  bridge: RendererBridge;
  children: ReactNode;
}) {
  return <RendererBridgeContext.Provider value={bridge}>{children}</RendererBridgeContext.Provider>;
}

export function useRendererBridge(): RendererBridge {
  const bridge = useContext(RendererBridgeContext);
  if (!bridge) {
    throw new Error("RendererBridgeProvider is missing");
  }
  return bridge;
}
