import { spawn } from "node:child_process";
import { existsSync, writeFileSync } from "node:fs";

const [, , leaderReadyPath, leaderReleasePath, descendantPidPath, descendantReleasePath] =
  process.argv;
if (!leaderReadyPath || !leaderReleasePath || !descendantPidPath || !descendantReleasePath) {
  throw new Error("expected leader/descendant coordination paths");
}

const descendant = spawn(
  process.execPath,
  [
    "-e",
    [
      'const { existsSync, writeFileSync } = require("node:fs");',
      "const [pidPath, releasePath] = process.argv.slice(1);",
      "writeFileSync(pidPath, `${process.pid}\\n`);",
      "const timer = setInterval(() => {",
      "  if (existsSync(releasePath)) {",
      "    clearInterval(timer);",
      '    writeFileSync(`${pidPath}.exited`, "exited\\n");',
      "    process.exit(0);",
      "  }",
      "}, 10);",
    ].join("\n"),
    descendantPidPath,
    descendantReleasePath,
  ],
  { stdio: "ignore" },
);
descendant.unref();
writeFileSync(leaderReadyPath, `${process.pid}\n`);

while (!existsSync(leaderReleasePath)) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
