import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { syncDarkMode } from "./app";

const here = dirname(fileURLToPath(import.meta.url));

/** Minimal fake `MediaQueryList` driven manually by tests via `emit`. */
class FakeMediaQueryList {
  matches = false;
  private readonly changeListeners = new Set<(event: MediaQueryListEvent) => void>();

  addEventListener(type: string, listener: (event: MediaQueryListEvent) => void): void {
    if (type === "change") {
      this.changeListeners.add(listener);
    }
  }

  removeEventListener(type: string, listener: (event: MediaQueryListEvent) => void): void {
    if (type === "change") {
      this.changeListeners.delete(listener);
    }
  }

  get listenerCount(): number {
    return this.changeListeners.size;
  }

  emit(matches: boolean): void {
    this.matches = matches;
    for (const listener of [...this.changeListeners]) {
      listener({ matches } as MediaQueryListEvent);
    }
  }
}

/** Swaps `globalThis.window`/`globalThis.document` for the duration of `fn`. */
function withFakeBrowserGlobals<T>(
  mql: FakeMediaQueryList,
  toggles: Array<[string, boolean | undefined]>,
  fn: () => T,
): T {
  const originalWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
  const originalDocument = Object.getOwnPropertyDescriptor(globalThis, "document");

  const fakeWindow = {
    matchMedia: (): MediaQueryList => mql as unknown as MediaQueryList,
  } as unknown as Window & typeof globalThis;

  const fakeDocument = {
    documentElement: {
      classList: {
        toggle: (className: string, force?: boolean) => {
          toggles.push([className, force]);
        },
      },
    },
  } as unknown as Document;

  Object.defineProperty(globalThis, "window", { value: fakeWindow, configurable: true, writable: true });
  Object.defineProperty(globalThis, "document", {
    value: fakeDocument,
    configurable: true,
    writable: true,
  });

  try {
    return fn();
  } finally {
    if (originalWindow) {
      Object.defineProperty(globalThis, "window", originalWindow);
    } else {
      delete (globalThis as { window?: unknown }).window;
    }
    if (originalDocument) {
      Object.defineProperty(globalThis, "document", originalDocument);
    } else {
      delete (globalThis as { document?: unknown }).document;
    }
  }
}

test("syncDarkMode applies the current match synchronously, reacts to later changes, and its cleanup removes exactly the listener it added", () => {
  const mql = new FakeMediaQueryList();
  const toggles: Array<[string, boolean | undefined]> = [];

  withFakeBrowserGlobals(mql, toggles, () => {
    const stop = syncDarkMode();

    // Applied synchronously on call, before any `change` event.
    assert.deepEqual(toggles, [["dark", false]]);
    assert.equal(mql.listenerCount, 1, "exactly one change listener registered");

    mql.emit(true);
    assert.deepEqual(toggles, [
      ["dark", false],
      ["dark", true],
    ]);

    stop();
    assert.equal(mql.listenerCount, 0, "cleanup removes the exact listener it added");

    // A change firing after cleanup must not reach the (removed) listener.
    mql.emit(false);
    assert.equal(toggles.length, 2, "no toggle call after cleanup");
  });
});

test("calling the syncDarkMode cleanup twice is a no-op the second time (no error, no double-removal side effects)", () => {
  const mql = new FakeMediaQueryList();
  const toggles: Array<[string, boolean | undefined]> = [];

  withFakeBrowserGlobals(mql, toggles, () => {
    const stop = syncDarkMode();
    stop();
    assert.doesNotThrow(() => stop());
    assert.equal(mql.listenerCount, 0);
  });
});

// --- Source-level lifecycle invariants (Finding 3): StrictMode's double- ---
// --- invoked effect cleanup must never disconnect the bridge, and         ---
// --- mountApp's dispose() must unmount then disconnect exactly once.      ---

test("RootView never calls bridge.disconnect() from component lifecycle (StrictMode-safe)", () => {
  const source = readFileSync(join(here, "root-view.tsx"), "utf8");
  assert.ok(
    !/bridge\.disconnect\(\)/.test(source),
    "RootView must not disconnect the bridge itself — StrictMode double-invokes effect cleanup, " +
      "and disconnecting there would kill live subscriptions out from under a remounting component",
  );
});

test("mountApp returns a dispose() that unmounts the root then disconnects the bridge exactly once", () => {
  const source = readFileSync(join(here, "app.tsx"), "utf8");

  assert.match(source, /export function mountApp\(/, "mountApp must remain exported");
  assert.match(
    source,
    /return function dispose\(\)/,
    "mountApp must return an explicit named dispose() function",
  );

  const disposeBody = source.slice(source.indexOf("return function dispose()"));
  const unmountIndex = disposeBody.indexOf("root.unmount()");
  const disconnectIndex = disposeBody.indexOf("bridge.disconnect()");

  assert.ok(unmountIndex !== -1, "dispose() must call root.unmount()");
  assert.ok(disconnectIndex !== -1, "dispose() must call bridge.disconnect()");
  assert.ok(unmountIndex < disconnectIndex, "dispose() must unmount before disconnecting the bridge");

  assert.match(
    source,
    /let disposed = false;[\s\S]*if \(disposed\) {\s*return;\s*}\s*disposed = true;/,
    "dispose() must guard so unmount/disconnect run exactly once even if called more than once",
  );
});

test("entry points only call mountApp's dispose from pagehide or HMR dispose, never unconditionally", () => {
  const mainEntry = readFileSync(join(here, "index.tsx"), "utf8");
  const standaloneEntry = readFileSync(join(here, "..", "standalone", "index.tsx"), "utf8");

  for (const [name, source] of [
    ["renderer/main/index.tsx", mainEntry],
    ["renderer/standalone/index.tsx", standaloneEntry],
  ] as const) {
    assert.match(
      source,
      /const dispose = mountApp\(/,
      `${name} must capture mountApp's returned dispose function`,
    );
    assert.match(
      source,
      /addEventListener\("pagehide",\s*dispose\)/,
      `${name} must call dispose() on pagehide (real teardown), not from component/effect lifecycle`,
    );
    assert.ok(
      !/^\s*dispose\(\);\s*$/m.test(source),
      `${name} must not call dispose() unconditionally at module scope`,
    );
  }

  assert.match(
    mainEntry,
    /import\.meta\.hot\.dispose\(dispose\)/,
    "renderer/main/index.tsx must also dispose on HMR module replacement",
  );
});
