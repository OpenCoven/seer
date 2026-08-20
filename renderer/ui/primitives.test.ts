import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { nextSegmentedControlIndex } from "./primitives";

const here = dirname(fileURLToPath(import.meta.url));

test("nextSegmentedControlIndex moves forward on ArrowRight/ArrowDown, wrapping past the last item", () => {
  assert.equal(nextSegmentedControlIndex(0, 3, "ArrowRight"), 1);
  assert.equal(nextSegmentedControlIndex(1, 3, "ArrowRight"), 2);
  assert.equal(nextSegmentedControlIndex(2, 3, "ArrowRight"), 0, "wraps from the last item to the first");
  assert.equal(nextSegmentedControlIndex(0, 3, "ArrowDown"), 1);
  assert.equal(nextSegmentedControlIndex(2, 3, "ArrowDown"), 0, "ArrowDown wraps just like ArrowRight");
});

test("nextSegmentedControlIndex moves backward on ArrowLeft/ArrowUp, wrapping past the first item", () => {
  assert.equal(nextSegmentedControlIndex(2, 3, "ArrowLeft"), 1);
  assert.equal(nextSegmentedControlIndex(1, 3, "ArrowLeft"), 0);
  assert.equal(nextSegmentedControlIndex(0, 3, "ArrowLeft"), 2, "wraps from the first item to the last");
  assert.equal(nextSegmentedControlIndex(0, 3, "ArrowUp"), 2, "ArrowUp wraps just like ArrowLeft");
});

test("nextSegmentedControlIndex jumps to the first/last item on Home/End regardless of current index", () => {
  assert.equal(nextSegmentedControlIndex(2, 5, "Home"), 0);
  assert.equal(nextSegmentedControlIndex(0, 5, "Home"), 0);
  assert.equal(nextSegmentedControlIndex(0, 5, "End"), 4);
  assert.equal(nextSegmentedControlIndex(3, 5, "End"), 4);
});

test("nextSegmentedControlIndex returns null for keys the group does not handle, leaving native click/Space alone", () => {
  assert.equal(nextSegmentedControlIndex(0, 3, "Enter"), null);
  assert.equal(nextSegmentedControlIndex(0, 3, " "), null);
  assert.equal(nextSegmentedControlIndex(0, 3, "Tab"), null);
  assert.equal(nextSegmentedControlIndex(0, 3, "a"), null);
});

test("nextSegmentedControlIndex is a correct wrap-around with exactly two items (the app's actual SegmentedControl usage)", () => {
  assert.equal(nextSegmentedControlIndex(0, 2, "ArrowRight"), 1);
  assert.equal(nextSegmentedControlIndex(1, 2, "ArrowRight"), 0);
  assert.equal(nextSegmentedControlIndex(0, 2, "ArrowLeft"), 1);
  assert.equal(nextSegmentedControlIndex(1, 2, "ArrowLeft"), 0);
});

test("nextSegmentedControlIndex returns null when the group has no items", () => {
  assert.equal(nextSegmentedControlIndex(0, 0, "ArrowRight"), null);
  assert.equal(nextSegmentedControlIndex(-1, 0, "Home"), null);
});

// --- Source-level invariants for the parts of roving-tabindex/radio ---
// --- semantics that require a real DOM to fully exercise. ---

test("SegmentedControlItem sets role=radio, aria-checked, and roving tabIndex (selected=0, others=-1)", () => {
  const source = readFileSync(join(here, "primitives.tsx"), "utf8");
  assert.match(source, /role="radio"/);
  assert.match(source, /aria-checked=\{selected\}/);
  assert.match(source, /tabIndex=\{selected \? 0 : -1\}/);
});

test("SegmentedControl scopes navigation to its own registered items via context, not a module-level/global list", () => {
  const source = readFileSync(join(here, "primitives.tsx"), "utf8");
  assert.match(
    source,
    /const itemsRef = React\.useRef<HTMLButtonElement\[\]>\(\[\]\);/,
    "each SegmentedControl instance must own its own items ref (scoped, not shared/global)",
  );
  assert.match(source, /SegmentedControlContext\.Provider/);
});
