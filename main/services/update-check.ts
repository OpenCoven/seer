import type { UpdateState } from "./types.js";

export const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1_000;

// Seer's release feed lives in the dedicated public releases repository
// (`OpenCoven/seer-releases`), never the main `OpenCoven/seer` source
// repository, which never has its own GitHub releases published against it.
const STABLE_URL = "https://api.github.com/repos/OpenCoven/seer-releases/releases/latest";
const PRERELEASE_URL = "https://api.github.com/repos/OpenCoven/seer-releases/releases?per_page=20";

// A single dot-separated pre-release identifier. Per the SemVer spec, an
// identifier composed entirely of digits (and not empty) is compared
// numerically; any identifier containing a letter or hyphen is compared as
// a string, and always sorts *after* every numeric identifier regardless
// of its own text. `digits` is the identifier's normalized decimal digit
// string (no leading zero unless the identifier is exactly `"0"`) rather
// than a `number` — SemVer places no upper bound on how large a numeric
// identifier may be, and `number` cannot exactly represent every integer
// beyond `Number.MAX_SAFE_INTEGER` (2^53 - 1).
type PrereleaseIdentifier = { readonly kind: "numeric"; readonly digits: string } | { readonly kind: "alphanumeric"; readonly value: string };

export type SemanticVersion = {
  // Each of `major`/`minor`/`patch` is stored as its normalized decimal
  // digit string (no leading zero unless the component is exactly `"0"`)
  // rather than a `number`, for the same overflow-independence reason as
  // `PrereleaseIdentifier.digits` above. `compareNumericStrings` compares
  // these (and numeric pre-release identifiers) without ever converting
  // to `number`.
  major: string;
  minor: string;
  patch: string;
  prerelease: PrereleaseIdentifier[];
};

export type UpdateSettings = {
  includePrereleaseUpdates: boolean;
};

export type UpdateSettingsAccess = {
  get(): UpdateSettings;
  setIncludePrereleaseUpdates(value: boolean): Promise<UpdateSettings>;
};

type UpdateServiceOptions = {
  currentVersion: string;
  fetchImpl?: typeof fetch;
  now?: () => number;
  settings: UpdateSettingsAccess;
  openExternal: (url: string) => Promise<void>;
};

type GitHubRelease = {
  tag_name: string;
  html_url: string;
  draft: boolean;
  prerelease: boolean;
};

type ValidRelease = {
  tag: string;
  url: string;
  version: SemanticVersion;
};

export class UpdateCheckError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UpdateCheckError";
  }
}

/// Compares two normalized (no leading zero, unless exactly `"0"`) decimal
/// digit strings as arbitrarily large non-negative integers — used for
/// `major`/`minor`/`patch` and numeric pre-release identifiers alike —
/// without ever converting either one to `number`. Because leading zeros
/// are already disallowed at parse time, a longer digit string is always
/// numerically larger regardless of its digits, so comparing by length
/// first and then lexicographically (equal-length decimal digit strings
/// compare identically either way) is exactly equivalent to numeric
/// comparison, for numbers of any magnitude.
function compareNumericStrings(left: string, right: string): -1 | 0 | 1 {
  if (left.length !== right.length) return left.length < right.length ? -1 : 1;
  if (left === right) return 0;
  return left < right ? -1 : 1;
}

function parseIdentifiers(raw: string, numericLeadingZerosAreInvalid: boolean): PrereleaseIdentifier[] | null {
  const parts = raw.split(".");
  if (parts.length === 0 || parts.some((part) => part.length === 0 || !/^[0-9A-Za-z-]+$/.test(part))) {
    return null;
  }

  const identifiers: PrereleaseIdentifier[] = [];
  for (const part of parts) {
    if (/^\d+$/.test(part)) {
      if (numericLeadingZerosAreInvalid && part.length > 1 && part.startsWith("0")) return null;
      identifiers.push({ kind: "numeric", digits: part });
    } else {
      identifiers.push({ kind: "alphanumeric", value: part });
    }
  }
  return identifiers;
}

