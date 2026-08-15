import {
  appendFileSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

const [, , outputDir] = process.argv;
if (!outputDir) throw new Error("expected private renderer output directory");

let attempt = null;
const counterPath = process.env.SEER_RENDERER_BUILD_TEST_COUNTER_PATH;
if (counterPath) {
  attempt = existsSync(counterPath) ? Number(readFileSync(counterPath, "utf8")) + 1 : 1;
  writeFileSync(counterPath, `${attempt}\n`);
}
const baseMarker = process.env.SEER_RENDERER_BUILD_TEST_MARKER ?? "test-generation";
const marker = attempt === null ? baseMarker : `${baseMarker}-${attempt}`;
const startedPath = process.env.SEER_RENDERER_BUILD_TEST_CHILD_STARTED_PATH;
if (startedPath) writeFileSync(startedPath, `${process.pid}\n`);

const blockFirstReadyPath = process.env.SEER_RENDERER_BUILD_TEST_BLOCK_FIRST_READY_PATH;
const blockFirstReleasePath = process.env.SEER_RENDERER_BUILD_TEST_BLOCK_FIRST_RELEASE_PATH;
if (attempt === 1 && blockFirstReadyPath && blockFirstReleasePath) {
  writeFileSync(blockFirstReadyPath, `${process.pid}\n`);
  while (!existsSync(blockFirstReleasePath)) {
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

const delayMs = Number(process.env.SEER_RENDERER_BUILD_TEST_CHILD_DELAY_MS ?? "0");
if (delayMs > 0) await new Promise((resolve) => setTimeout(resolve, delayMs));
if (process.env.SEER_RENDERER_BUILD_TEST_FAIL === "1") {
  throw new Error("injected renderer build failure");
}

mkdirSync(join(outputDir, "assets"), { recursive: true });
writeFileSync(join(outputDir, "standalone-window.html"), '<script src="./assets/app.js"></script>\n');
writeFileSync(join(outputDir, "assets", "app.js"), `globalThis.generation = ${JSON.stringify(marker)};\n`);
writeFileSync(join(outputDir, "generation-marker.txt"), `${marker}\n`);
const historyPath = process.env.SEER_RENDERER_BUILD_TEST_HISTORY_PATH;
if (historyPath) appendFileSync(historyPath, `${marker}\n`);
const restoreSourcePath = process.env.SEER_RENDERER_BUILD_TEST_RESTORE_SOURCE_PATH;
const restoreSourceFrom = process.env.SEER_RENDERER_BUILD_TEST_RESTORE_SOURCE_FROM;
if (attempt === 2 && restoreSourcePath && restoreSourceFrom) {
  copyFileSync(restoreSourceFrom, restoreSourcePath);
}
