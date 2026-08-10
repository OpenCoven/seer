import type { AppSnapshot, KeepAwakeMode } from "./types";

/**
 * Transport-agnostic contract views/hooks depend on. Both the Glaze IPC
 * adapter and the standalone postMessage transport implement this exact
 * shape so entry points can inject either one without renderer code caring
 * which host it is running under.
 */
export interface RendererBridge {
  getSnapshot(): Promise<AppSnapshot>;
  setKeepAwakeMode(mode: KeepAwakeMode): Promise<AppSnapshot>;
  clearHistory(): Promise<AppSnapshot>;
  subscribe(listener: (snapshot: AppSnapshot) => void): () => void;
  requestUpdateCheck(): Promise<AppSnapshot>;
  openCurrentRelease(): Promise<void>;
  quit(): Promise<void>;
  /** Hides the panel window. The product-level operation behind Escape. */
  hidePanel(): Promise<void>;
  disconnect(): void;
}
