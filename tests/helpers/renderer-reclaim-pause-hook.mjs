import { existsSync, writeFileSync } from "node:fs";

// Unlike renderer-reclaim-kill-hook.mjs (which hard-kills the wrapper to
// exercise crash recovery), this hook pauses the wrapper mid-reclaim so a
// test can inspect its held state (and drive a concurrent contender) while
// the paused phase's work is still in flight, then let it resume normally.
const phase = process.argv[2];
const readyPath = process.env.SEER_RENDERER_RECLAIM_TEST_READY_PATH;
const releasePath = process.env.SEER_RENDERER_RECLAIM_TEST_RELEASE_PATH;
if (!phase || !readyPath || !releasePath) {
  throw new Error("expected reclaim phase, ready path, and release path");
}

writeFileSync(readyPath, `${phase}\n`);
while (!existsSync(releasePath)) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
