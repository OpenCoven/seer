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

/** Error payload sent back by the native host for a failed request. */
export interface NativeBridgeErrorPayload {
  code: string;
  message: string;
}

/** Per-method request payload shapes. Parameterless methods carry `{}`. */
interface BridgeMethodPayloadMap {
  "snapshot.get": Record<string, never>;
  "keepAwakeMode.set": { mode: KeepAwakeMode };
  "history.clear": Record<string, never>;
  "updates.check": Record<string, never>;
  "updates.open": Record<string, never>;
  "app.quit": Record<string, never>;
}

/** Per-method result shapes returned inside a successful response. */
interface BridgeMethodResultMap {
  "snapshot.get": AppSnapshot;
  "keepAwakeMode.set": AppSnapshot;
  "history.clear": AppSnapshot;
  "updates.check": AppSnapshot;
  "updates.open": void;
  "app.quit": void;
}

/**
 * Closed discriminated union of every request shape this adapter can send,
 * one member per `BridgeMethod`, each with its own `payload` type. There is
 * no `unknown`/generic-default payload — every method's wire shape is fully
 * known at compile time.
 */
type BridgeRequest = {
  [M in BridgeMethod]: {
    id: string;
    version: typeof BRIDGE_VERSION;
    method: M;
    payload: BridgeMethodPayloadMap[M];
  };
}[BridgeMethod];

/** Minimal transport this adapter needs — a `window.seerNative`-shaped port. */
export interface BridgePort {
  postMessage(message: BridgeRequest): void;
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

/**
 * Closed discriminated union of every inbound message shape `receive` can be
 * fed: a response (success or error, keyed on `ok`) or a known event (keyed
 * on `type`). `receive` still accepts `unknown` at its boundary and narrows
 * down to this union via a runtime guard, so malformed/unrecognized
 * postMessage payloads from the native host are defensively ignored instead
 * of widening this contract.
 */
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

function isBridgeSuccessResponse(candidate: Record<string, unknown>): boolean {
  return (
    candidate.kind === "response" &&
    typeof candidate.id === "string" &&
    candidate.ok === true &&
    "result" in candidate
  );
}

function isBridgeErrorResponse(candidate: Record<string, unknown>): boolean {
  if (candidate.kind !== "response" || typeof candidate.id !== "string" || candidate.ok !== false) {
    return false;
  }
  const error = candidate.error as Partial<NativeBridgeErrorPayload> | undefined;
  return (
    typeof error === "object" &&
    error !== null &&
    typeof error.code === "string" &&
    typeof error.message === "string"
  );
}

function isBridgeSnapshotChangedEvent(candidate: Record<string, unknown>): boolean {
  return (
    candidate.kind === "event" &&
    candidate.type === "snapshot.changed" &&
    typeof candidate.snapshot === "object" &&
    candidate.snapshot !== null
  );
}

/**
 * Runtime guard narrowing an arbitrary inbound postMessage payload down to
 * the closed `BridgeInboundMessage` union. Every field required by the
 * discriminant (`kind`, then `ok`/`type`) is checked, so malformed or
 * unrecognized messages from the native host are ignored rather than
 * crashing the renderer or being (mis)trusted as one of the known shapes.
 */
function isBridgeInboundMessage(message: unknown): message is BridgeInboundMessage {
  if (typeof message !== "object" || message === null) {
    return false;
  }

  const candidate = message as Record<string, unknown>;
  if (candidate.version !== BRIDGE_VERSION) {
    return false;
  }

  switch (candidate.kind) {
    case "response":
      return isBridgeSuccessResponse(candidate) || isBridgeErrorResponse(candidate);
    case "event":
      return isBridgeSnapshotChangedEvent(candidate);
    default:
      return false;
  }
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

  function send<M extends BridgeMethod>(
    method: M,
    payload: BridgeMethodPayloadMap[M],
  ): Promise<BridgeMethodResultMap[M]> {
    const id = crypto.randomUUID();
    // TypeScript cannot verify that a generic `{ method: M; payload:
    // BridgeMethodPayloadMap[M] }` matches the mapped-union `BridgeRequest`
    // without narrowing on the literal `M`, even though every call site is
    // statically well-typed (method/payload always agree via the map). The
    // cast is safe by construction.
    const request = {
      id,
      version: BRIDGE_VERSION,
      method,
      payload,
    } as BridgeRequest;

    return new Promise((resolve, reject) => {
      const timeoutHandle = scheduler.setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Bridge request timed out after ${REQUEST_TIMEOUT_MS}ms: ${method}`));
      }, REQUEST_TIMEOUT_MS);

      pending.set(id, {
        resolve: resolve as (value: unknown) => void,
        reject,
        timeoutHandle,
      });
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
      return await send("snapshot.get", {});
    },

    async setKeepAwakeMode(mode: KeepAwakeMode): Promise<AppSnapshot> {
      return await send("keepAwakeMode.set", { mode });
    },

    async clearHistory(): Promise<AppSnapshot> {
      return await send("history.clear", {});
    },

    subscribe(listener: (snapshot: AppSnapshot) => void): () => void {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },

    async requestUpdateCheck(): Promise<AppSnapshot> {
      return await send("updates.check", {});
    },

    async openCurrentRelease(): Promise<void> {
      await send("updates.open", {});
    },

    async quit(): Promise<void> {
      await send("app.quit", {});
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
