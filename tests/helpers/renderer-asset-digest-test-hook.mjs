#!/usr/bin/env node
import { mkdirSync, renameSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";

const [, , action, ...paths] = process.argv;

switch (action) {
  case "replace-file-with-symlink": {
    const [target, replacement] = paths;
    unlinkSync(target);
    symlinkSync(replacement, target);
    break;
  }
  case "replace-file-with-file": {
    const [replacement, target] = paths;
    renameSync(replacement, target);
    break;
  }
  case "replace-file-with-directory": {
    const [target] = paths;
    unlinkSync(target);
    mkdirSync(target);
    break;
  }
  case "mutate-file": {
    const [target] = paths;
    writeFileSync(target, "in-place mutation after asset collection\n");
    break;
  }
  case "replace-directory-with-symlink": {
    const [target, parked, replacement] = paths;
    renameSync(target, parked);
    symlinkSync(replacement, target);
    break;
  }
  default:
    throw new Error(`unknown renderer asset digest hook action: ${action}`);
}