export function parseSemanticVersion(raw: string): SemanticVersion | null {
  let text = raw;
  if (text.startsWith("v") || text.startsWith("V")) text = text.slice(1);

  const plusParts = text.split("+");
  if (plusParts.length > 2) return null;
  if (plusParts.length === 2 && parseIdentifiers(plusParts[1]!, false) === null) return null;

  const versionPart = plusParts[0]!;
  const dashIndex = versionPart.indexOf("-");
  const core = dashIndex === -1 ? versionPart : versionPart.slice(0, dashIndex);
  const prereleaseRaw = dashIndex === -1 ? null : versionPart.slice(dashIndex + 1);
  const coreParts = core.split(".");
  if (coreParts.length !== 3) return null;

  // Normalized decimal digit strings, never converted to `number` — a
  // core numeric component may validly exceed `Number.MAX_SAFE_INTEGER`.
  const numbers = coreParts.map((part) => (/^(0|[1-9]\d*)$/.test(part) ? part : null));
  if (numbers.some((part) => part === null)) return null;

  const prerelease = prereleaseRaw === null ? [] : parseIdentifiers(prereleaseRaw, true);
  if (prerelease === null) return null;

  return {
    major: numbers[0]!,
    minor: numbers[1]!,
    patch: numbers[2]!,
    prerelease,
  };
}

export function compareSemanticVersions(left: SemanticVersion, right: SemanticVersion): -1 | 0 | 1 {
  for (const key of ["major", "minor", "patch"] as const) {
    const order = compareNumericStrings(left[key], right[key]);
    if (order !== 0) return order;
  }

  if (left.prerelease.length === 0 && right.prerelease.length === 0) return 0;
  if (left.prerelease.length === 0) return 1;
  if (right.prerelease.length === 0) return -1;

  const length = Math.max(left.prerelease.length, right.prerelease.length);
  for (let index = 0; index < length; index += 1) {
    const leftPart = left.prerelease[index];
    const rightPart = right.prerelease[index];
    if (leftPart === undefined) return -1;
    if (rightPart === undefined) return 1;
    if (leftPart.kind === "numeric" && rightPart.kind === "numeric") {
      const order = compareNumericStrings(leftPart.digits, rightPart.digits);
      if (order !== 0) return order;
      continue;
    }
    if (leftPart.kind === "numeric" && rightPart.kind === "alphanumeric") return -1;
    if (leftPart.kind === "alphanumeric" && rightPart.kind === "numeric") return 1;
    if (leftPart.kind === "alphanumeric" && rightPart.kind === "alphanumeric") {
      if (leftPart.value === rightPart.value) continue;
      return leftPart.value < rightPart.value ? -1 : 1;
    }
  }
  return 0;
}

export function isAllowedReleaseURL(raw: string): boolean {
  try {
    const url = new URL(raw);
    return url.protocol === "https:" && url.hostname === "github.com";
  } catch {
    return false;
  }
}

function decodeRelease(value: unknown): GitHubRelease | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  if (
    typeof record.tag_name !== "string" ||
    typeof record.html_url !== "string" ||
    typeof record.draft !== "boolean" ||
    typeof record.prerelease !== "boolean"
  ) {
    return null;
  }
  return record as GitHubRelease;
}

function selectBestRelease(values: unknown[], includePrerelease: boolean): ValidRelease | null {
  let best: ValidRelease | null = null;
  for (const value of values) {
    const release = decodeRelease(value);
    if (!release || release.draft || (!includePrerelease && release.prerelease)) continue;
    const version = parseSemanticVersion(release.tag_name);
    if (!version || !isAllowedReleaseURL(release.html_url)) continue;
    if (!best || compareSemanticVersions(version, best.version) > 0) {
      best = { tag: release.tag_name, url: release.html_url, version };
    }
  }
  return best;
}

export class UpdateService {
  private readonly currentVersion: SemanticVersion;
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => number;
  private readonly settings: UpdateSettingsAccess;
  private readonly openExternal: (url: string) => Promise<void>;
  private readonly listeners = new Set<(state: UpdateState) => void>();
  private state: UpdateState = {
    checking: false,
    availableVersion: null,
    releaseURL: null,
    lastCheckedAt: null,
  };
  private etag: string | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private started = false;
  private lastAttemptCompletedAt: number | null = null;

  constructor(options: UpdateServiceOptions) {
    this.currentVersion = parseSemanticVersion(options.currentVersion) ?? {
      major: "0",
      minor: "0",
      patch: "0",
      prerelease: [],
    };
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.now = options.now ?? Date.now;
    this.settings = options.settings;
    this.openExternal = options.openExternal;
  }

