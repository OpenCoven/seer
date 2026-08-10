import type { RendererBridge } from "./renderer-bridge";
import { isAppSnapshot } from "./standalone-wire-schema";
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

/**
 * A success response envelope. Note there is deliberately no `method` field:
 * the response is correlated to its request purely by `id`, and the expected
 * `result` shape is validated using the decoder stored on that `id`'s pending
 * request (see `PendingRequest.decode` / `resultDecoders`) rather than by
 * trusting a method name the native host could echo back incorrectly.
 * `result` stays `unknown` at this envelope layer — it is decoded/validated
 * per-request in `receive` before ever being handed to calling code.
 */
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

/**
 * Thrown to reject every request still pending when `disconnect()` is
 * called. Distinct from a timeout or a native-host-reported error: the
 * request was never actually settled by the native host, it was aborted
 * locally because this bridge is shutting down.
 */
export class NativeBridgeDisconnectedError extends Error {
  constructor(method: BridgeMethod) {
    super(`Bridge request for method "${method}" was aborted because the bridge disconnected`);
    this.name = "NativeBridgeDisconnectedError";
  }
}

/**
 * Thrown when a response's `result` does not decode into the shape the
 * pending request expects (e.g. a malformed/partial `AppSnapshot`, or a
 * non-null result for a void method). This is distinct from
 * `NativeBridgeRequestError`, which represents a typed error the native host
 * itself reported — this error means the native host sent a *success*
 * response whose payload we cannot trust.
 */
export class NativeBridgeProtocolError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "NativeBridgeProtocolError";
  }
}

/** Outcome of decoding a raw `result` value against a pending request's expected shape. */
type DecodeResult<T> = { ok: true; value: T } | { ok: false };

interface PendingRequest<T = unknown> {
  /** The method this request was sent for — used for timeout/disconnect error messages. */
  method: BridgeMethod;
  /** Validates/decodes a raw `result` value into this request's expected result type. */
  decode: (result: unknown) => DecodeResult<T>;
  resolve: (value: T) => void;
  reject: (error: unknown) => void;
  timeoutHandle: unknown;
}

/**
 * Wire convention for void-returning methods (`updates.open`, `app.quit`):
 * a successful response's `result` must be exactly `null` — not `undefined`,
 * not an object, not absent. `null` is chosen (over an absent/`undefined`
 * field) for JSON interoperability, since `undefined` cannot round-trip
 * through JSON. Both the implementation and its tests treat this as the one
 * valid encoding of "no result".
 */
function decodeVoidResult(result: unknown): DecodeResult<void> {
  return result === null ? { ok: true, value: undefined } : { ok: false };
}

function decodeAppSnapshotResult(result: unknown): DecodeResult<AppSnapshot> {
  return isAppSnapshot(result) ? { ok: true, value: result } : { ok: false };
}

/** Per-method result decoder, selected by `send` based on the method being called. */
const resultDecoders: {
  [M in BridgeMethod]: (result: unknown) => DecodeResult<BridgeMethodResultMap[M]>;
} = {
  "snapshot.get": decodeAppSnapshotResult,
  "keepAwakeMode.set": decodeAppSnapshotResult,
  "history.clear": decodeAppSnapshotResult,
  "updates.check": decodeAppSnapshotResult,
  "updates.open": decodeVoidResult,
  "app.quit": decodeVoidResult,
};

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
    isAppSnapshot(candidate.snapshot)
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
  const pending = new Map<string, PendingRequest<unknown>>();
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

    // Stored on the pending entry so `receive` can validate/decode a
    // response's `result` against exactly the shape this call expects,
    // without the response itself needing to carry a `method` field.
    const decode = resultDecoders[method] as (result: unknown) => DecodeResult<
      BridgeMethodResultMap[M]
    >;

    return new Promise((resolve, reject) => {
      const timeoutHandle = scheduler.setTimeout(() => {
        pending.delete(id);
        reject(new Error(`Bridge request timed out after ${REQUEST_TIMEOUT_MS}ms: ${method}`));
      }, REQUEST_TIMEOUT_MS);

      pending.set(id, {
        method,
        decode: decode as (result: unknown) => DecodeResult<unknown>,
        resolve: resolve as (value: unknown) => void,
        reject,
        timeoutHandle,
      });

      try {
        port.postMessage(request);
      } catch (error) {
        // `postMessage` failed synchronously (e.g. the native transport
        // channel is already closed). The pending entry and its timer must
        // not be left dangling — remove/clear them here and reject this
        // call's own promise instead of leaking a request that will never
        // be correlated to a response.
        pending.delete(id);
        scheduler.clearTimeout(timeoutHandle);
        reject(
          new NativeBridgeProtocolError(
            `Bridge failed to send request for method "${method}": ${
              error instanceof Error ? error.message : String(error)
            }`,
          ),
        );
      }
    });
  }

  function receive(message: unknown): void {
    if (typeof message !== "object" || message === null) {
      return;
    }
    const candidate = message as Record<string, unknown>;

    if (candidate.kind === "event") {
      if (isBridgeInboundMessage(message) && message.kind === "event") {
        // isBridgeInboundMessage already validated message.snapshot is a
        // complete AppSnapshot via isAppSnapshot — malformed events never
        // reach here, so subscribers are never notified with a bad shape.
        // Each listener gets its own deep clone: no listener-owned object
        // is retained/shared here, so one listener mutating its delivered
        // snapshot can never affect another listener or a later delivery.
        for (const listener of listeners) {
          listener(structuredClone(message.snapshot));
        }
      }
      return;
    }

    // Correlate by the message's own string id *before* validating the rest
    // of the envelope. This way a malformed response for a *known* pending
    // request fails that request immediately instead of silently being
    // ignored and left to time out ten seconds later. Unknown ids (no
    // matching pending request) are still ignored either way.
    if (typeof candidate.id !== "string") {
      return;
    }

    const request = pending.get(candidate.id);
    if (!request) {
      // Unknown or duplicate response id — ignore.
      return;
    }

    if (!isBridgeInboundMessage(message) || message.kind !== "response") {
      pending.delete(candidate.id);
      scheduler.clearTimeout(request.timeoutHandle);
      request.reject(
        new NativeBridgeProtocolError(
          `Bridge response envelope for request ${candidate.id} was malformed`,
        ),
      );
      return;
    }

    pending.delete(message.id);
    scheduler.clearTimeout(request.timeoutHandle);

    if (!message.ok) {
      request.reject(new NativeBridgeRequestError(message.error));
      return;
    }

    const decoded = request.decode(message.result);
    if (!decoded.ok) {
      request.reject(
        new NativeBridgeProtocolError(
          `Bridge response result for request ${message.id} did not match the expected shape`,
        ),
      );
      return;
    }

    request.resolve(decoded.value);
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
        request.reject(new NativeBridgeDisconnectedError(request.method));
      }
      pending.clear();
      listeners.clear();
    },

    receive,
  };
}
