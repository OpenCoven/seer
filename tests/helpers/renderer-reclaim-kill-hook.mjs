import { writeFileSync } from "node:fs";

const phase = process.argv[2];
const readyPath = process.env.SEER_RENDERER_RECLAIM_TEST_READY_PATH;
if (!phase || !readyPath) throw new Error("expected reclaim phase and ready path");

writeFileSync(readyPath, `${phase}\n`);
process.kill(process.ppid, "SIGKILL");
