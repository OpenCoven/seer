import { writeFileSync } from "node:fs";

const markerPath = process.env.SEER_RENDERER_CONSUMER_TEST_MARKER;
if (!markerPath) throw new Error("expected consumer marker path");
writeFileSync(markerPath, `${process.pid}\n`);
