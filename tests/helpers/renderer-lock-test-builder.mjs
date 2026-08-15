import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [, , outputDir] = process.argv;
if (!outputDir) throw new Error("expected private renderer output directory");

const marker = process.env.SEER_RENDERER_BUILD_TEST_MARKER ?? "test-generation";
const startedPath = process.env.SEER_RENDERER_BUILD_TEST_CHILD_STARTED_PATH;
if (startedPath) writeFileSync(startedPath, `${process.pid}\n`);

const delayMs = Number(process.env.SEER_RENDERER_BUILD_TEST_CHILD_DELAY_MS ?? "0");
if (delayMs > 0) await new Promise((resolve) => setTimeout(resolve, delayMs));

mkdirSync(join(outputDir, "assets"), { recursive: true });
writeFileSync(join(outputDir, "standalone-window.html"), '<script src="./assets/app.js"></script>\n');
writeFileSync(join(outputDir, "assets", "app.js"), `globalThis.generation = ${JSON.stringify(marker)};\n`);
writeFileSync(join(outputDir, "generation-marker.txt"), `${marker}\n`);
