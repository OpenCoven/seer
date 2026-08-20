import { readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";

import { CANONICAL_FORBIDDEN_MARKERS } from "../../scripts/check-standalone-boundary.mjs";

/**
 * Pure source-boundary scanning helpers shared by production checks (the
 * real "no Glaze references in the standalone-safe renderer sources" scan)
 * and their own tests. Extracted from the test file so the scanning logic
 * itself can be exercised against a disposable fixture directory (e.g. under
 * `os.tmpdir()`) instead of ever writing a fixture file into `renderer/` —
 * production sources must never be mutated just to test the scanner.
 */

/** Closed set of forbidden Glaze references the standalone build must never contain. */
export const FORBIDDEN_PATTERNS = CANONICAL_FORBIDDEN_MARKERS.map(
  ({ marker }) => new RegExp(marker.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")),
);

/** Source extensions the scan covers — CSS is included alongside TS/TSX. */
export const SOURCE_FILE_PATTERN = /\.(ts|tsx|css)$/;

/**
 * Recursively collects paths (relative to `root`) of every file under
 * `directory` whose name matches `filePattern`, skipping any directory
 * whose root-relative path is in `excludedDirs` and any file whose
 * root-relative path is in `excludedFiles`.
 */
export function walkSourceFiles(
  directory,
  { root = directory, excludedDirs = [], excludedFiles = new Set(), filePattern = SOURCE_FILE_PATTERN } = {},
  out = [],
) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const fullPath = join(directory, entry.name);
    const relPath = relative(root, fullPath);

    if (excludedDirs.some((dir) => relPath === dir || relPath.startsWith(`${dir}/`))) {
      continue;
    }

    if (entry.isDirectory()) {
      walkSourceFiles(fullPath, { root, excludedDirs, excludedFiles, filePattern }, out);
      continue;
    }

    if (!filePattern.test(entry.name)) {
      continue;
    }
    if (excludedFiles.has(relPath)) {
      continue;
    }
    out.push(relPath);
  }
  return out;
}

/**
 * Scans `files` (paths relative to `root`) for any of `patterns`, returning
 * one offender string (`"<path> matches <pattern>"`) per match found.
 */
export function scanForbiddenPatterns(files, root, patterns = FORBIDDEN_PATTERNS) {
  const offenders = [];
  for (const relPath of files) {
    const source = readFileSync(join(root, relPath), "utf8");
    for (const pattern of patterns) {
      if (pattern.test(source)) {
        offenders.push(`${relPath} matches ${pattern}`);
      }
    }
  }
  return offenders;
}
