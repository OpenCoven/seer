import { spawn } from "node:child_process";
import { writeFileSync } from "node:fs";

const pidPath = process.argv[2];
if (!pidPath) throw new Error("expected grandchild pid path");

const grandchild = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], {
  stdio: "ignore",
});
writeFileSync(pidPath, `${grandchild.pid}\n`);
grandchild.unref();
process.exitCode = 17;
