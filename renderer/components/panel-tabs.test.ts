import assert from "node:assert/strict";
import test from "node:test";

import { panelValueToPath, pathnameToPanelValue } from "./panel-tabs";

test("pathnameToPanelValue selects history only for /history and its subpaths", () => {
  assert.equal(pathnameToPanelValue("/history"), "history");
  assert.equal(pathnameToPanelValue("/history/anything"), "history");
  assert.equal(pathnameToPanelValue("/"), "status");
  assert.equal(pathnameToPanelValue("/status"), "status");
  assert.equal(pathnameToPanelValue(""), "status");
});

test("panelValueToPath is the inverse mapping used for navigation", () => {
  assert.equal(panelValueToPath("history"), "/history");
  assert.equal(panelValueToPath("status"), "/");
});
