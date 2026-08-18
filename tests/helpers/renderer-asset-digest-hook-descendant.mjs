#!/usr/bin/env node
// Used as the executable half of an `--after-collection-hook`/afterCollection
// hook to exercise renderer-asset-digest.py's process-group cleanup: spawns
// a background grandchild that, after delayMs milliseconds, writes "done" to
// markerPath - proof it was left running long enough to finish - then this
// process itself exits immediately, unless selfDelayMs is given and greater
// than zero, in which case this process synchronously busy-waits that long
// first, so it is *this* process (not just its grandchild) that exceeds
// `--hook-timeout-seconds`.
//
// The grandchild inherits this process's own process group: the helper's
// `run_hook` starts this process in a new session via Python's
// `start_new_session=True`, and this process never calls `setsid()` itself,
// so a plain child of it stays in that same session/process group. If the
// helper correctly terminates the whole group, the grandchild is killed
// before its timer fires and markerPath is never created; if cleanup were
// incomplete, the grandchild would keep running past this script's own exit
// and eventually write markerPath regardless.
import { spawn } from "node:child_process";
import process from "node:process";

const [, , markerPath, delayMsArg, selfDelayMsArg] = process.argv;
const delayMs = Number(delayMsArg);

// Deliberately *not* `detached: true`: on POSIX, `detached` makes the child
// the leader of a brand-new session/process group of its own, which would
// take it *out* of this process's group - the opposite of what this helper
// needs to exercise. A plain (non-detached) child simply inherits this
// process's existing process group and is unaffected by this process's own
// exit; `.unref()` alone is enough to let this process exit without Node
// waiting on it first.
const grandchild = spawn(
  process.execPath,
  [
    "-e",
    "setTimeout(() => require('node:fs').writeFileSync(process.argv[1], 'done'), Number(process.argv[2]))",
    markerPath,
    String(delayMs),
  ],
  { stdio: "ignore" },
);
grandchild.unref();

const selfDelayMs = Number(selfDelayMsArg || "0");
if (selfDelayMs > 0) {
  const deadline = Date.now() + selfDelayMs;
  while (Date.now() < deadline) {
    // Busy-wait synchronously: this process must remain alive long enough
    // for --hook-timeout-seconds to be the thing that elapses here, rather
    // than exiting promptly and only leaving the grandchild behind.
  }
}