  getState(): UpdateState {
    return { ...this.state };
  }

  includesPrereleaseUpdates(): boolean {
    return this.settings.get().includePrereleaseUpdates;
  }

  subscribe(listener: (state: UpdateState) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private publish(): void {
    const snapshot = this.getState();
    for (const listener of this.listeners) listener(snapshot);
  }

  async check(options: { force?: boolean } = {}): Promise<UpdateState> {
    const startedAt = this.now();
    if (
      !options.force &&
      this.state.lastCheckedAt !== null &&
      startedAt - this.state.lastCheckedAt < CHECK_INTERVAL_MS
    ) {
      return this.getState();
    }

    const includePrerelease = this.settings.get().includePrereleaseUpdates;
    const headers: Record<string, string> = {
      Accept: "application/vnd.github+json",
      "User-Agent": "Seer/1.0.0",
    };
    if (this.etag) headers["If-None-Match"] = this.etag;

    this.state = { ...this.state, checking: true };
    this.publish();
    try {
      let response: Response;
      try {
        response = await this.fetchImpl(includePrerelease ? PRERELEASE_URL : STABLE_URL, {
          method: "GET",
          headers,
        });
      } catch (error) {
        throw new UpdateCheckError(`Unable to check for updates: ${error instanceof Error ? error.message : "network error"}`);
      }

      const completedAt = this.now();
      if (response.status === 304) {
        this.state = { ...this.state, checking: false, lastCheckedAt: completedAt };
        this.publish();
        return this.getState();
      }
      if (!response.ok) {
        throw new UpdateCheckError(`Update check returned HTTP ${response.status}`);
      }

      let payload: unknown;
      try {
        payload = await response.json();
      } catch (error) {
        throw new UpdateCheckError(
          `GitHub returned an invalid release response: ${error instanceof Error ? error.message : "invalid JSON"}`,
        );
      }
      const values = includePrerelease ? (Array.isArray(payload) ? payload : null) : [payload];
      if (values === null || (!includePrerelease && decodeRelease(payload) === null)) {
        throw new UpdateCheckError("GitHub returned an invalid release response");
      }

      const best = selectBestRelease(values, includePrerelease);
      const isNewer = best !== null && compareSemanticVersions(this.currentVersion, best.version) < 0;
      this.etag = response.headers.get("etag");
      this.state = {
        checking: false,
        availableVersion: isNewer ? best.tag : null,
        releaseURL: isNewer ? best.url : null,
        lastCheckedAt: this.now(),
      };
      this.publish();
      return this.getState();
    } finally {
      this.lastAttemptCompletedAt = this.now();
      if (this.state.checking) {
        this.state = { ...this.state, checking: false };
        this.publish();
      }
    }
  }

  async setIncludePrereleaseUpdates(value: boolean): Promise<UpdateState> {
    await this.settings.setIncludePrereleaseUpdates(value);
    this.etag = null;
    this.state = {
      checking: false,
      availableVersion: null,
      releaseURL: null,
      lastCheckedAt: null,
    };
    this.publish();
    return this.check({ force: true });
  }

  async openCurrentRelease(): Promise<void> {
    const url = this.state.releaseURL;
    if (!url || !isAllowedReleaseURL(url)) return;
    await this.openExternal(url);
  }

  async start(): Promise<void> {
    if (this.started) return;
    this.started = true;
    try {
      await this.check();
    } finally {
      this.schedule();
    }
  }

  stop(): void {
    this.started = false;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  private schedule(): void {
    if (!this.started) return;
    if (this.timer) clearTimeout(this.timer);
    const base = Math.max(this.state.lastCheckedAt ?? 0, this.lastAttemptCompletedAt ?? this.now());
    const delay = Math.max(0, base + CHECK_INTERVAL_MS - this.now());
    this.timer = setTimeout(() => {
      void this.check()
        .catch(() => undefined)
        .finally(() => this.schedule());
    }, delay);
    this.timer.unref?.();
  }
}

let sharedUpdateService: UpdateService | null = null;

export function setSharedUpdateService(service: UpdateService): void {
  sharedUpdateService?.stop();
  sharedUpdateService = service;
}

export function getSharedUpdateService(): UpdateService {
  if (!sharedUpdateService) throw new Error("Update service has not been initialized");
  return sharedUpdateService;
}
