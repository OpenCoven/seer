import { logger, powerSaveBlocker } from "@glaze/core/backend";

import type { KeepAwakeMode } from "./types.js";

function blockerTypeForMode(mode: KeepAwakeMode): "prevent-app-suspension" | "prevent-display-sleep" {
  return mode === "display" ? "prevent-display-sleep" : "prevent-app-suspension";
}

class KeepAwakeService {
  private blockerId: number | null = null;
  private mode: KeepAwakeMode = "system";

  isActive(): boolean {
    return this.blockerId !== null && powerSaveBlocker.isStarted(this.blockerId);
  }

  getMode(): KeepAwakeMode {
    return this.mode;
  }

  setMode(mode: KeepAwakeMode): void {
    if (this.mode === mode) return;
    this.mode = mode;
    if (this.isActive()) {
      this.restart();
    }
  }

  setDesired(active: boolean): void {
    if (active) {
      this.start();
    } else {
      this.stop();
    }
  }

  private start(): void {
    if (this.isActive()) return;

    // Clear a stale id if the native blocker already ended.
    if (this.blockerId !== null) {
      this.blockerId = null;
    }

    const type = blockerTypeForMode(this.mode);
    this.blockerId = powerSaveBlocker.start(type);
    logger.info("keep-awake", "Started power save blocker", {
      id: this.blockerId,
      type,
      mode: this.mode,
    });
  }

  private stop(): void {
    if (this.blockerId === null) return;

    if (powerSaveBlocker.isStarted(this.blockerId)) {
      powerSaveBlocker.stop(this.blockerId);
      logger.info("keep-awake", "Stopped power save blocker", { id: this.blockerId });
    }

    this.blockerId = null;
  }

  private restart(): void {
    this.stop();
    this.start();
  }

  dispose(): void {
    this.stop();
  }
}

export const keepAwakeService = new KeepAwakeService();
