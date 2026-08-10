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

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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

/** Optional-field helper: valid if the key is absent, or present and passes `check`. */
function isOptional<T>(
  candidate: Record<string, unknown>,
  key: string,
  check: (value: unknown) => value is T,
): boolean {
  return !(key in candidate) || check(candidate[key]);
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
    isString(value.id) &&
    isString(value.name) &&
    isString(value.detail) &&
    isAgentActivitySource(value.source) &&
    isOptional(value, "pid", isFiniteNumber) &&
    isOptional(value, "cpuPercent", isFiniteNumber) &&
    isFiniteNumber(value.lastActivityAt)
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
    isBoolean(value.active) &&
    isBoolean(value.keepingAwake) &&
    isKeepAwakeMode(value.keepAwakeMode) &&
    isActiveAgentArray(value.agents) &&
    isFiniteNumber(value.lastScanAt)
  );
}

function isAgentUsage(value: unknown): value is AgentUsage {
  if (!isPlainObject(value)) {
    return false;
  }
  return isString(value.id) && isString(value.name) && isFiniteNumber(value.durationMs);
}

function isAgentUsageArray(value: unknown): value is AgentUsage[] {
  return Array.isArray(value) && value.every(isAgentUsage);
}

function isAwakeSession(value: unknown): value is AwakeSession {
  if (!isPlainObject(value)) {
    return false;
  }
  return (
    isString(value.id) &&
    isFiniteNumber(value.startedAt) &&
    isNullableFiniteNumber(value.endedAt) &&
    isFiniteNumber(value.durationMs) &&
    isKeepAwakeMode(value.mode) &&
    isAgentUsageArray(value.agents)
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
    isFiniteNumber(value.totalAwakeMs) &&
    isFiniteNumber(value.todayAwakeMs) &&
    isFiniteNumber(value.sessionCount) &&
    isAgentUsageArray(value.perAgent) &&
    isNullableAwakeSession(value.currentSession) &&
    isAwakeSessionArray(value.recentSessions)
  );
}

function isUpdateState(value: unknown): value is UpdateState {
  if (!isPlainObject(value)) {
    return false;
  }
  return (
    isBoolean(value.checking) &&
    isNullableString(value.availableVersion) &&
    isNullableString(value.releaseURL) &&
    isNullableFiniteNumber(value.lastCheckedAt)
  );
}

function isDiagnostic(value: unknown): value is Diagnostic {
  if (!isPlainObject(value)) {
    return false;
  }
  return isString(value.id) && isString(value.message) && isFiniteNumber(value.occurredAt);
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
    isAgentMonitorState(value.monitor) &&
    isHistoryStats(value.history) &&
    isUpdateState(value.update) &&
    isDiagnosticArray(value.diagnostics) &&
    isString(value.appVersion)
  );
}
