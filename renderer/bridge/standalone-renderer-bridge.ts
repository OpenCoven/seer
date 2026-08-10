import type { RendererBridge } from "./renderer-bridge";
import { BRIDGE_VERSION, type AppSnapshot, type KeepAwakeMode } from "./types";

/** Closed set of methods the standalone native host understands. */
export type BridgeMethod =
  | "snapshot.get"
  | "keepAwakeMode.set"
  | "history.clear"
  | "updates.check"
  | "updates.open"
  | "app.quit";

/** Minimal transport this adapter needs — a `window.seerNative`-shaped port. */
export interface BridgePort {
  postMessage(message: unknown): void;
}

/** Error payload sent back by the native host for a failed request. */
export interface NativeBridgeErrorPayload {
  code: string;
  message: string;
}

interface BridgeRequest<TPayload = unknown> {
  id: string;
  version: typeof BRIDGE_VERSION;
  method: BridgeMethod;
  payload: TPayload;
}

interface BridgeSuccessResponse {
  id: string;
  version: typeof BRIDGE_VERSION;
  kind: "response";
  ok: true;
  result: unknown;
}

interface BridgeErrorResponse {
  id: string;
  version: typeof BRIDGE_VERSION;
  kind: "response";
  ok: false;
  error: NativeBridgeErrorPayload;
}

type BridgeResponse = BridgeSuccessResponse | BridgeErrorResponse;

interface BridgeSnapshotChangedEvent {
  version: typeof BRIDGE_VERSION;
  kind: "event";
  type: "snapshot.changed";
  snapshot: AppSnapshot;
}

type BridgeInboundMessage = BridgeResponse | BridgeSnapshotChangedEvent;

/** Injectable timer so timeout behavior is testable without waiting 10s. */
export interface BridgeScheduler {
  setTimeout(handler: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

const defaultScheduler: BridgeScheduler = {
  setTimeout: (handler, ms) => setTimeout(handler, ms),
  clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
};

const REQUEST_TIMEOUT_MS = 10_000;

/** Thrown when the native host reports a typed error for a request. */
export class NativeBridgeRequestError extends Error {
  readonly code: string;

  constructor(error: NativeBridgeErrorPayload) {
    super(error.message);
    this.name = "NativeBridgeRequestError";
    this.code = error.code;
  }
}

interface PendingRequest {
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
  timeoutHandle: unknown;
}

export interface StandaloneRendererBridge extends RendererBridge {
  /** Feed an inbound postMessage payload from the native host into the bridge. */
  receive(message: unknown): void;
}

function isBridgeInboundMessage(message: unknown): message is BridgeInboundMessage {
  return (
    typeof message === "object" &&
    message !== null &&
    "version" in message &&
    (message as { version: unknown }).version === BRIDGE_VERSION &&
    "kind" in message
  );
}

/**
 * Builds the standalone RendererBridge transport: requests are posted through
 * `port.postMessage` with a `crypto.randomUUID()` id, BRIDGE_VERSION, method,
 * and payload; responses/events are fed back in via `receive`. No global is
 * exposed here — Task 3's entry point wires `window.seerNative` to this port.
 */
export function createStandaloneRendererBridge(
  port: BridgePort,
  scheduler: BridgeScheduler = defaultScheduler,
): StandaloneRendererBridge {
  const pending = new Map<string, PendingRequest>();
  const listeners = new Set<(snapshot: AppSnapshot) => void>();

  function send<TPayload>(method: BridgeMethod, payload: TPayload): Promise<unknown> {
    const id = crypto.randomUUID();
    const request: BridgeRequest<TPayload> = {
      id,
      version: BRIDGE_VERSION,
      method,
      payload,
    };

    return new Promise((resolve, reject) => {
      const timeoutHandle = scheduler.setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Bridge request timed out after ${REQUEST_TIMEOUT_MS}ms: ${method}`));
      }, REQUEST_TIMEOUT_MS);

      pending.set(id, { resolve, reject, timeoutHandle });
      port.postMessage(request);
    });
  }

  function receive(message: unknown): void {
    if (!isBridgeInboundMessage(message)) {
      return;
    }

    if (message.kind === "event") {
      if (message.type === "snapshot.changed") {
        for (const listener of listeners) {
          listener(message.snapshot);
        }
      }
      return;
    }

    const request = pending.get(message.id);
    if (!request) {
      // Unknown or duplicate response id — ignore.
      return;
    }

    pending.delete(message.id);
    scheduler.clearTimeout(request.timeoutHandle);

    if (message.ok) {
      request.resolve(message.result);
    } else {
      request.reject(new NativeBridgeRequestError(message.error));
    }
  }

  return {
    async getSnapshot(): Promise<AppSnapshot> {
      return (await send("snapshot.get", undefined)) as AppSnapshot;
    },

    async setKeepAwakeMode(mode: KeepAwakeMode): Promise<AppSnapshot> {
      return (await send("keepAwakeMode.set", { mode })) as AppSnapshot;
    },

    async clearHistory(): Promise<AppSnapshot> {
      return (await send("history.clear", undefined)) as AppSnapshot;
    },

    subscribe(listener: (snapshot: AppSnapshot) => void): () => void {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },

    async requestUpdateCheck(): Promise<AppSnapshot> {
      return (await send("updates.check", undefined)) as AppSnapshot;
    },

    async openCurrentRelease(): Promise<void> {
      await send("updates.open", undefined);
    },

    async quit(): Promise<void> {
      await send("app.quit", undefined);
    },

    disconnect(): void {
      for (const request of pending.values()) {
        scheduler.clearTimeout(request.timeoutHandle);
      }
      pending.clear();
      listeners.clear();
    },

    receive,
  };
}
