import assert from "node:assert/strict";
import test from "node:test";

import { sourceLabel } from "./home-view";

test("sourceLabel maps each ActiveAgent source to its display label", () => {
  assert.equal(sourceLabel("both"), "Process + session");
  assert.equal(sourceLabel("process"), "Process");
  assert.equal(sourceLabel("session"), "Session");
});
