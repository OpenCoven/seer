import type {
  ActiveAgent,
  AgentActivitySource,
  AgentMonitorState,
  AgentUsage,
  AppSnapshot,
  AwakeSession,
  Diagnostic,
  HistoryStats,
  KeepAwakeMode,
  UpdateState,
} from "./types";

/**
 * Focused runtime schema guards for `AppSnapshot` and every nested shape it
 * carries over the standalone wire. These exist so the bridge never trusts a
 * native-host-supplied `result`/`snapshot.changed` payload just because it is
 * "an object" — every field, enum, optional, and nullable is checked, arrays
 * are rejected where an object is expected (and vice versa), and numbers must
 * be finite. No unsafe assertions (`as`) are used to bypass any of these
 * checks; every guard is a genuine `unknown`-narrowing type predicate.
 */

/**
 * Accepts only genuine plain objects: object literals (`Object.prototype`)
 * and objects created with `Object.create(null)`. Class instances and any
 * other custom-prototype object are rejected, since a native host payload
 * claiming to be e.g. an `AppSnapshot` must not be trusted just because
 * `typeof value === "object"` — that would also match arbitrary class
 * instances whose own fields happen to look right but whose prototype
 * carries untrusted behavior (or whose fields are actually inherited, not
 * own, via a crafted prototype chain).
 */
function isPlainObject(value: unknown): value is Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return false;
  }
  const proto = Object.getPrototypeOf(value) as object | null;
  return proto === Object.prototype || proto === null;
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function isString(value: unknown): value is string {
  return typeof value === "string";
}

function isBoolean(value: unknown): value is boolean {
  return typeof value === "boolean";
}

function isNullableFiniteNumber(value: unknown): value is number | null {
  return value === null || isFiniteNumber(value);
}

function isNullableString(value: unknown): value is string | null {
  return value === null || isString(value);
}

/**
 * Required-field helper: valid only if `key` is an *own* property of
 * `candidate` (via `Object.hasOwn`, never inherited through the prototype
 * chain) and its value passes `check`. Using `Object.hasOwn` instead of the
 * `in` operator or direct property access means a field only reachable via
 * `candidate`'s prototype (e.g. a crafted `Object.create(proto)` payload, or
 * prototype pollution on `Object.prototype` itself) is never mistaken for a
 * genuinely-present field.
 */
function isRequired<T>(
  candidate: Record<string, unknown>,
  key: string,
  check: (value: unknown) => value is T,
): boolean {
  return Object.hasOwn(candidate, key) && check(candidate[key]);
}

/**
 * Optional-field helper: valid if the key is not an *own* property of
 * `candidate` (an inherited/prototype-only value is treated as if the field
 * were absent, not read or validated), or if it is an own property and
 * passes `check`.
 */
function isOptional<T>(
  candidate: Record<string, unknown>,
  key: string,
  check: (value: unknown) => value is T,
): boolean {
  return !Object.hasOwn(candidate, key) || check(candidate[key]);
}

function isKeepAwakeMode(value: unknown): value is KeepAwakeMode {
  return value === "system" || value === "display";
}

function isAgentActivitySource(value: unknown): value is AgentActivitySource {
  return value === "process" || value === "session" || value === "both";
}

function isActiveAgent(value: unknown): value is ActiveAgent {
  if (!isPlainObject(value)) {
    return false;
  }
  return (
    isRequired(value, "id", isString) &&
    isRequired(value, "name", isString) &&
    isRequired(value, "detail", isString) &&
    isRequired(value, "source", isAgentActivitySource) &&
    isOptional(value, "pid", isFiniteNumber) &&
    isOptional(value, "cpuPercent", isFiniteNumber) &&
    isRequired(value, "lastActivityAt", isFiniteNumber)
  );
}

function isActiveAgentArray(value: unknown): value is ActiveAgent[] {
  return Array.isArray(value) && value.every(isActiveAgent);
}

function isAgentMonitorState(value: unknown): value is AgentMonitorState {
  if (!isPlainObject(value)) {
    return false;
  }
  return (
    isRequired(value, "active", isBoolean) &&
    isRequired(value, "keepingAwake", isBoolean) &&
    isRequired(value, "keepAwakeMode", isKeepAwakeMode) &&
    isRequired(value, "agents", isActiveAgentArray) &&
    isRequired(value, "lastScanAt", isFiniteNumber)
  );
}

function isAgentUsage(value: unknown): value is AgentUsage {
  if (!isPlainObject(value)) {
    return false;
  }
  return (
    isRequired(value, "id", isString) &&
    isRequired(value, "name", isString) &&
    isRequired(value, "durationMs", isFiniteNumber)
  );
}

function isAgentUsageArray(value: unknown): value is AgentUsage[] {
  return Array.isArray(value) && value.every(isAgentUsage);
}

function isAwakeSession(value: unknown): value is AwakeSession {
  if (!isPlainObject(value)) {
    return false;
  }
  return (
    isRequired(value, "id", isString) &&
    isRequired(value, "startedAt", isFiniteNumber) &&
    isRequired(value, "endedAt", isNullableFiniteNumber) &&
    isRequired(value, "durationMs", isFiniteNumber) &&
    isRequired(value, "mode", isKeepAwakeMode) &&
    isRequired(value, "agents", isAgentUsageArray)
  );
}

function isNullableAwakeSession(value: unknown): value is AwakeSession | null {
  return value === null || isAwakeSession(value);
}

function isAwakeSessionArray(value: unknown): value is AwakeSession[] {
  return Array.isArray(value) && value.every(isAwakeSession);
}

function isHistoryStats(value: unknown): value is HistoryStats {
  if (!isPlainObject(value)) {
    return false;
  }
  return (
    isRequired(value, "totalAwakeMs", isFiniteNumber) &&
    isRequired(value, "todayAwakeMs", isFiniteNumber) &&
    isRequired(value, "sessionCount", isFiniteNumber) &&
    isRequired(value, "perAgent", isAgentUsageArray) &&
    isRequired(value, "currentSession", isNullableAwakeSession) &&
    isRequired(value, "recentSessions", isAwakeSessionArray)
  );
}

function isUpdateState(value: unknown): value is UpdateState {
  if (!isPlainObject(value)) {
    return false;
  }
  return (
    isRequired(value, "checking", isBoolean) &&
    isRequired(value, "availableVersion", isNullableString) &&
    isRequired(value, "releaseURL", isNullableString) &&
    isRequired(value, "lastCheckedAt", isNullableFiniteNumber)
  );
}

function isDiagnostic(value: unknown): value is Diagnostic {
  if (!isPlainObject(value)) {
    return false;
  }
  return (
    isRequired(value, "id", isString) &&
    isRequired(value, "message", isString) &&
    isRequired(value, "occurredAt", isFiniteNumber)
  );
}

function isDiagnosticArray(value: unknown): value is Diagnostic[] {
  return Array.isArray(value) && value.every(isDiagnostic);
}

/** Validates a complete, well-formed `AppSnapshot` — rejects any partial/malformed shape. */
export function isAppSnapshot(value: unknown): value is AppSnapshot {
  if (!isPlainObject(value)) {
    return false;
  }
  return (
    isRequired(value, "monitor", isAgentMonitorState) &&
    isRequired(value, "history", isHistoryStats) &&
    isRequired(value, "update", isUpdateState) &&
    isRequired(value, "diagnostics", isDiagnosticArray) &&
    isRequired(value, "appVersion", isString)
  );
}
